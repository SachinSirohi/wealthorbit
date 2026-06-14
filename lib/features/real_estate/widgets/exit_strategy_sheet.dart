import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:drift/drift.dart' as drift;
import 'package:uuid/uuid.dart';
import '../../../core/theme/wo_design.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/app_repository.dart';

class ExitStrategySheet extends StatefulWidget {
  final Asset asset;
  final ScrollController scrollController;

  const ExitStrategySheet({
    super.key,
    required this.asset,
    required this.scrollController,
  });

  @override
  State<ExitStrategySheet> createState() => _ExitStrategySheetState();
}

class _ExitStrategySheetState extends State<ExitStrategySheet> {
  AppRepository? _repo;
  List<PropertyExitRule> _rules = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    _repo = await AppRepository.getInstance();
    final rules = await _repo!.getExitRulesForAsset(widget.asset.id);
    if (mounted) {
      setState(() {
        _rules = rules;
        _isLoading = false;
      });
    }
  }

  void _showAddRuleDialog() {
    String selectedType = 'irr_threshold';
    final valueController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: WoColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WoRadius.card)),
        title: Text('Add Exit Rule', style: WoText.title()),
        content: StatefulBuilder(
          builder: (context, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButton<String>(
                value: selectedType,
                dropdownColor: WoColors.surfaceHi,
                style: WoText.bodyHi(),
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: 'irr_threshold', child: Text('Target IRR (%)')),
                  DropdownMenuItem(value: 'equity_threshold', child: Text('Target Equity (%)')),
                  DropdownMenuItem(value: 'profit_threshold', child: Text('Target Profit (Amount)')),
                  DropdownMenuItem(value: 'holding_period', child: Text('Holding Period (Years)')),
                ],
                onChanged: (val) {
                  setDialogState(() => selectedType = val!);
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: valueController,
                keyboardType: TextInputType.number,
                style: WoText.bodyHi(),
                decoration: woInput('Threshold Value').copyWith(
                  suffixText: _getSuffix(selectedType),
                  suffixStyle: WoText.caption(color: WoColors.textLo),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            child: Text('Cancel', style: WoText.body()),
            onPressed: () => Navigator.pop(context),
          ),
          ElevatedButton(
            style: WoButtons.primary,
            child: const Text('Add Rule'),
            onPressed: () async {
              if (valueController.text.isEmpty) return;

              final rule = PropertyExitRulesCompanion(
                id: drift.Value(const Uuid().v4()),
                assetId: drift.Value(widget.asset.id),
                ruleType: drift.Value(selectedType),
                thresholdValue: drift.Value(double.parse(valueController.text)),
                isTriggered: const drift.Value(false),
                createdAt: drift.Value(DateTime.now()),
              );

              await _repo!.insertExitRule(rule);
              if (!context.mounted) return;
              Navigator.pop(context);
              _loadData(); // Refresh list
            },
          ),
        ],
      ),
    );
  }

  String _getSuffix(String type) {
    switch (type) {
      case 'irr_threshold': return '%';
      case 'equity_threshold': return '%';
      case 'holding_period': return 'Years';
      default: return '';
    }
  }

  Future<void> _deleteRule(String id) async {
    await _repo!.deleteExitRule(id);
    _loadData();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: WoColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(top: BorderSide(color: WoColors.borderHi, width: 1)),
      ),
      child: Column(
        children: [
          // Handle bar
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: WoSheetHandle(),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Exit Strategy', style: WoText.title()),
                    Text(widget.asset.name, style: WoText.body()),
                  ],
                ),
                IconButton(
                  icon: Icon(CupertinoIcons.add_circled_solid, color: WoColors.gold, size: 32),
                  onPressed: _showAddRuleDialog,
                ),
              ],
            ),
          ),

          Divider(color: WoColors.border, height: 1),

          // Rules List
          Expanded(
            child: _isLoading
                ? Center(child: CircularProgressIndicator(color: WoColors.gold))
                : _rules.isEmpty
                    ? WoEmptyState(
                        icon: CupertinoIcons.flag_slash,
                        title: 'No exit rules yet',
                        hint: 'Set a target to get notified when it\'s time to sell',
                        ctaLabel: 'Add your first rule',
                        onCta: _showAddRuleDialog,
                      )
                    : ListView.builder(
                        controller: widget.scrollController,
                        padding: const EdgeInsets.all(20),
                        itemCount: _rules.length,
                        itemBuilder: (context, index) {
                          final rule = _rules[index];
                          return Dismissible(
                            key: Key(rule.id),
                            onDismissed: (_) => _deleteRule(rule.id),
                            background: Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              decoration: BoxDecoration(color: WoColors.red, borderRadius: BorderRadius.circular(16)),
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20),
                              child: const Icon(Icons.delete, color: Colors.white),
                            ),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              padding: const EdgeInsets.all(16),
                              decoration: woCard(radius: 16, tint: rule.isTriggered ? WoColors.mint : null),
                              child: Row(
                                children: [
                                  WoIconBubble(
                                    rule.isTriggered ? Icons.check_circle : CupertinoIcons.scope,
                                    color: rule.isTriggered ? WoColors.mint : WoColors.gold,
                                    size: 44,
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _formatRuleType(rule.ruleType),
                                          style: WoText.subtitle(),
                                        ),
                                        Text(
                                          'Target: ${_formatRuleValue(rule.ruleType, rule.thresholdValue)}',
                                          style: WoText.caption(),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (rule.isTriggered)
                                    WoChip('READY', color: WoColors.mint),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  String _formatRuleType(String type) {
    switch (type) {
      case 'irr_threshold': return 'Target IRR';
      case 'equity_threshold': return 'Target Equity';
      case 'profit_threshold': return 'Target Profit';
      case 'holding_period': return 'Holding Period';
      default: return type;
    }
  }

  String _formatRuleValue(String type, double value) {
    switch (type) {
      case 'irr_threshold': return '${value.toStringAsFixed(1)}%';
      case 'equity_threshold': return '${value.toStringAsFixed(1)}%';
      case 'holding_period': return '${value.toStringAsFixed(1)} Years';
      default: return value.toStringAsFixed(0);
    }
  }
}
