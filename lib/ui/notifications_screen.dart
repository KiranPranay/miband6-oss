import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/notification_relay.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';
import 'widgets/settings_widgets.dart';

/// Which phone notifications reach the band.
///
/// Speaks the same grammar as Settings — overline group labels, one surface per
/// group, hairline-divided rows — because it is reached *from* Settings and
/// used to look like a different app once you got here.
///
/// Search takes the screen over: while the field has focus or holds a query,
/// the access and forwarding groups fold away so the matches sit directly
/// under the field, above the keyboard, instead of below the fold. The whole
/// thing is one scroll view, so a tall keyboard can never push content off a
/// fixed column (which was the overflow).
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen>
    with WidgetsBindingObserver {
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _searchFocus.addListener(() => setState(() {}));
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
    _searchFocus.dispose();
    super.dispose();
  }

  bool get _searching => _searchFocus.hasFocus || _query.isNotEmpty;

  void _clearSearch() {
    _searchCtrl.clear();
    _searchFocus.unfocus();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    final relay = context.watch<NotificationRelay>();
    final all = relay.installedApps;
    final apps = _query.isEmpty
        ? all
        : all
            .where((a) =>
                a.name.toLowerCase().contains(_query) ||
                a.package.toLowerCase().contains(_query))
            .toList();

    final String listLabel;
    if (_query.isNotEmpty) {
      listLabel = apps.length == 1
          ? '1 match · ${relay.selectedCount} selected'
          : '${apps.length} matches · ${relay.selectedCount} selected';
    } else {
      listLabel = 'Apps to forward · ${relay.selectedCount} selected';
    }

    return Scaffold(
      backgroundColor: AppColors.scaffold,
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          IconButton(
            tooltip: 'Reload apps',
            icon: Icon(Icons.refresh_rounded, color: AppColors.inkMuted),
            onPressed: () => relay.refreshInstalledApps(),
          ),
        ],
      ),
      body: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedSize(
                    duration: AppMotion.medium,
                    curve: AppMotion.ease,
                    alignment: Alignment.topCenter,
                    child: _searching
                        ? const SizedBox(width: double.infinity)
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SectionLabel('Access'),
                              _AccessGroup(relay: relay),
                              const SectionLabel('Forwarding'),
                              _ForwardingGroup(relay: relay),
                            ],
                          ),
                  ),
                  SizedBox(height: _searching ? AppSpacing.md : AppSpacing.xxl),
                  _SearchField(
                    controller: _searchCtrl,
                    focusNode: _searchFocus,
                    searching: _searching,
                    onChanged: (v) =>
                        setState(() => _query = v.trim().toLowerCase()),
                    onClear: _clearSearch,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        4, AppSpacing.lg, 4, AppSpacing.sm),
                    child:
                        Text(listLabel.toUpperCase(), style: AppText.overline),
                  ),
                ],
              ),
            ),
          ),
          if (relay.isLoadingApps && all.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (apps.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg, AppSpacing.xxl, AppSpacing.lg, 0),
                child: Column(
                  children: [
                    Icon(Icons.search_off_rounded,
                        size: 28, color: AppColors.inkFaint),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      _query.isEmpty
                          ? 'No apps found on this phone'
                          : 'No app matches "${_searchCtrl.text.trim()}"',
                      style: AppText.body.copyWith(color: AppColors.inkMuted),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              sliver: DecoratedSliver(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadii.lg),
                  boxShadow: AppShadows.card,
                ),
                sliver: SliverList.builder(
                  itemCount: apps.length,
                  itemBuilder: (context, i) => _AppRow(
                    app: apps[i],
                    first: i == 0,
                    selected: relay.isAppSelected(apps[i].package),
                    onChanged: relay.enabled
                        ? (v) => relay.setAppSelected(apps[i].package, v)
                        : null,
                  ),
                ),
              ),
            ),
          SliverPadding(
            padding: EdgeInsets.only(
                bottom:
                    AppSpacing.xxxl + MediaQuery.viewPaddingOf(context).bottom),
          ),
        ],
      ),
    );
  }
}

/// One app in the picker. Rows sit on a [DecoratedSliver] that paints the
/// group surface behind the whole list, so each row only draws its own
/// hairline; the rounded card look comes for free and the list stays lazy.
class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.app,
    required this.first,
    required this.selected,
    required this.onChanged,
  });

  final AppInfo app;
  final bool first;
  final bool selected;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    // Own Material, so the tap ink paints above the sliver's decoration
    // instead of on the Scaffold's surface underneath it.
    return Material(
      color: Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!first) Divider(height: 1, color: AppColors.divider),
          CheckboxListTile(
            value: selected,
            onChanged: onChanged == null ? null : (v) => onChanged!(v ?? false),
            activeColor: AppColors.primary,
            // The tick has to contrast with the fill. Dark mode's primary is a
            // light indigo, so a white tick on it is barely there.
            checkColor:
                AppColors.isDark ? const Color(0xFF10121A) : Colors.white,
            title: Text(app.name, style: AppText.body),
            subtitle: Text(app.package,
                style: AppText.caption.copyWith(color: AppColors.inkFaint),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            controlAffinity: ListTileControlAffinity.trailing,
            dense: true,
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.searching,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool searching;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    OutlineInputBorder border(Color c) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: BorderSide(color: c),
        );
    return TextField(
      controller: controller,
      focusNode: focusNode,
      style: AppText.body,
      textInputAction: TextInputAction.search,
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: 'Search apps',
        hintStyle: AppText.body.copyWith(color: AppColors.inkFaint),
        prefixIcon: Icon(Icons.search_rounded, color: AppColors.inkFaint),
        suffixIcon: searching
            ? IconButton(
                tooltip: 'Clear search',
                icon: Icon(Icons.close_rounded, color: AppColors.inkMuted),
                onPressed: onClear,
              )
            : null,
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        border: border(Colors.transparent),
        enabledBorder: border(Colors.transparent),
        focusedBorder: border(AppColors.primary),
      ),
    );
  }
}

class _AccessGroup extends StatelessWidget {
  const _AccessGroup({required this.relay});
  final NotificationRelay relay;

  @override
  Widget build(BuildContext context) {
    final granted = relay.accessGranted;
    return GroupCard(children: [
      ListTile(
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: (granted ? AppColors.success : AppColors.warning)
                .withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            granted ? Icons.check_rounded : Icons.priority_high_rounded,
            color: granted ? AppColors.success : AppColors.warning,
            size: 19,
          ),
        ),
        title: Text(
            granted
                ? 'Notification access granted'
                : 'Notification access needed',
            style: AppText.body),
        subtitle: Text(
            granted
                ? 'The app can read notifications to forward them'
                : 'Android has to let this app read notifications first',
            style: AppText.caption.copyWith(color: AppColors.inkMuted)),
        trailing: granted
            ? null
            : TextButton(
                onPressed: () => relay.openAccessSettings(),
                child: const Text('Grant'),
              ),
        onTap: granted ? null : () => relay.openAccessSettings(),
      ),
    ]);
  }
}

class _ForwardingGroup extends StatelessWidget {
  const _ForwardingGroup({required this.relay});
  final NotificationRelay relay;

  @override
  Widget build(BuildContext context) {
    return GroupCard(children: [
      SwitchTile(
        title: 'Forward notifications to band',
        subtitle: 'Selected apps below will alert your band',
        value: relay.enabled,
        onChanged: (v) async {
          await relay.setEnabled(v);
          return true;
        },
      ),
      if (relay.enabled) ...[
        SwitchTile(
          title: 'Private alerts',
          subtitle: 'Send the app and title only — never the message text',
          value: relay.privacyMode,
          onChanged: (v) async {
            await relay.setPrivacyMode(v);
            return true;
          },
        ),
        SwitchTile(
          title: 'Skip while using your phone',
          subtitle: "Don't buzz your wrist when the screen is already on",
          value: relay.suppressWhenScreenOn,
          onChanged: (v) async {
            await relay.setSuppressWhenScreenOn(v);
            return true;
          },
        ),
        NavTile(
          icon: Icons.send_rounded,
          iconColor: AppColors.primary,
          title: 'Send a test notification',
          subtitle: 'Straight to the band, skipping Android — tells you '
              'which half of the path is at fault',
          onTap: () {
            relay.sendTest();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Test alert sent — check your band'),
              ),
            );
          },
        ),
      ],
    ]);
  }
}
