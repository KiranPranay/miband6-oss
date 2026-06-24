import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/notification_relay.dart';

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
      backgroundColor: const Color(0xFF0F0F1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F1A),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white70),
        title: const Text('Notifications',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            tooltip: 'Reload apps',
            icon: const Icon(Icons.refresh, color: Colors.white60),
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
              style: const TextStyle(color: Colors.white),
              onChanged: (v) => setState(() => _query = v.toLowerCase()),
              decoration: InputDecoration(
                hintText: 'Search apps…',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF1A1A2E),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                Text('Apps to forward (${relay.selectedCount} selected)',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 12)),
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
                        activeColor: Colors.lightGreenAccent,
                        checkColor: Colors.black,
                        title: Text(app.name,
                            style: const TextStyle(color: Colors.white)),
                        subtitle: Text(app.package,
                            style: const TextStyle(
                                color: Colors.white30, fontSize: 11)),
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
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(granted ? Icons.check_circle : Icons.error_outline,
              color: granted ? Colors.lightGreenAccent : Colors.amberAccent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    granted
                        ? 'Notification access granted'
                        : 'Notification access needed',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                    granted
                        ? 'The app can read notifications to forward them.'
                        : 'Grant access so the app can read notifications.',
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 12)),
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
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(14),
      ),
      child: SwitchListTile(
        value: relay.enabled,
        onChanged: (v) => relay.setEnabled(v),
        activeColor: Colors.lightGreenAccent,
        title: const Text('Forward notifications to band',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        subtitle: const Text('Selected apps below will alert your band',
            style: TextStyle(color: Colors.white38, fontSize: 12)),
      ),
    );
  }
}
