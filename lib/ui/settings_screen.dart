import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../core/auth_manager.dart';
import '../core/band_config.dart';
import '../core/band_config_controller.dart';
import '../core/ble_manager.dart';
import 'auth_key_screen.dart';
import 'debug_console.dart';
import 'device_scan_screen.dart';
import 'notifications_screen.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';

/// Settings — one screen, not two.
///
/// There used to be a "Settings" screen (connection, auth key, alerts,
/// developer) that linked to a second "Band settings" screen (measurement,
/// display, goals). Which of the two held a given switch was not guessable,
/// and half of what people came for was a tap deeper than it looked. Everything
/// is here now, grouped by what it changes: the connection first, then how the
/// band measures, then how it looks and behaves, then the phone-side extras.
///
/// Two honesty rules are enforced in the UI, not just the protocol layer:
///
/// * Settings that Mi Band 6 does not support are **absent**, not disabled —
///   SpO2 all-day monitoring and sleep-breathing quality are ZeppOS-only, and a
///   greyed-out switch would imply the feature is nearly there.
/// * Every toggle is optimistic with rollback: it moves immediately, and flips
///   back with an explanation if the band refuses. A switch that stays on while
///   the band ignored the command is a lie.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

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
    final ble = context.watch<BLEManager>();
    final auth = context.watch<AuthManager>();
    final s = config.settings;
    final connected = ble.canConfigure;

    return Scaffold(
      backgroundColor: AppColors.scaffold,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: AppColors.ink),
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 8, 16, 32 + MediaQuery.viewPaddingOf(context).bottom),
        children: [
          _BandStatusCard(bleManager: ble),
          if (!connected) const _OfflineNotice(),
          if (config.lastError != null)
            _ErrorNotice(message: config.lastError!),
          _Section('Connection'),
          _Card(children: [
            _NavTile(
              icon: Icons.bluetooth_searching_rounded,
              title: 'Scan & connect',
              subtitle: ble.device != null
                  ? ble.device!.remoteId.str
                  : 'No band paired',
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const DeviceScanScreen())),
            ),
            const Divider(height: 1),
            _NavTile(
              icon: Icons.key_rounded,
              title: 'Auth key',
              subtitle: auth.hasKey ? 'Set' : 'Not set — pairing will fail',
              subtitleColor:
                  auth.hasKey ? AppColors.success : AppColors.warning,
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const AuthKeyScreen())),
            ),
            if (ble.isConnected) ...[
              const Divider(height: 1),
              _NavTile(
                icon: Icons.link_off_rounded,
                iconColor: AppColors.danger,
                title: 'Disconnect',
                titleColor: AppColors.danger,
                subtitle: 'Stops auto-reconnect until you connect again',
                onTap: () => ble.disconnect(),
              ),
            ],
          ]),
          if (!config.isLoaded)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else ...[
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
                onChanged: (v) => config.setHrHighAlert(v, s.hrHighAlertBpm),
              ),
            ]),
            // Mi Band 6 has no low-HR alert on this protocol path, so none
            // is offered — see protocol-mb6.md §9.

            _Section('Band buttons'),
            _Card(children: [
              _PermissionsTile(),
              const Divider(height: 1),
              _DeclineTextTile(ble: ble),
            ]),
            // Reject/ignore on the wrist end or silence the call on the
            // phone (§12.1); find-phone rings it (§12.2). Neither needs a
            // switch — they work whenever the permissions above are granted.

            _Section('Alerts'),
            _Card(children: [
              _NavTile(
                icon: Icons.notifications_active_outlined,
                iconColor: AppColors.spo2,
                title: 'Notifications',
                subtitle: 'Which apps, calls and messages reach the band',
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const NotificationsScreen())),
              ),
            ]),

            _Section('Experimental'),
            _Card(children: [
              _SwitchTile(
                title: 'Automatic blood oxygen',
                subtitle: 'Asks the band to sample SpO2 on its own. '
                    'Unverified on Mi Band 6 — the band may ignore it. '
                    'Readings, if any, appear on the Sleep screen.',
                value: s.spo2AutoMonitoring,
                onChanged: config.setSpo2AutoMonitoring,
              ),
              const Divider(height: 1),
              _SwitchTile(
                title: 'Quick replies on the band',
                subtitle: 'Offer canned texts when declining a call from '
                    'the wrist. Unverified on Mi Band 6.',
                value: s.cannedRepliesEnabled,
                onChanged: config.setCannedRepliesEnabled,
              ),
              if (s.cannedRepliesEnabled) ...[
                const Divider(height: 1),
                _CannedRepliesTile(config: config),
              ],
            ]),

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
                    style: AppText.caption.copyWith(color: AppColors.inkMuted)),
                trailing: const Icon(Icons.nightlight_round,
                    color: Color(0xFF6366F1)),
                onTap: () async {
                  await ble.enterSleepCaptureMode();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content:
                          Text('Band set to overnight capture — 1-minute heart '
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
          ],
          _Section('Developer'),
          _Card(children: [
            _NavTile(
              icon: Icons.terminal_rounded,
              title: 'Debug console',
              subtitle: 'Every frame the band sends and receives',
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const DebugConsole())),
            ),
            const Divider(height: 1),
            _NavTile(
              icon: ble.isTestSessionRunning
                  ? Icons.hourglass_top_rounded
                  : Icons.science_outlined,
              iconColor: ble.isTestSessionRunning
                  ? AppColors.warning
                  : AppColors.activity,
              title: 'Run hardware test',
              subtitle: ble.isTestSessionRunning
                  ? 'Running gates 0→6 — watch the console'
                  : 'Verify heart rate, battery and fetch on the band (wear it first)',
              onTap: () => _onRunHardwareTest(context, ble),
            ),
            const Divider(height: 1),
            _NavTile(
              icon: Icons.send_rounded,
              iconColor: AppColors.spo2,
              title: 'Send a test notification',
              onTap: () => _onSendTestNotification(context, ble),
            ),
          ]),
          const SizedBox(height: 16),
          if (config.lastAppliedAt != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Band settings are re-sent every time it reconnects, '
                'so they survive a band reset.',
                style: AppText.caption.copyWith(color: AppColors.inkFaint),
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

/// Phone permissions the band's buttons need. Requested here, on demand, with
/// the reason next to the button — not at first launch.
class _PermissionsTile extends StatefulWidget {
  @override
  State<_PermissionsTile> createState() => _PermissionsTileState();
}

class _PermissionsTileState extends State<_PermissionsTile> {
  Map<String, bool> _granted = const {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final ble = context.read<BLEManager>();
    final g = await ble.callControl.permissions();
    if (mounted) setState(() => _granted = g);
  }

  Future<void> _request() async {
    await [
      Permission.phone,
      Permission.sms,
    ].request();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final calls = _granted['answerPhoneCalls'] == true;
    final sms = _granted['sendSms'] == true;
    final all = calls && sms;
    return ListTile(
      title: Text('Phone permissions', style: AppText.body),
      subtitle: Text(
        all
            ? 'Granted — the band can decline, silence and reply to calls'
            : 'Needed for the band\'s call buttons to act on the phone: '
                '${calls ? '' : 'phone calls'}'
                '${!calls && !sms ? ', ' : ''}'
                '${sms ? '' : 'SMS'}',
        style: AppText.caption.copyWith(color: AppColors.inkMuted),
      ),
      trailing: all
          ? Icon(Icons.check_circle_rounded, color: AppColors.success)
          : TextButton(onPressed: _request, child: const Text('Grant')),
    );
  }
}

/// Decline-with-text (§13.3): phone-side, works today, no band bytes.
class _DeclineTextTile extends StatelessWidget {
  const _DeclineTextTile({required this.ble});
  final BLEManager ble;

  Future<void> _edit(BuildContext context) async {
    final ctrl = TextEditingController(text: ble.declineText ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reply when declining'),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          maxLength: 160,
          decoration: const InputDecoration(
            hintText: "Can't talk now — I'll call you back.",
            helperText: 'Sent by SMS to the caller when you decline from the '
                'band. Leave empty to turn off.',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (result != null) await ble.setDeclineText(result);
  }

  @override
  Widget build(BuildContext context) {
    final text = context.watch<BLEManager>().declineText;
    return ListTile(
      title: Text('Reply with a text when I decline', style: AppText.body),
      subtitle: Text(
        text == null
            ? 'Off'
            : '"$text" — sent only when the call notification showed a number',
        style: AppText.caption.copyWith(color: AppColors.inkMuted),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Icon(Icons.chevron_right, color: AppColors.inkFaint),
      onTap: () => _edit(context),
    );
  }
}

/// The canned replies sent to the band while the experimental switch is on.
class _CannedRepliesTile extends StatelessWidget {
  const _CannedRepliesTile({required this.config});
  final BandConfigController config;

  Future<void> _edit(BuildContext context) async {
    final ctrl =
        TextEditingController(text: config.settings.cannedReplies.join('\n'));
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quick replies'),
        content: TextField(
          controller: ctrl,
          maxLines: 6,
          decoration: const InputDecoration(
            helperText:
                'One per line, up to 16. Sent to the band the next time '
                'settings are applied.',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (result != null) {
      await config.setCannedReplies(result.split('\n'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = config.settings.cannedReplies;
    return ListTile(
      title: Text('Replies', style: AppText.body),
      subtitle: Text(
        list.isEmpty ? 'None' : list.join(' · '),
        style: AppText.caption.copyWith(color: AppColors.inkMuted),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Icon(Icons.chevron_right, color: AppColors.inkFaint),
      onTap: () => _edit(context),
    );
  }
}

void _onSendTestNotification(BuildContext context, BLEManager bleManager) {
  final messenger = ScaffoldMessenger.of(context);
  if (!bleManager.isConnected ||
      bleManager.authState != AuthState.authenticated) {
    messenger.showSnackBar(const SnackBar(
      content: Text('Connect & authenticate the band first'),
    ));
    return;
  }
  bleManager.alertManager.sendTest();
  messenger.showSnackBar(const SnackBar(
    content: Text('Test notification sent — check your band'),
  ));
}

void _onRunHardwareTest(BuildContext context, BLEManager bleManager) {
  final messenger = ScaffoldMessenger.of(context);
  if (bleManager.isTestSessionRunning) {
    messenger.showSnackBar(const SnackBar(
      content: Text('Hardware test already running — see Debug Log'),
    ));
    return;
  }
  if (!bleManager.isConnected ||
      bleManager.authState != AuthState.authenticated) {
    messenger.showSnackBar(const SnackBar(
      content: Text('Connect & authenticate the band first'),
    ));
    return;
  }
  // Fire-and-forget; the session logs MB6TEST banners to the Debug Log.
  bleManager.runHardwareTestSession();
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const DebugConsole()),
  );
}

class _BandStatusCard extends StatelessWidget {
  final BLEManager bleManager;
  const _BandStatusCard({required this.bleManager});

  @override
  Widget build(BuildContext context) {
    final connected = bleManager.isConnected;
    final authState = bleManager.authState;
    final device = bleManager.device;
    final battery = bleManager.batteryLevel;

    String authLabel;
    Color authColor;
    switch (authState) {
      case AuthState.authenticating:
        authLabel = 'Authenticating…';
        authColor = AppColors.warning;
        break;
      case AuthState.authenticated:
        authLabel = 'Authenticated';
        authColor = AppColors.success;
        break;
      case AuthState.failed:
        authLabel = 'Failed';
        authColor = AppColors.danger;
        break;
      default:
        authLabel = 'Not Authenticated';
        authColor = AppColors.inkMuted;
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        color: AppColors.surface,
        boxShadow: AppShadows.card,
        border: Border.all(
          color: connected
              ? AppColors.success.withValues(alpha: 0.3)
              : AppColors.divider,
        ),
      ),
      child: Column(
        children: [
          // ── Top row: name + battery ──────────────────────────────
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.watch, color: AppColors.inkMuted, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device?.platformName.isNotEmpty == true
                          ? device!.platformName
                          : 'Mi Band',
                      style: TextStyle(
                        color: AppColors.ink,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (device != null)
                      Text(
                        device.remoteId.str,
                        style: TextStyle(
                          color: AppColors.inkFaint,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
              if (battery != null)
                _BatteryWidget(level: battery)
              else if (connected)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.inkFaint),
                ),
            ],
          ),

          const SizedBox(height: 16),
          Divider(color: AppColors.divider, height: 1),
          const SizedBox(height: 16),

          // ── Status rows ──────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: _StatusPill(
                  label: 'Connection',
                  value: connected ? 'Connected' : 'Disconnected',
                  color: connected ? AppColors.success : AppColors.danger,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatusPill(
                  label: 'Auth',
                  value: authLabel,
                  color: authColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A row that opens another screen — same shape as [_ChoiceTile] so the
/// merged list reads as one family.
class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.iconColor,
    this.titleColor,
    this.subtitleColor,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? iconColor;
  final Color? titleColor;
  final Color? subtitleColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon, color: iconColor ?? AppColors.inkMuted, size: 22),
        title: Text(title,
            style: AppText.body.copyWith(color: titleColor ?? AppColors.ink)),
        subtitle: subtitle == null
            ? null
            : Text(subtitle!,
                style: AppText.caption
                    .copyWith(color: subtitleColor ?? AppColors.inkMuted)),
        trailing: Icon(Icons.chevron_right, color: AppColors.inkFaint),
        onTap: onTap,
      );
}

class _BatteryWidget extends StatelessWidget {
  final int level;
  const _BatteryWidget({required this.level});

  @override
  Widget build(BuildContext context) {
    final color = level > 50
        ? AppColors.success
        : level > 20
            ? AppColors.warning
            : AppColors.danger;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          level > 80
              ? Icons.battery_full
              : level > 50
                  ? Icons.battery_4_bar
                  : level > 20
                      ? Icons.battery_2_bar
                      : Icons.battery_1_bar,
          color: color,
          size: 20,
        ),
        const SizedBox(width: 2),
        Text(
          '$level%',
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StatusPill({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: color.withValues(alpha: 0.7),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
