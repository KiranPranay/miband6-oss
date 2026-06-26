import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/snore_detector.dart';

/// One night's snore-tracking session: the window it ran for and the derived
/// events (NO audio — only event times + loudness, per the privacy model).
class SnoreSession {
  final DateTime start;
  final DateTime end;
  final List<SnoreEvent> events;

  const SnoreSession({
    required this.start,
    required this.end,
    required this.events,
  });

  SnoreSummary get summary => SnoreSummary.from(events);
  Duration get monitored => end.difference(start);

  Map<String, dynamic> toJson() => {
        's': start.millisecondsSinceEpoch,
        'e': end.millisecondsSinceEpoch,
        'ev': events.map((e) => e.toJson()).toList(),
      };

  factory SnoreSession.fromJson(Map<String, dynamic> j) => SnoreSession(
        start: DateTime.fromMillisecondsSinceEpoch(j['s'] as int),
        end: DateTime.fromMillisecondsSinceEpoch(j['e'] as int),
        events: ((j['ev'] as List?) ?? const [])
            .map((e) => SnoreEvent.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// JSON-file persistence for snore sessions (derived events only).
class SnoreStore {
  static const _file = 'snore_sessions.json';
  static const _keepSessions = 30;

  List<SnoreSession> _sessions = [];
  List<SnoreSession> get sessions => List.unmodifiable(_sessions);
  SnoreSession? get latest => _sessions.isEmpty ? null : _sessions.last;

  Future<File> _path() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_file');
  }

  Future<void> load() async {
    try {
      final f = await _path();
      if (!await f.exists()) return;
      final raw = jsonDecode(await f.readAsString());
      if (raw is List) {
        _sessions = raw
            .map((e) => SnoreSession.fromJson(e as Map<String, dynamic>))
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
      }
    } catch (_) {
      _sessions = [];
    }
  }

  Future<void> add(SnoreSession session) async {
    _sessions.add(session);
    _sessions.sort((a, b) => a.start.compareTo(b.start));
    if (_sessions.length > _keepSessions) {
      _sessions = _sessions.sublist(_sessions.length - _keepSessions);
    }
    await _save();
  }

  /// The session whose monitoring ended on [wakeDate] (the morning you woke).
  SnoreSession? sessionForWakeDate(DateTime wakeDate) {
    for (final s in _sessions.reversed) {
      final e = s.end;
      if (e.year == wakeDate.year &&
          e.month == wakeDate.month &&
          e.day == wakeDate.day) {
        return s;
      }
    }
    return null;
  }

  Future<void> _save() async {
    final f = await _path();
    await f.writeAsString(jsonEncode(_sessions.map((s) => s.toJson()).toList()));
  }
}
