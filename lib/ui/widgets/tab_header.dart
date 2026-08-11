import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// The one collapsing header every tab uses.
///
/// Before this existed the five tabs had four different treatments: Today,
/// Heart and Activity each hand-rolled their own `SliverAppBar`, while Sleep and
/// Profile used a plain `SliverToBoxAdapter`. The two without an app bar had
/// nothing pinned at the top of the viewport, so once the header scrolled away
/// the content underneath ran straight up behind the status bar — the clock and
/// the battery icon sat on top of card text. That is the "settings screen
/// overlapped" and "the UI is very inconsistent" report, and it is structural:
/// no amount of padding fixes it, because the offending content is *scrolled*,
/// not laid out, into that space.
///
/// A pinned app bar with an opaque [AppColors.scaffold] background is the fix.
/// It always occupies the status-bar strip, so scrolled content is painted over
/// rather than showing through.
class TabHeaderSliver extends StatelessWidget {
  final String title;

  /// Quiet second line — the "what am I looking at right now" detail.
  final String? subtitle;

  /// Optional colour + icon shown next to the subtitle, for tabs that use one
  /// (a heart for the live BPM, a moon for the night).
  final IconData? subtitleIcon;
  final Color? subtitleIconColor;

  /// Optional avatar/badge shown to the left of the title.
  final Widget? leading;

  /// Optional control pinned to the right of the title row.
  final Widget? trailing;

  const TabHeaderSliver({
    super.key,
    required this.title,
    this.subtitle,
    this.subtitleIcon,
    this.subtitleIconColor,
    this.leading,
    this.trailing,
  });

  static const double _expandedHeight = 128;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final maxExtent = _expandedHeight + topInset;
    final minExtent = kToolbarHeight + topInset;

    return SliverAppBar(
      pinned: true,
      expandedHeight: _expandedHeight,
      backgroundColor: AppColors.scaffold,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      automaticallyImplyLeading: false,
      // No `title:` here. An AppBar title and a FlexibleSpaceBar background are
      // drawn at the same time, so passing both printed the screen name twice —
      // once large, once small — while the header was expanded. Both states live
      // in the flexible space instead, cross-faded by how far it has collapsed.
      flexibleSpace: LayoutBuilder(
        builder: (context, constraints) {
          final t = maxExtent == minExtent
              ? 1.0
              : ((maxExtent - constraints.maxHeight) / (maxExtent - minExtent))
                  .clamp(0.0, 1.0);
          // Hand over in the second half of the collapse, so the two titles are
          // never both legible.
          final expandedOpacity = (1 - t * 2).clamp(0.0, 1.0);
          final collapsedOpacity = ((t - 0.5) * 2).clamp(0.0, 1.0);

          return Stack(
            fit: StackFit.expand,
            children: [
              if (collapsedOpacity > 0)
                Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: EdgeInsets.only(
                        top: topInset + (kToolbarHeight - 24) / 2,
                        left: AppSpacing.lg),
                    child: Opacity(
                      opacity: collapsedOpacity,
                      child: Text(title,
                          style: AppText.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ),
              if (expandedOpacity > 0)
                Opacity(
                  opacity: expandedOpacity,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                          AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Spacer(),
                          Row(
                            children: [
                              if (leading != null) ...[
                                leading!,
                                const SizedBox(width: AppSpacing.md),
                              ],
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(title,
                                        style: AppText.h1,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis),
                                    if (subtitle != null) ...[
                                      const SizedBox(height: 3),
                                      Row(
                                        children: [
                                          if (subtitleIcon != null) ...[
                                            Icon(subtitleIcon,
                                                size: 14,
                                                color: subtitleIconColor ??
                                                    AppColors.inkMuted),
                                            const SizedBox(width: AppSpacing.xs),
                                          ],
                                          Flexible(
                                            child: Text(subtitle!,
                                                style: AppText.label,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              if (trailing != null) trailing!,
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Bottom spacer that clears the floating nav on whatever device this is.
///
/// Every tab used to end with a hardcoded `SizedBox(height: 96)`, which is
/// shorter than the nav actually is (66 pill + 12 margin + the system gesture
/// inset), so the last card was clipped on all five tabs. See
/// [AppLayout.navClearance].
class SliverNavClearance extends StatelessWidget {
  const SliverNavClearance({super.key});

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
        child: SizedBox(height: AppLayout.navClearance(context)),
      );
}
