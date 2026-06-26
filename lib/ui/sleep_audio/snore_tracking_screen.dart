import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/sleep_audio_controller.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';

/// Opt-in microphone snoring tracker. First use shows an explicit privacy
/// consent; thereafter a ready/active screen. The mic only runs while a session
/// is explicitly active.
class SnoreTrackingScreen extends StatefulWidget {
  const SnoreTrackingScreen({super.key});

  @override
  State<SnoreTrackingScreen> createState() => _SnoreTrackingScreenState();
}

class _SnoreTrackingScreenState extends State<SnoreTrackingScreen> {
  static const _consentKey = 'sleep_audio_consent_v1';
  bool? _consented; // null = loading

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) {
        setState(() => _consented = p.getBool(_consentKey) ?? false);
      }
    });
  }

  Future<void> _giveConsentAndStart() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_consentKey, true);
    if (!mounted) return;
    setState(() => _consented = true);
    await context.read<SleepAudioController>().start();
  }

  @override
  Widget build(BuildContext context) {
    final audio = context.watch<SleepAudioController>();
    return Scaffold(
      appBar: AppBar(title: const Text('Sleep sounds')),
      body: SafeArea(
        child: _body(audio),
      ),
    );
  }

  Widget _body(SleepAudioController audio) {
    if (audio.state == SleepAudioState.listening) {
      return _Active(audio: audio);
    }
    if (audio.state == SleepAudioState.denied) {
      return _PermissionNeeded(onOpenSettings: audio.openSettings);
    }
    if (_consented == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_consented == false) {
      return _Consent(onAccept: _giveConsentAndStart);
    }
    return _Ready(onStart: () => context.read<SleepAudioController>().start());
  }
}

// ── Consent ─────────────────────────────────────────────────────────────────

class _Consent extends StatelessWidget {
  final VoidCallback onAccept;
  const _Consent({required this.onAccept});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        const SizedBox(height: AppSpacing.sm),
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.mic_rounded,
                color: AppColors.primary, size: 34),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('Track sleep with sound',
            style: AppText.h1, textAlign: TextAlign.center),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Your phone’s microphone can listen for snoring overnight. Before you '
          'start, here’s exactly how it works:',
          style: AppText.body.copyWith(color: AppColors.inkMuted),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.lg),
        const _PrivacyPoint(
          icon: Icons.phone_android_rounded,
          title: 'On your device only',
          body: 'Audio is analysed on this phone as it’s heard. Nothing is sent '
              'anywhere.',
        ),
        const _PrivacyPoint(
          icon: Icons.do_not_disturb_on_rounded,
          title: 'No recordings are kept',
          body: 'No audio is ever saved to storage or uploaded. Only the times '
              'and loudness of snoring are stored.',
        ),
        const _PrivacyPoint(
          icon: Icons.notifications_active_rounded,
          title: 'Always visible while on',
          body: 'A notification shows the whole time the mic is listening. Stop '
              'any time with one tap.',
        ),
        const _PrivacyPoint(
          icon: Icons.group_rounded,
          title: 'Others may be heard',
          body: 'The mic can pick up anyone in the room. Let people sharing the '
              'space know, even though nothing is recorded.',
        ),
        const _PrivacyPoint(
          icon: Icons.health_and_safety_rounded,
          title: 'Not a medical device',
          body: 'This detects sound consistent with snoring — it is not a '
              'diagnosis of any condition.',
        ),
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.md)),
          ),
          onPressed: onAccept,
          child: const Text('I understand — start tracking'),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: Text('Not now',
              style: AppText.label.copyWith(color: AppColors.inkMuted)),
        ),
      ],
    );
  }
}

class _PrivacyPoint extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _PrivacyPoint(
      {required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, color: AppColors.primary, size: 19),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.title),
                const SizedBox(height: 2),
                Text(body,
                    style: AppText.body.copyWith(color: AppColors.inkMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Ready ───────────────────────────────────────────────────────────────────

class _Ready extends StatelessWidget {
  final VoidCallback onStart;
  const _Ready({required this.onStart});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        children: [
          const Spacer(),
          Container(
            width: 96,
            height: 96,
            decoration: const BoxDecoration(
                color: AppColors.primarySoft, shape: BoxShape.circle),
            child: const Icon(Icons.nightlight_round,
                color: AppColors.primary, size: 44),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('Ready for tonight', style: AppText.h1),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Start this when you go to bed. Keep the phone on a surface near you, '
            'screen down or off. Audio stays on this phone.',
            style: AppText.body.copyWith(color: AppColors.inkMuted),
            textAlign: TextAlign.center,
          ),
          const Spacer(),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadii.md)),
            ),
            onPressed: onStart,
            icon: const Icon(Icons.mic_rounded),
            label: const Text('Start sleep tracking'),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    );
  }
}

// ── Active (listening) ──────────────────────────────────────────────────────

class _Active extends StatelessWidget {
  final SleepAudioController audio;
  const _Active({required this.audio});

  @override
  Widget build(BuildContext context) {
    final start = audio.sessionStart;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        children: [
          const Spacer(),
          _PulsingMic(),
          const SizedBox(height: AppSpacing.lg),
          Text('Listening for snoring', style: AppText.h1),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Audio stays on this phone — nothing is saved.',
            style: AppText.label.copyWith(color: AppColors.inkMuted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xl),
          AppCard(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _Stat(
                    label: 'Snore events', value: '${audio.summary.eventCount}'),
                Container(width: 1, height: 34, color: AppColors.divider),
                _Stat(
                    label: 'Snore time',
                    value: '${audio.summary.totalMinutes}m'),
                if (start != null) ...[
                  Container(width: 1, height: 34, color: AppColors.divider),
                  _Stat(label: 'Started', value: _hhmm(start)),
                ],
              ],
            ),
          ),
          const Spacer(),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadii.md)),
            ),
            onPressed: () => audio.stop(),
            icon: const Icon(Icons.stop_rounded),
            label: const Text('Stop tracking'),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    );
  }

  static String _hhmm(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: AppText.metricSm),
        const SizedBox(height: 2),
        Text(label,
            style: AppText.caption.copyWith(color: AppColors.inkMuted)),
      ],
    );
  }
}

class _PulsingMic extends StatefulWidget {
  @override
  State<_PulsingMic> createState() => _PulsingMicState();
}

class _PulsingMicState extends State<_PulsingMic>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = reduced ? 0.5 : _c.value;
        return Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primary.withValues(alpha: 0.10 + t * 0.10),
          ),
          child: Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: const BoxDecoration(
                  color: AppColors.primary, shape: BoxShape.circle),
              child: const Icon(Icons.mic_rounded,
                  color: Colors.white, size: 40),
            ),
          ),
        );
      },
    );
  }
}

// ── Permission needed ───────────────────────────────────────────────────────

class _PermissionNeeded extends StatelessWidget {
  final Future<void> Function() onOpenSettings;
  const _PermissionNeeded({required this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.14),
                shape: BoxShape.circle),
            child: const Icon(Icons.mic_off_rounded,
                color: AppColors.warning, size: 34),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('Microphone permission needed', style: AppText.title),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Sleep-sound tracking needs microphone access. You can grant it in '
            'Settings — it’s only used while a session is running.',
            style: AppText.body.copyWith(color: AppColors.inkMuted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton(
            onPressed: onOpenSettings,
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
  }
}
