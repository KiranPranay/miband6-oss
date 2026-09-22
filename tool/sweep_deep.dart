// Sweeps the deep-sleep detector over a real capture and reports, per
// parameter set, the median deep share, the mean position of deep bouts in the
// night (must be well below 0.5 — slow-wave sleep is front-loaded), and how
// many nights report no deep at all.
//
//   dart run tool/sweep_deep.dart activity.json hr.json
import 'dart:convert';
import 'dart:io';

import 'package:band/core/activity_sample.dart';
import 'package:band/core/sleep_analyzer.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: sweep_deep <activity.json> <hr.json>');
    exit(2);
  }
  final samples = (jsonDecode(File(args[0]).readAsStringSync()) as List)
      .map((e) => ActivitySample.fromJson(e as Map<String, dynamic>))
      .toList();
  final hr = (jsonDecode(File(args[1]).readAsStringSync()) as List)
      .map((e) => HeartRateReading.fromJson(e as Map<String, dynamic>))
      .toList();

  stdout.writeln('samples=${samples.length} hr=${hr.length}');
  stdout.writeln('${'params'.padRight(38)} nights  medShare  meanPos  zero%  p25-p75 share');

  // half=0 selects the linear (whole-session least-squares) detrend.
  final grid = <DeepParams>[
    for (final half in [0, 120, 180])
      for (final dip in [1.0, 1.5, 2.0, 3.0])
        for (final tau in [180, 240, 360])
          for (final floor in [0.25, 0.4])
            for (final run in [8, 10])
              DeepParams(
                  dipBpm: dip,
                  tauMinutes: tau,
                  baselineHalfWindow: half,
                  minRunMinutes: run,
                  wFloor: floor,
                  stillCeiling: 12),
  ];
  for (final p in grid) {
    {
      {
        SleepAnalyzer.debugDeepOverride = p;
        final days = SleepAnalyzer.detectSessions(samples, hr: hr)
            .where((d) => !d.isNap && d.totalSleepMinutes >= 180)
            .toList();
        final shares = <double>[];
        final positions = <double>[];
        var zero = 0;
        for (final d in days) {
          final total = d.totalSleepMinutes;
          if (total == 0) continue;
          final share = d.totalDeepMinutes / total * 100;
          shares.add(share);
          if (share < 1) zero++;
          final s = d.startTime, e = d.endTime;
          if (s == null || e == null) continue;
          final span = e.difference(s).inMinutes;
          for (final iv in d.intervals) {
            if (iv.stage != SleepStage.deep) continue;
            final mid = iv.startTime
                .add(Duration(minutes: iv.durationMinutes ~/ 2))
                .difference(s)
                .inMinutes;
            positions.add(mid / span);
          }
        }
        if (shares.isEmpty) continue;
        shares.sort();
        final med = shares[shares.length ~/ 2];
        final p25 = shares[(shares.length * 0.25).floor()];
        final p75 = shares[(shares.length * 0.75).floor().clamp(0, shares.length - 1)];
        final mp = positions.isEmpty
            ? double.nan
            : positions.reduce((a, b) => a + b) / positions.length;
        final flag = (med >= 13 && med <= 23 && mp < 0.45 && zero <= days.length * 0.25) ? '  <-- OK' : '';
        stdout.writeln('${p.toString().padRight(62)} ${days.length.toString().padLeft(6)}  '
            '${med.toStringAsFixed(1).padLeft(7)}%  ${mp.toStringAsFixed(3).padLeft(6)}  '
            '${(zero / days.length * 100).toStringAsFixed(0).padLeft(4)}%  '
            '${p25.toStringAsFixed(0)}-${p75.toStringAsFixed(0)}%$flag');
      }
    }
  }
  SleepAnalyzer.debugDeepOverride = null;
}
