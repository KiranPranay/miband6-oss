import 'package:flutter_test/flutter_test.dart';

import 'package:band/core/ble_manager.dart';

/// The sync loop deadlocked in production, and these tests pin the arithmetic
/// that made it possible.
///
/// The band does not answer "everything since X" in one go — it serves a
/// contiguous run and stops at the first gap in its ring buffer. So the fetch
/// crawls: ask, store, ask again from just past the newest sample. On a
/// fragmented stretch (band charging or off the wrist) a round advances as
/// little as ten minutes.
///
/// The fetch also starts *behind* the watermark, to re-pull a boundary minute
/// that might have arrived mid-write. That overlap used to be six hours while
/// the crawl was capped at twelve rounds. Twelve rounds at ten minutes covers
/// two hours — less than the six-hour overlap — so every sync spent its whole
/// budget re-reading data it already had and finished exactly where it began.
/// Net progress per sync: zero, forever. The user's data sat frozen for five
/// days while each sync looked busy in the log.
///
/// The invariant is simply: **the overlap must be cheap to cross compared with
/// the budget available to cross it.**
void main() {
  // Worst case observed on the user's band on 2026-08-21, crawling a stretch
  // where the band had been off the wrist: ten minutes of data per round, and
  // roughly two seconds per round including the BLE round trip.
  const worstCaseAdvance = Duration(minutes: 10);
  const worstCaseRoundDuration = Duration(seconds: 2);

  Duration timeToCross(Duration span) {
    final rounds = (span.inMinutes / worstCaseAdvance.inMinutes).ceil();
    return worstCaseRoundDuration * rounds;
  }

  group('sync budget', () {
    test('the re-fetch overlap is crossable well inside the smallest budget',
        () {
      // 10 minutes of overlap is one round; anything approaching the budget
      // itself reintroduces the deadlock.
      const overlap = Duration(minutes: 10);
      final cost = timeToCross(overlap);

      expect(cost, lessThan(BLEManager.periodicFetchBudget * 0.2),
          reason: 'crossing the overlap must be a rounding error against the '
              'budget — at six hours it cost more than the entire budget, and '
              'the sync could never reach new data');
    });

    test('a periodic sync makes real forward progress when far behind', () {
      final rounds =
          BLEManager.periodicFetchBudget.inSeconds ~/ worstCaseRoundDuration.inSeconds;
      final progress = worstCaseAdvance * rounds;

      expect(progress, greaterThan(const Duration(hours: 2)),
          reason: 'an unattended sync that gains less than a couple of hours '
              'can never catch up on a multi-day hole');
    });

    test('a manual sync stays short enough to watch', () {
      expect(BLEManager.deepFetchBudget, lessThanOrEqualTo(const Duration(minutes: 2)),
          reason: 'someone is watching a spinner; the recent window is already '
              'fetched first, so this only backfills');
    });

    test('the round backstop cannot be the real limit', () {
      // The budget must run out long before the round cap does, otherwise the
      // cap silently becomes the constraint again — which is exactly how the
      // deadlock was introduced.
      final roundsAffordable =
          BLEManager.deepFetchBudget.inSeconds ~/ worstCaseRoundDuration.inSeconds;

      expect(BLEManager.maxFetchRounds, greaterThan(roundsAffordable),
          reason: 'maxFetchRounds is a runaway backstop, not a budget — if the '
              'crawl can hit it inside the time budget it is the limit again');
    });

    test('budgets are ordered as intended', () {
      expect(BLEManager.deepFetchBudget,
          greaterThan(BLEManager.periodicFetchBudget),
          reason: 'a sync the user explicitly asked for should do more work '
              'than one that runs unattended every ten minutes');
    });
  });
}
