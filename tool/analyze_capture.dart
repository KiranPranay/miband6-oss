// Runs the real SleepAnalyzer over a captured activity_data.json and prints
// physiological diagnostics. Development tool — not shipped in the app.
//
//   dart run tool/analyze_capture.dart <activity_data.json> [hr_data.json]
//
// Why this exists: unit tests prove internal consistency against synthetic
// input. They cannot tell you whether a night's output is *physiologically*
// plausible. This harness runs the shipping code over real captured data and
// checks it against published norms — deep sleep 13-23 % of total sleep,
// slow-wave sleep concentrated in the first half of the night, sleep efficiency
// ≤ 100 %, and no night longer than ~12 h.

import 'dart:convert';
import 'dart:io';

import 'package:band/core/activity_sample.dart';
import 'package:band/core/sleep_analyzer.dart';
import 'package:band/core/sleep_regularity.dart';

double _mean(List<num> v) =>
    v.isEmpty ? 0 : v.fold<num>(0, (a, b) => a + b) / v.length;

double _median(List<num> v) {
  if (v.isEmpty) return 0;
  final s = [...v]..sort();
  return s[s.length ~/ 2].toDouble();
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/analyze_capture.dart '
        '<activity_data.json> [hr_data.json]');
    exit(2);
  }

  final samples = (jsonDecode(File(args[0]).readAsStringSync()) as List)
      .map((e) => ActivitySample.fromJson(e as Map<String, dynamic>))
      .toList();

  final hr = args.length > 1 && File(args[1]).existsSync()
      ? (jsonDecode(File(args[1]).readAsStringSync()) as List)
          .map((e) => HeartRateReading.fromJson(e as Map<String, dynamic>))
          .toList()
      : <HeartRateReading>[];

  stdout.writeln('samples=${samples.length}  hrReadings=${hr.length}');
  if (samples.isNotEmpty) {
    stdout.writeln('range: ${samples.first.timestamp} -> '
        '${samples.last.timestamp}');
  }

  final days = SleepAnalyzer.detectSessions(samples, hr: hr);
  final nights = days.where((d) => !d.isNap).toList();
  final naps = days.where((d) => d.isNap).toList();

  stdout.writeln('\n=== ${days.length} sessions '
      '(${nights.length} nights, ${naps.length} naps) ===');

  final deepPcts = <double>[];
  final effs = <double>[];
  final spans = <int>[];
  var overLong = 0;
  var remLeak = 0;

  for (final d in nights) {
    final q = SleepQuality.of(d);
    final total = d.totalSleepMinutes;
    final deepPct = total == 0 ? 0.0 : d.totalDeepMinutes * 100.0 / total;
    final span = d.startTime == null || d.endTime == null
        ? 0
        : d.endTime!.difference(d.startTime!).inMinutes;
    spans.add(span);
    if (span > 12 * 60) overLong++;
    if (d.totalRemMinutes != 0) remLeak++;
    if (total > 0) {
      deepPcts.add(deepPct);
      effs.add(q.efficiencyPercent);
    }

    stdout.writeln(
      '${d.date.toIso8601String().substring(0, 10)}  '
      '${d.startTime?.toIso8601String().substring(11, 16)}'
      '->${d.endTime?.toIso8601String().substring(11, 16)}  '
      'span=${span}m total=${total}m '
      'deep=${d.totalDeepMinutes}m (${deepPct.toStringAsFixed(1)}%) '
      'light=${d.totalLightMinutes}m awake=${d.totalAwakeMinutes}m '
      'eff=${q.efficiencyPercent.toStringAsFixed(0)}% '
      'lat=${q.latencyMinutes}m wakes=${q.wakeEpisodes}',
    );
  }

  stdout.writeln('\n=== PLAUSIBILITY vs published norms ===');
  void check(String label, bool ok, String detail) =>
      stdout.writeln('  ${ok ? "PASS" : "FAIL"}  $label — $detail');

  if (deepPcts.isNotEmpty) {
    final md = _median(deepPcts);
    check('deep sleep share', md >= 10 && md <= 30,
        'median ${md.toStringAsFixed(1)}% (healthy adult 13-23%)');
    final zero = deepPcts.where((p) => p < 1).length;
    check('nights with usable deep staging', zero <= deepPcts.length * 0.25,
        '$zero/${deepPcts.length} nights report ~0% deep');
  }
  if (effs.isNotEmpty) {
    check('sleep efficiency', _median(effs) >= 60 && effs.every((e) => e <= 100),
        'median ${_median(effs).toStringAsFixed(0)}%, '
        'max ${effs.reduce((a, b) => a > b ? a : b).toStringAsFixed(0)}%');
  }
  if (spans.isNotEmpty) {
    check('no impossible nights', overLong == 0,
        '$overLong night(s) longer than 12 h; longest '
        '${spans.reduce((a, b) => a > b ? a : b)}m');
    check('typical night length', _median(spans) >= 240 && _median(spans) <= 700,
        'median span ${_median(spans).toStringAsFixed(0)}m');
  }
  check('REM never reported', remLeak == 0,
      '$remLeak night(s) reported REM (firmware cannot measure it)');

  final sri = SleepRegularity.compute(samples, hr: hr);
  stdout.writeln('\n=== Sleep Regularity Index ===');
  if (sri == null) {
    stdout.writeln('  no data');
  } else if (!sri.hasValue) {
    stdout.writeln('  ${sri.explanation}');
  } else {
    stdout.writeln('  SRI = ${sri.index!.toStringAsFixed(1)}  (${sri.label})  '
        'from ${sri.comparedDays} day-pairs, ${sri.pairCount} epoch pairs');
    stdout.writeln('  UK Biobank median 81.0 (IQR 73.8-86.3)');
    check('SRI within bounds', sri.index! >= -100 && sri.index! <= 100,
        sri.index!.toStringAsFixed(1));
  }

  // Deep sleep should concentrate in the first half of the night.
  final positions = <double>[];
  for (final d in nights) {
    final s = d.startTime, e = d.endTime;
    if (s == null || e == null) continue;
    final span = e.difference(s).inMinutes;
    if (span <= 0) continue;
    for (final iv in d.intervals) {
      if (iv.stage != SleepStage.deep) continue;
      final mid = iv.startTime
          .add(Duration(minutes: iv.durationMinutes ~/ 2))
          .difference(s)
          .inMinutes;
      positions.add(mid / span);
    }
  }
  if (positions.isNotEmpty) {
    final mp = _mean(positions);
    check('slow-wave sleep is front-loaded', mp < 0.45,
        'mean deep position ${mp.toStringAsFixed(3)} of the night '
        '(should be well below 0.5)');
  } else {
    stdout.writeln('  ----  slow-wave position — no deep intervals to test');
  }
}
