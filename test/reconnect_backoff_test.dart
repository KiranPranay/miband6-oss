import 'dart:math';

import 'package:band/core/reconnect_backoff.dart';
import 'package:flutter_test/flutter_test.dart';

/// A `Random` that always returns the midpoint, so jitter contributes exactly
/// zero and the schedule can be asserted exactly.
class _NoJitterRandom implements Random {
  @override
  double nextDouble() => 0.5; // → (0.5*2 - 1) == 0
  @override
  bool nextBool() => false;
  @override
  int nextInt(int max) => 0;
}

/// Always returns the extreme, giving the maximum positive jitter.
class _MaxJitterRandom implements Random {
  @override
  double nextDouble() => 1.0; // → (1.0*2 - 1) == +1
  @override
  bool nextBool() => true;
  @override
  int nextInt(int max) => max - 1;
}

/// Always returns the other extreme, giving the maximum negative jitter.
class _MinJitterRandom implements Random {
  @override
  double nextDouble() => 0.0; // → (0.0*2 - 1) == -1
  @override
  bool nextBool() => false;
  @override
  int nextInt(int max) => 0;
}

void main() {
  group('ReconnectBackoff', () {
    test('follows the 1/2/5/15/30/60 s schedule', () {
      final b = ReconnectBackoff(random: _NoJitterRandom());
      final seconds = List.generate(6, (_) => b.next().inMilliseconds / 1000);
      expect(seconds, [1, 2, 5, 15, 30, 60]);
    });

    test('holds at the cap and retries indefinitely', () {
      final b = ReconnectBackoff(random: _NoJitterRandom());
      for (var i = 0; i < 6; i++) {
        b.next();
      }
      // A band out of range for an hour must still be retried — forever, but
      // no faster than the cap.
      for (var i = 0; i < 100; i++) {
        expect(b.next().inMilliseconds, 60000);
      }
      expect(b.attempt, 106);
    });

    test('jitter stays within ±20% of the base delay', () {
      for (final random in [_MaxJitterRandom(), _MinJitterRandom()]) {
        final b = ReconnectBackoff(random: random);
        b.next(); // 1 s
        b.next(); // 2 s
        b.next(); // 5 s
        final d = b.next(); // base 15 s
        expect(d.inMilliseconds, inInclusiveRange(12000, 18000));
      }
    });

    test('never returns a non-positive delay even at max negative jitter', () {
      final b = ReconnectBackoff(
        schedule: const [1],
        jitterFraction: 0.99,
        random: _MinJitterRandom(),
      );
      for (var i = 0; i < 10; i++) {
        expect(b.next().inMilliseconds, greaterThan(0));
      }
    });

    test('reset returns to the bottom of the schedule', () {
      final b = ReconnectBackoff(random: _NoJitterRandom());
      for (var i = 0; i < 5; i++) {
        b.next();
      }
      expect(b.attempt, 5);

      // A successful connection must not leave the next unrelated drop
      // inheriting a 60 s penalty.
      b.reset();
      expect(b.attempt, 0);
      expect(b.next().inMilliseconds, 1000);
    });

    test('currentBase reports the delay the next call would use', () {
      final b = ReconnectBackoff(random: _NoJitterRandom());
      expect(b.currentBase, const Duration(seconds: 1));
      b.next();
      expect(b.currentBase, const Duration(seconds: 2));
    });

    test('a custom schedule is honoured', () {
      final b = ReconnectBackoff(
          schedule: const [3, 7], jitterFraction: 0, random: _NoJitterRandom());
      expect(b.next(), const Duration(seconds: 3));
      expect(b.next(), const Duration(seconds: 7));
      expect(b.next(), const Duration(seconds: 7));
    });
  });
}
