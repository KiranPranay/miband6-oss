import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/band_config.dart';
import '../core/band_config_controller.dart';
import '../core/ble_manager.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';

/// Band settings — the things that change how the *band itself* behaves.
///
/// Grouped rather than listed flat (Hick's law: fewer decisions per glance),
/// with the measurement settings first because they are what people come here
/// to change.
///
/// Two honesty rules are enforced in the UI, not just the protocol layer:
///
/// * Settings that Mi Band 6 does not support are **absent**, not disabled —
///   SpO2 all-day monitoring and sleep-breathing quality are ZeppOS-only, and a
///   greyed-out switch would imply the feature is nearly there.
/// * Every toggle is optimistic with rollback: it moves immediately, and flips
///   back with an explanation if the band refuses. A switch that stays on while
///   the band ignored the command is a lie.
class BandSettingsScreen extends StatelessWidget {
  const BandSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ble = context.read<BLEManager>();
    return ChangeNotifierProvider<BandConfigController>.value(
      value: ble.bandConfig,
      child: const _BandSettingsBody(),
    );
  }
}

class _BandSettingsBody extends StatelessWidget {
  const _BandSettingsBody();

  @override
  Widget build(BuildContext context) {
    final config = context.watch<BandConfigController>();
    final ble = context.read<BLEManager>();
    final s = config.settings;
    final connected = ble.canConfigure;

    return Scaffold(
      backgroundColor: AppColors.scaffold,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: AppColors.ink),
        title: Text('Band settings', style: AppText.h1),
      ),
      body: !config.isLoaded
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                if (!connected) const _OfflineNotice(),
                if (config.lastError != null)
                  _ErrorNotice(message: config.lastError!),

                _Section('Measurement'),
                _Card(children: [
                  _ChoiceTile<HrInterval>(
                    title: 'Automatic heart rate',
                    subtitle: 'How often the band measures on its own',
                    value: s.hrInterval,
                    options: HrInterval.values,
                    labelOf: (v) => v.label,
                    onChanged: config.setHrInterval,
                  ),
                  const Divider(height: 1),
                  _SwitchTile(
                    title: 'All-day heart rate',
                    subtitle: 'Continuous background monitoring',
                    value: s.hrAllDayMonitoring,
                    onChanged: config.setHrAllDayMonitoring,
                  ),
                  const Divider(height: 1),
                  _SwitchTile(
                    title: 'Sleep-assisted heart rate',
                    subtitle: 'Denser sampling while you sleep — improves the '
                        'sleep stage estimate',
                    value: s.hrSleepAssisted,
                    onChanged: config.setHrSleepAssisted,
                  ),
                  const Divider(height: 1),
                  _SwitchTile(
                    title: 'All-day stress',
                    subtitle: 'Lets the band record its own stress samples',
                    value: s.stressMonitoring,
                    onChanged: config.setStressMonitoring,
                  ),
                  const Divider(height: 1),
                  _SwitchTile(
                    title: 'High heart-rate alert',
                    subtitle: s.hrHighAlertEnabled
                        ? 'Buzz above ${s.hrHighAlertBpm} bpm'
                        : 'Off',
                    value: s.hrHighAlertEnabled,
                    onChanged: (v) =>
                        config.setHrHighAlert(v, s.hrHighAlertBpm),
                  ),
                ]),
                // Mi Band 6 has no low-HR alert on this protocol path, so none
                // is offered — see protocol-mb6.md §9.

                _Section('Display'),
                _Card(children: [
                  _ChoiceTile<TimeFormat>(
                    title: 'Time format',
                    value: s.timeFormat,
                    options: TimeFormat.values,
                    labelOf: (v) =>
                        v == TimeFormat.twentyFourHour ? '24-hour' : '12-hour',
                    onChanged: config.setTimeFormat,
                  ),
                  const Divider(height: 1),
                  _ChoiceTile<DistanceUnit>(
                    title: 'Units',
                    value: s.distanceUnit,
                    options: DistanceUnit.values,
                    labelOf: (v) =>
                        v == DistanceUnit.metric ? 'Metric' : 'Imperial',
                    onChanged: config.setDistanceUnit,
                  ),
                  const Divider(height: 1),
                  _ChoiceTile<WearWrist>(
                    title: 'Worn on',
                    subtitle: 'Improves lift-to-wake accuracy',
                    value: s.wearWrist,
                    options: WearWrist.values,
                    labelOf: (v) => v == WearWrist.left ? 'Left' : 'Right',
                    onChanged: config.setWearWrist,
                  ),
                  const Divider(height: 1),
                  _ChoiceTile<LiftWristMode>(
                    title: 'Lift wrist to wake',
                    value: s.liftWrist,
                    options: LiftWristMode.values,
                    labelOf: (v) => switch (v) {
                      LiftWristMode.off => 'Off',
                      LiftWristMode.always => 'Always',
                      LiftWristMode.scheduled => 'Scheduled',
                    },
                    onChanged: config.setLiftWrist,
                  ),
                  const Divider(height: 1),
                  _ChoiceTile<NightMode>(
                    title: 'Night mode',
                    subtitle: 'Dims the screen',
                    value: s.nightMode,
                    options: NightMode.values,
                    labelOf: (v) => switch (v) {
                      NightMode.off => 'Off',
                      NightMode.sunset => 'At sunset',
                      NightMode.scheduled => 'Scheduled',
                    },
                    onChanged: config.setNightMode,
                  ),
                ]),

                _Section('Overnight'),
                _Card(children: [
                  ListTile(
                    title: Text('Prepare for sleep', style: AppText.body),
                    subtitle: Text(
                        'Stops live heart-rate streaming and lets the band '
                        'record the night itself at 1-minute intervals. Far '
                        'kinder to the battery, and it is what fills in the '
                        'sleep and stress history.',
                        style: AppText.caption
                            .copyWith(color: AppColors.inkMuted)),
                    trailing: const Icon(Icons.nightlight_round,
                        color: Color(0xFF6366F1)),
                    onTap: () async {
                      await ble.enterSleepCaptureMode();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                              'Band set to overnight capture — 1-minute heart '
                              'rate, sleep-assisted, stress recording on.'),
                        ),
                      );
                    },
                  ),
                ]),

                _Section('Goals & reminders'),
                _Card(children: [
                  _StepGoalTile(
                    goal: s.stepGoal,
                    onChanged: config.setStepGoal,
                  ),
                  const Divider(height: 1),
                  _SwitchTile(
                    title: 'Celebrate reaching your goal',
                    subtitle: 'The band buzzes when you hit your step goal',
                    value: s.goalNotification,
                    onChanged: config.setGoalNotification,
                  ),
                  const Divider(height: 1),
                  _SwitchTile(
                    title: 'Move reminders',
                    subtitle: s.inactivityEnabled
                        ? 'After ${s.inactivityThresholdMinutes} min of sitting'
                        : 'Off',
                    value: s.inactivityEnabled,
                    onChanged: config.setInactivityEnabled,
                  ),
                  const Divider(height: 1),
                  _ChoiceTile<DndMode>(
                    title: 'Do not disturb',
                    value: s.dnd,
                    options: DndMode.values,
                    labelOf: (v) => switch (v) {
                      DndMode.off => 'Off',
                      DndMode.automatic => 'Automatic',
                      DndMode.scheduled => 'Scheduled',
                    },
                    onChanged: config.setDnd,
                  ),
                ]),

                const SizedBox(height: 16),
                if (config.lastAppliedAt != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      'Settings are re-sent to the band every time it '
                      'reconnects, so they survive a band reset.',
                      style: AppText.caption
                          .copyWith(color: AppColors.inkFaint),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _OfflineNotice extends StatelessWidget {
  const _OfflineNotice();

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 18, color: AppColors.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Band not connected. Changes are saved and applied as soon as '
                'it reconnects.',
                style: AppText.caption.copyWith(color: AppColors.ink),
              ),
            ),
          ],
        ),
      );
}

class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.danger.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 18, color: AppColors.danger),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message,
                  style: AppText.caption.copyWith(color: AppColors.ink)),
            ),
          ],
        ),
      );
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(title.toUpperCase(),
            style: AppText.caption.copyWith(
              color: AppColors.inkFaint,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
            )),
      );
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          boxShadow: AppShadows.card,
        ),
        child: Column(children: children),
      );
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final Future<bool> Function(bool) onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
        value: value,
        title: Text(title, style: AppText.body),
        subtitle: subtitle == null
            ? null
            : Text(subtitle!,
                style: AppText.caption.copyWith(color: AppColors.inkMuted)),
        onChanged: (v) => onChanged(v),
      );
}

/// A setting with a small set of choices, shown as a bottom sheet.
///
/// Chosen over an inline segmented control because several of these have three
/// or more options with long labels; a sheet keeps each row scannable.
class _ChoiceTile<T> extends StatelessWidget {
  const _ChoiceTile({
    required this.title,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final Future<bool> Function(T) onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(title, style: AppText.body),
        subtitle: subtitle == null
            ? null
            : Text(subtitle!,
                style: AppText.caption.copyWith(color: AppColors.inkMuted)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(labelOf(value),
                style: AppText.body.copyWith(color: AppColors.primary)),
            Icon(Icons.chevron_right, color: AppColors.inkFaint),
          ],
        ),
        onTap: () async {
          final picked = await showModalBottomSheet<T>(
            context: context,
            backgroundColor: AppColors.surface,
            shape: const RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.vertical(top: Radius.circular(AppRadii.lg)),
            ),
            builder: (ctx) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(title, style: AppText.title),
                  ),
                  for (final o in options)
                    ListTile(
                      title: Text(labelOf(o), style: AppText.body),
                      trailing: o == value
                          ? Icon(Icons.check, color: AppColors.primary)
                          : null,
                      onTap: () => Navigator.pop(ctx, o),
                    ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
          if (picked != null && picked != value) await onChanged(picked);
        },
      );
}

class _StepGoalTile extends StatelessWidget {
  const _StepGoalTile({required this.goal, required this.onChanged});

  final int goal;
  final Future<bool> Function(int) onChanged;

  static const _options = [5000, 7500, 10000, 12500, 15000, 20000];

  @override
  Widget build(BuildContext context) => _ChoiceTile<int>(
        title: 'Daily step goal',
        value: _options.contains(goal) ? goal : 10000,
        options: _options,
        labelOf: (v) => '$v steps',
        onChanged: onChanged,
      );
}
