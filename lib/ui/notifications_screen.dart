import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/notification_relay.dart';
import 'theme/tokens.dart';
import 'theme/app_theme.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen>
    with WidgetsBindingObserver {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final relay = context.read<NotificationRelay>();
    relay.refreshAccess();
    if (relay.installedApps.isEmpty) relay.refreshInstalledApps();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user grants access in system settings then returns — re-check.
    if (state == AppLifecycleState.resumed) {
      context.read<NotificationRelay>().refreshAccess();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final relay = context.watch<NotificationRelay>();
    final apps = _query.isEmpty
        ? relay.installedApps
        : relay.installedApps
            .where((a) =>
                a.name.toLowerCase().contains(_query) ||
                a.package.toLowerCase().contains(_query))
            .toList();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.ink),
        title: Text('Notifications',
            style: AppText.title.copyWith(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'Reload apps',
            icon: const Icon(Icons.refresh, color: AppColors.inkMuted),
            onPressed: () => relay.refreshInstalledApps(),
          ),
        ],
      ),
      body: Column(
        children: [
          _AccessCard(relay: relay),
          _EnableCard(relay: relay),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              style: AppText.body,
              onChanged: (v) => setState(() => _query = v.toLowerCase()),
              decoration: InputDecoration(
                hintText: 'Search apps…',
                hintStyle: const TextStyle(color: AppColors.inkFaint),
                prefixIcon: const Icon(Icons.search, color: AppColors.inkFaint),
                filled: true,
                fillColor: AppColors.surface,
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  borderSide: const BorderSide(color: AppColors.primary),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                Text('Apps to forward (${relay.selectedCount} selected)',
                    style: AppText.caption),
              ],
            ),
          ),
          Expanded(
            child: relay.isLoadingApps && apps.isEmpty
                ? const Center(
                    child: CircularProgressIndicator(strokeWidth: 2))
                : ListView.builder(
                    itemCount: apps.length,
                    itemBuilder: (context, i) {
                      final app = apps[i];
                      final selected = relay.isAppSelected(app.package);
                      return CheckboxListTile(
                        value: selected,
                        onChanged: relay.enabled
                            ? (v) =>
                                relay.setAppSelected(app.package, v ?? false)
                            : null,
                        activeColor: AppColors.primary,
                        checkColor: Colors.white,
                        title: Text(app.name, style: AppText.body),
                        subtitle: Text(app.package,
                            style: AppText.caption
                                .copyWith(color: AppColors.inkFaint)),
                        controlAffinity: ListTileControlAffinity.trailing,
                        dense: true,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _AccessCard extends StatelessWidget {
  final NotificationRelay relay;
  const _AccessCard({required this.relay});

  @override
  Widget build(BuildContext context) {
    final granted = relay.accessGranted;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        boxShadow: AppShadows.card,
      ),
      child: Row(
        children: [
          Icon(granted ? Icons.check_circle : Icons.error_outline,
              color: granted ? AppColors.success : AppColors.warning),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    granted
                        ? 'Notification access granted'
                        : 'Notification access needed',
                    style: AppText.title),
                const SizedBox(height: 2),
                Text(
                    granted
                        ? 'The app can read notifications to forward them.'
                        : 'Grant access so the app can read notifications.',
                    style: AppText.caption
                        .copyWith(color: AppColors.inkMuted)),
              ],
            ),
          ),
          if (!granted)
            TextButton(
              onPressed: () => relay.openAccessSettings(),
              child: const Text('Grant'),
            ),
        ],
      ),
    );
  }
}

class _EnableCard extends StatelessWidget {
  final NotificationRelay relay;
  const _EnableCard({required this.relay});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        boxShadow: AppShadows.card,
      ),
      child: SwitchListTile(
        value: relay.enabled,
        onChanged: (v) => relay.setEnabled(v),
        activeThumbColor: AppColors.primary,
        title: Text('Forward notifications to band', style: AppText.title),
        subtitle: Text('Selected apps below will alert your band',
            style: AppText.caption.copyWith(color: AppColors.inkMuted)),
      ),
    );
  }
}
