import 'dart:math';

/// Exponential-backoff schedule with jitter for connection retries.
///
/// Extracted from the supervisor so the policy is unit-testable on its own.
///
/// The previous strategy was a fixed 3 s retry that, on error, re-armed itself
/// after 5 s — so a band that was simply out of range was hammered at a roughly
/// constant rate for as long as it stayed away, and an adapter that had been
/// switched off produced a tight failing loop. This schedule instead steps
/// 1 → 2 → 5 → 15 → 30 → 60 s and then holds at 60 s, retrying indefinitely:
/// a band out of range for an hour must still reconnect by itself the moment it
/// returns, but must not spend the battery trying every second meanwhile.
///
/// Jitter (±[jitterFraction]) prevents several clients — or a reconnect storm
/// after a Bluetooth adapter toggle — from retrying in lockstep.
class ReconnectBackoff {
  ReconnectBackoff({
    this.schedule = const [1, 2, 5, 15, 30, 60],
    this.jitterFraction = 0.2,
    Random? random,
  })  : assert(schedule.isNotEmpty, 'schedule must not be empty'),
        assert(jitterFraction >= 0 && jitterFraction < 1),
        _random = random ?? Random();

  /// Delay in seconds per consecutive failure; the last entry is the cap.
  final List<int> schedule;

  /// Fraction of the base delay applied as ± random jitter.
  final double jitterFraction;

  final Random _random;

  int _attempt = 0;

  /// Number of consecutive failures recorded so far.
  int get attempt => _attempt;

  /// The base (un-jittered) delay that [next] would currently produce.
  Duration get currentBase => Duration(seconds: _baseSecondsFor(_attempt));

  int _baseSecondsFor(int attempt) =>
      schedule[attempt < schedule.length ? attempt : schedule.length - 1];

  /// Returns the delay to wait before the next attempt and advances the
  /// schedule. Never returns a non-positive duration.
  Duration next() {
    final base = _baseSecondsFor(_attempt) * 1000;
    _attempt++;
    final jitter = (base * jitterFraction * (_random.nextDouble() * 2 - 1)).round();
    return Duration(milliseconds: max(250, base + jitter));
  }

  /// Call after a successful connection, so an unrelated later drop starts
  /// again at the bottom of the schedule instead of inheriting a 60 s penalty.
  void reset() => _attempt = 0;
}
