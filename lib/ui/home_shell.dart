import 'package:flutter/material.dart';

import 'tabs/today_tab.dart';
import 'tabs/heart_tab.dart';
import 'tabs/activity_tab.dart';
import 'tabs/sleep_tab.dart';
import 'tabs/profile_tab.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';

/// Root scaffold: 5 destinations behind a floating pill nav. Tabs are kept alive
/// in an IndexedStack so scroll/animation state survives switching.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _NavDest {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final Color color;
  const _NavDest(this.icon, this.activeIcon, this.label, this.color);
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _dests = [
    _NavDest(Icons.today_outlined, Icons.today_rounded, 'Today',
        AppColors.primary),
    _NavDest(Icons.favorite_border_rounded, Icons.favorite_rounded, 'Heart',
        AppColors.heart),
    _NavDest(Icons.directions_walk_rounded, Icons.directions_run_rounded,
        'Activity', AppColors.activity),
    _NavDest(Icons.bedtime_outlined, Icons.bedtime_rounded, 'Sleep',
        AppColors.sleep),
    _NavDest(Icons.person_outline_rounded, Icons.person_rounded, 'Profile',
        AppColors.primary),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: IndexedStack(
        index: _index,
        children: const [
          TodayTab(),
          HeartTab(),
          ActivityTab(),
          SleepTab(),
          ProfileTab(),
        ],
      ),
      bottomNavigationBar: _FloatingNav(
        dests: _dests,
        index: _index,
        onTap: (i) => setState(() => _index = i),
      ),
    );
  }
}

class _FloatingNav extends StatelessWidget {
  final List<_NavDest> dests;
  final int index;
  final ValueChanged<int> onTap;

  const _FloatingNav({
    required this.dests,
    required this.index,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Container(
          height: 66,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadii.xl),
            boxShadow: AppShadows.card,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (var i = 0; i < dests.length; i++)
                _NavItem(
                  dest: dests[i],
                  selected: i == index,
                  onTap: () => onTap(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final _NavDest dest;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.dest,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: AppMotion.fast,
              curve: AppMotion.ease,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: selected
                    ? dest.color.withValues(alpha: 0.14)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(AppRadii.pill),
              ),
              child: Icon(
                selected ? dest.activeIcon : dest.icon,
                color: selected ? dest.color : AppColors.inkFaint,
                size: 23,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              dest.label,
              style: AppText.caption.copyWith(
                color: selected ? dest.color : AppColors.inkFaint,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
