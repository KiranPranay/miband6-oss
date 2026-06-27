/// Shared personalization gate, used by both Sleep and Heart analyses.
///
/// Personal baselines ("your average", "vs last week", personal normal ranges)
/// only use data on/after [cutoff] — when the parsers were fixed (findings-09)
/// and clean capture began — and only once there are at least [minSamples] of
/// them. This prevents confidently-wrong baselines from thin or contaminated
/// history (the discipline that fixed SpO2/sleep). See docs/sleep-baseline.md.
///
/// Note: heart-rate data itself was always reliable (HR byte verified in
/// findings-07); the gate is applied to Heart for the *minimum-sample* guarantee
/// and UI consistency, not because old HR values were wrong.
class Baseline {
  Baseline._();

  static final DateTime cutoff = DateTime(2026, 6, 26);
  static const int minSamples = 7;
}
