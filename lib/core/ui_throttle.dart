import 'dart:async';

/// Rate-limits a repeated callback to at most one invocation per [interval].
///
/// Why: BLE notifications arrive far faster than a screen can usefully redraw —
/// a streaming heart rate fires several times a second, the logger fires once
/// per line, and every one of those used to drive a `notifyListeners()` that
/// rebuilt whole tabs. [Coalescer] collapses a burst of `schedule()` calls into
/// a single trailing invocation, capping UI churn at ~1/[interval] while never
/// dropping the *last* update (which is the one that matters — it carries the
/// current value).
///
/// Leading-edge behaviour: the first `schedule()` after an idle period runs
/// immediately, so a single isolated event (a battery read, a state change)
/// still feels instant. Subsequent calls inside the window are deferred to one
/// trailing invocation.
class Coalescer {
  Coalescer(this.action, {this.interval = const Duration(milliseconds: 250)});

  /// The work to perform (typically `notifyListeners`).
  final void Function() action;

  /// Minimum spacing between two invocations of [action].
  final Duration interval;

  Timer? _timer;
  DateTime? _lastRun;
  bool _disposed = false;

  /// Request an invocation. Runs immediately if the last run was longer than
  /// [interval] ago, otherwise schedules a single trailing run.
  void schedule() {
    if (_disposed) return;
    final now = DateTime.now();
    final last = _lastRun;
    if (last == null || now.difference(last) >= interval) {
      _lastRun = now;
      action();
      return;
    }
    if (_timer != null) return; // a trailing run is already queued
    final wait = interval - now.difference(last);
    _timer = Timer(wait, () {
      _timer = null;
      if (_disposed) return;
      _lastRun = DateTime.now();
      action();
    });
  }

  /// Run any pending trailing invocation right now.
  void flush() {
    if (_disposed) return;
    if (_timer != null) {
      _timer!.cancel();
      _timer = null;
      _lastRun = DateTime.now();
      action();
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}

/// Defers work until the caller stops asking for it for [delay].
///
/// Used for expensive tail-work that must not run per-event — notably persisting
/// the activity store to disk, which JSON-encodes the whole sample history and
/// must never sit in a BLE notify path.
class Debouncer {
  Debouncer({this.delay = const Duration(seconds: 3)});

  final Duration delay;
  Timer? _timer;
  bool _disposed = false;

  void call(void Function() action) {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      if (!_disposed) action();
    });
  }

  /// True when work is queued but not yet executed.
  bool get isPending => _timer != null;

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _disposed = true;
    cancel();
  }
}
