import 'dart:ui' show PointMode;
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// A ledger: label on the left, a dotted leader, a monospace value on the
/// right. Rows sit on hairlines, not in boxes.
///
/// This replaces the grid of rounded metric tiles. Six tiles each with an
/// icon, a big number and a label used most of a screen to say six things;
/// six ledger rows say them in a fifth of the height, align every figure in
/// one column, and read top to bottom like a record — which is what these
/// screens are.
class LedgerRow extends StatelessWidget {
  final String label;
  final String value;
  final String? unit;
  final Color? color;

  /// Quiet second line under the label — where a number came from, a caveat.
  final String? note;
  final VoidCallback? onTap;

  const LedgerRow({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.color,
    this.note,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (color != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: AppSpacing.md),
          ],
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: AppText.body),
              if (note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(note!,
                      style: AppText.caption
                          .copyWith(color: AppColors.inkFaint)),
                ),
            ],
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: CustomPaint(
              painter: _LeaderPainter(AppColors.divider),
              child: const SizedBox(height: 1),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(value, style: AppText.figure),
          if (unit != null && unit!.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text(unit!, style: AppText.unit),
          ],
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.inkFaint),
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }
}

/// Dotted leader between a label and its value.
class _LeaderPainter extends CustomPainter {
  final Color color;
  const _LeaderPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (var x = 0.0; x < size.width; x += 5) {
      canvas.drawPoints(PointMode.points, [Offset(x, size.height / 2)], p);
    }
  }

  @override
  bool shouldRepaint(_LeaderPainter old) => old.color != color;
}

/// A titled group of [LedgerRow]s separated by hairlines. No card.
class LedgerGroup extends StatelessWidget {
  final String? title;
  final List<Widget> rows;

  /// Evidence footer, e.g. "from 1 440 samples · synced 3m ago".
  final String? evidence;

  const LedgerGroup({super.key, this.title, required this.rows, this.evidence});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Text(title!.toUpperCase(), style: AppText.overline),
          ),
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) Divider(height: 1, color: AppColors.divider),
          rows[i],
        ],
        if (evidence != null) ...[
          const SizedBox(height: AppSpacing.sm),
          EvidenceLine(evidence!),
        ],
      ],
    );
  }
}

/// The app's signature footer: where a number came from, in monospace.
///
/// "1 440 samples · 91% heart-rate coverage · synced 3m ago" under a figure
/// does more for trust than any amount of rounding-corner polish, and it is
/// the one thing a generic fitness app never shows.
class EvidenceLine extends StatelessWidget {
  final String text;
  const EvidenceLine(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 12,
          decoration: BoxDecoration(
            color: AppColors.inkFaint.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text(text, style: AppText.mono)),
      ],
    );
  }
}

/// Thousands separator with a thin space, the ledger convention: 12 345.
String fmtThousands(num n) {
  final s = n.round().abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
    b.write(s[i]);
  }
  return '${n < 0 ? '-' : ''}$b';
}
