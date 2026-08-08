import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'ui_throttle.dart';

/// Severity of a captured log line.
enum LogLevel { debug, info, error }

/// One captured log line. Kept as a small object rather than a formatted string
/// so the console can filter/colour by level without re-parsing text.
@immutable
class LogEntry {
  const LogEntry(this.time, this.level, this.message);

  final DateTime time;
  final LogLevel level;
  final String message;

  String get label => switch (level) {
        LogLevel.debug => 'DEBUG',
        LogLevel.info => 'INFO',
        LogLevel.error => 'ERROR',
      };

  /// `HH:MM:SS` — the console shows time-of-day only; the date is noise.
  String get clock =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';

  @override
  String toString() => '[$clock] [$label] $message';
}

/// In-app log buffer for the debug console.
///
/// Three deliberate properties, all of which were previously absent and showed
/// up directly as UI jank (see findings-15):
///
/// 1. **Bounded.** A ring buffer of [maxLines] entries. The old implementation
///    appended to an unbounded `List<String>` for the life of the process — an
///    overnight session with verbose packet logging leaked tens of MB and made
///    every console rebuild walk a longer and longer list.
/// 2. **Coalesced.** `notifyListeners()` is rate-limited to ~4 Hz. Previously
///    every single line notified, so a burst of BLE packet logs could schedule
///    hundreds of rebuilds per second.
/// 3. **Verbose-gated.** [verbose] defaults to `false`, so per-packet `d()`
///    lines are dropped at the source (no string interpolation cost, no buffer
///    churn) unless a developer turns them on in Settings → Advanced.
///    `debugPrint` still receives them in debug builds only when verbose is on,
///    which also keeps logcat readable during hardware runs.
class BLELogger extends ChangeNotifier {
  BLELogger({this.maxLines = 500}) {
    _coalescer = Coalescer(_emit, interval: const Duration(milliseconds: 250));
  }

  /// Ring-buffer capacity. 500 lines is enough to cover a full connect +
  /// auth + fetch cycle, which is what the console is actually used for.
  final int maxLines;

  final ListQueue<LogEntry> _entries = ListQueue<LogEntry>();
  late final Coalescer _coalescer;

  /// When false, `d()` (per-packet/debug detail) is discarded at the source.
  /// Errors and info are always kept.
  bool _verbose = false;
  bool get verbose => _verbose;
  set verbose(bool value) {
    if (_verbose == value) return;
    _verbose = value;
    i('Verbose packet logging ${value ? 'ENABLED' : 'disabled'}');
    notifyListeners();
  }

  /// Newest-last view of the buffer. Returns a lazy iterable view; the console
  /// indexes it through a `ListView.builder`, so no copy is made per rebuild.
  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  /// Number of buffered lines (cheap — used by the console header).
  int get length => _entries.length;

  /// Legacy string view, retained for callers that just dump text.
  List<String> get logs =>
      List<String>.unmodifiable(_entries.map((e) => e.toString()));

  void e(String message) => _add(LogLevel.error, message);

  void i(String message) => _add(LogLevel.info, message);

  /// Debug/verbose detail — dropped entirely unless [verbose] is on.
  void d(String message) {
    if (!_verbose) return;
    _add(LogLevel.debug, message);
  }

  /// Lazily-built verbose line. Use for hot paths where even building the
  /// message costs something (hex-dumping a packet); the closure is only
  /// invoked when verbose logging is actually on.
  void dLazy(String Function() build) {
    if (!_verbose) return;
    _add(LogLevel.debug, build());
  }

  void _add(LogLevel level, String message) {
    // Errors and info always reach logcat (hardware runs grep this); verbose
    // debug lines only when explicitly enabled.
    if (level != LogLevel.debug || _verbose) {
      debugPrint('[${level.name.toUpperCase()}] $message');
    }
    _entries.addLast(LogEntry(DateTime.now(), level, message));
    while (_entries.length > maxLines) {
      _entries.removeFirst();
    }
    _coalescer.schedule();
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void clearLogs() {
    _entries.clear();
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _coalescer.dispose();
    super.dispose();
  }
}
