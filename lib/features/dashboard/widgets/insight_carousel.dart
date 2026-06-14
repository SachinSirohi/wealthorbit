import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../../../core/theme/wo_design.dart';
import '../../../data/database/database.dart';

class InsightCarousel extends StatelessWidget {
  final List<FinancialInsight> insights;
  final Function(String) onDismiss;

  const InsightCarousel({
    super.key,
    required this.insights,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    if (insights.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              Icon(CupertinoIcons.lightbulb_fill, color: WoColors.gold, size: 16),
              const SizedBox(width: 8),
              Text('SMART INSIGHTS', style: WoText.label()),
            ],
          ),
        ),
        SizedBox(
          height: 140,
          child: PageView.builder(
            controller: PageController(viewportFraction: 0.9),
            itemCount: insights.length,
            itemBuilder: (context, index) {
              final insight = insights[index];
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: _buildInsightCard(context, insight),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildInsightCard(BuildContext context, FinancialInsight insight) {
    final color = _getSeverityColor(insight.severity);
    final icon = _getSeverityIcon(insight.severity);

    return Dismissible(
      key: Key(insight.id),
      direction: DismissDirection.up,
      onDismissed: (_) => onDismiss(insight.id),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: woCard(radius: 18, tint: color),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                WoIconBubble(icon, color: color, size: 34),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _formatType(insight.type),
                    style: WoText.caption(color: color).copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  icon: Icon(CupertinoIcons.xmark, size: 16, color: WoColors.textLo),
                  onPressed: () => onDismiss(insight.id),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              insight.message,
              style: WoText.bodyHi(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Color _getSeverityColor(String severity) {
    switch (severity) {
      case 'critical': return WoColors.red;
      case 'warning': return WoColors.orange;
      case 'positive': return WoColors.mint;
      default: return WoColors.blue;
    }
  }

  IconData _getSeverityIcon(String severity) {
    switch (severity) {
      case 'critical': return CupertinoIcons.exclamationmark_triangle_fill;
      case 'warning': return CupertinoIcons.exclamationmark_circle_fill;
      case 'positive': return CupertinoIcons.checkmark_seal_fill;
      default: return CupertinoIcons.info_circle_fill;
    }
  }

  String _formatType(String type) {
    return type.split('_').map((w) => w.isNotEmpty ? w[0].toUpperCase() + w.substring(1) : w).join(' ');
  }
}
