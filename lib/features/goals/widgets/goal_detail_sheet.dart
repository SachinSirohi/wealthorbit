import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:drift/drift.dart' show Value;
import 'package:intl/intl.dart';
import '../../../core/theme/wo_design.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/app_repository.dart';
import '../../../core/utils/financial_calculations.dart';

/// Goal Detail Sheet - Asset linking, progress tracking, SIP recommendations, what-if analysis
class GoalDetailSheet extends StatefulWidget {
  final Goal goal;

  const GoalDetailSheet({super.key, required this.goal});

  @override
  State<GoalDetailSheet> createState() => _GoalDetailSheetState();
}

class _GoalDetailSheetState extends State<GoalDetailSheet> {
  AppRepository? _repo;
  List<GoalAssetMapping> _mappings = [];
  List<Asset> _assets = [];
  List<Asset> _linkedAssets = [];
  double _currentProgress = 0;
  double _shortfall = 0;
  bool _isLoading = true;

  // What-if parameters
  double _expectedReturn = 10.0;

  @override
  void initState() {
    super.initState();
    _initializeData();
  }

  Future<void> _initializeData() async {
    _repo = await AppRepository.getInstance();
    await _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    final mappings = await _repo!.getGoalAssetMappings(widget.goal.id);
    final assets = await _repo!.getAllAssets();

    // Calculate linked assets and progress
    final linkedAssets = <Asset>[];
    double progress = 0;

    for (final mapping in mappings) {
      final asset = assets.where((a) => a.id == mapping.assetId).firstOrNull;
      if (asset != null) {
        linkedAssets.add(asset);
        progress += asset.currentValue * (mapping.allocationPercent / 100);
      }
    }

    setState(() {
      _mappings = mappings;
      _assets = assets;
      _linkedAssets = linkedAssets;
      _currentProgress = progress;
      _shortfall = (widget.goal.targetAmount - progress).clamp(0, double.infinity);
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.9,
      decoration: BoxDecoration(
        color: WoColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(top: BorderSide(color: WoColors.borderHi, width: 1)),
      ),
      child: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: _isLoading
                ? Center(child: CircularProgressIndicator(color: WoColors.gold))
                : SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildProgressCard(),
                        const SizedBox(height: 20),
                        _buildLinkedAssets(),
                        const SizedBox(height: 20),
                        _buildSIPRecommendation(),
                        const SizedBox(height: 20),
                        _buildWhatIfAnalysis(),
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final daysLeft = widget.goal.targetDate.difference(DateTime.now()).inDays;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        children: [
          const WoSheetHandle(),
          Row(
            children: [
              WoIconBubble(CupertinoIcons.flag_fill, color: WoColors.indigo, size: 46),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.goal.name, style: WoText.title()),
                    Text(
                      '${daysLeft > 0 ? daysLeft : 0} days left • ${DateFormat('MMM yyyy').format(widget.goal.targetDate)}',
                      style: WoText.caption(),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: Icon(Icons.close, color: WoColors.textMid),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProgressCard() {
    final progressPercent = widget.goal.targetAmount > 0
        ? (_currentProgress / widget.goal.targetAmount * 100).clamp(0.0, 100.0)
        : 0.0;
    final isOnTrack = progressPercent >= 50 || _shortfall == 0;
    final accent = isOnTrack ? WoColors.mint : WoColors.orange;

    // Calculate inflation-adjusted target (6% default inflation)
    final daysLeft = widget.goal.targetDate.difference(DateTime.now()).inDays.clamp(1, 36500);
    final yearsLeft = daysLeft / 365.0;
    final inflationAdjustedTarget = FinancialCalculations.calculateInflationAdjustedGoal(
      currentValue: widget.goal.targetAmount,
      inflationRate: 0.06, // 6% inflation
      years: yearsLeft.round().clamp(1, 50),
    );

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: woCard(tint: accent),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Progress', style: WoText.caption(color: WoColors.textLo)),
                  Text(_formatCurrency(_currentProgress), style: WoText.display(color: accent)),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('Target', style: WoText.caption(color: WoColors.textLo)),
                  Text(_formatCurrency(widget.goal.targetAmount), style: WoText.num(size: 17)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progressPercent / 100,
              backgroundColor: WoColors.inputFill,
              valueColor: AlwaysStoppedAnimation<Color>(accent),
              minHeight: 10,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${progressPercent.toStringAsFixed(1)}% complete', style: WoText.caption()),
              if (_shortfall > 0)
                Text('Shortfall: ${_formatCurrency(_shortfall)}', style: WoText.caption(color: WoColors.orange)),
            ],
          ),
          // Inflation-adjusted view
          if (yearsLeft >= 1) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: WoColors.inputFill,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: WoColors.border),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(Icons.trending_up, color: WoColors.textMid, size: 16),
                      const SizedBox(width: 6),
                      Text('Inflation Adjusted (6%)', style: WoText.caption()),
                    ],
                  ),
                  Text(_formatCurrency(inflationAdjustedTarget), style: WoText.num(size: 12.5)),
                ],
              ),
            ),
          ],
        ],
      ),
    ).animate().fadeIn().scale(begin: const Offset(0.95, 0.95));
  }

  Widget _buildLinkedAssets() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        WoSectionHeader(
          'Linked Assets',
          action: 'Link',
          onAction: _showLinkAssetSheet,
        ),
        if (_linkedAssets.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: woWell(radius: 16),
            child: Row(
              children: [
                Icon(Icons.link_off, color: WoColors.textLo, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('No assets linked', style: WoText.bodyHi()),
                      Text('Link investments to track goal progress', style: WoText.caption(color: WoColors.textLo)),
                    ],
                  ),
                ),
              ],
            ),
          )
        else
          ...List.generate(_linkedAssets.length, (index) {
            final asset = _linkedAssets[index];
            final mapping = _mappings.where((m) => m.assetId == asset.id).firstOrNull;
            final allocation = mapping?.allocationPercent ?? 0;
            final contribution = asset.currentValue * (allocation / 100);

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: woWell(radius: 16),
              child: Row(
                children: [
                  WoIconBubble(Icons.account_balance, color: WoColors.mint, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(asset.name, style: WoText.bodyHi()),
                        Text('${allocation.toStringAsFixed(0)}% allocated • ${_formatCurrency(contribution)}', style: WoText.caption(color: WoColors.textLo)),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () async {
                      await _repo!.deleteGoalAssetMapping(widget.goal.id, asset.id);
                      _loadData();
                      HapticFeedback.mediumImpact();
                    },
                    icon: Icon(Icons.link_off, color: WoColors.textLo, size: 18),
                  ),
                ],
              ),
            ).animate(delay: (index * 50).ms).fadeIn().slideX(begin: 0.05);
          }),
      ],
    );
  }

  Widget _buildSIPRecommendation() {
    if (_shortfall <= 0) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: WoColors.mint.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: WoColors.mint.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(Icons.check_circle, color: WoColors.mint, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Goal on Track!', style: WoText.title(color: WoColors.mint)),
                  Text('You have enough assets linked to meet this goal.', style: WoText.caption()),
                ],
              ),
            ),
          ],
        ),
      ).animate().fadeIn().slideY(begin: 0.1);
    }

    final daysLeft = widget.goal.targetDate.difference(DateTime.now()).inDays.clamp(1, 36500);
    final monthsLeft = (daysLeft / 30).ceil().clamp(1, 1200);

    // Calculate SIP needed with expected return
    final sipNeeded = FinancialCalculations.calculateMonthlySIPForGoal(
      _shortfall,
      _expectedReturn,
      monthsLeft,
    );

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: woCard(tint: WoColors.blue),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.trending_up, color: WoColors.blue, size: 24),
              const SizedBox(width: 8),
              Text('SIP Recommendation', style: WoText.title()),
            ],
          ),
          const SizedBox(height: 16),
          Text('To cover the shortfall of ${_formatCurrency(_shortfall)}:', style: WoText.body()),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: woWell(),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Recommended SIP', style: WoText.caption(color: WoColors.textLo)),
                    Text(_formatCurrency(sipNeeded), style: WoText.num(color: WoColors.blue, size: 22)),
                    Text('per month', style: WoText.caption(color: WoColors.textLo)),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('for $monthsLeft months', style: WoText.caption()),
                    Text('@ ${_expectedReturn.toStringAsFixed(1)}% p.a.', style: WoText.caption(color: WoColors.textLo)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text('Assumptions: ${_expectedReturn.toStringAsFixed(1)}% annual return, compounded monthly', style: WoText.caption(color: WoColors.textLo)),
        ],
      ),
    ).animate().fadeIn().slideY(begin: 0.1);
  }

  Widget _buildWhatIfAnalysis() {
    final daysLeft = widget.goal.targetDate.difference(DateTime.now()).inDays.clamp(1, 36500);
    final monthsLeft = (daysLeft / 30).ceil().clamp(1, 1200);

    // Calculate different scenarios
    final scenarios = [
      {'label': 'Conservative', 'return': 6.0, 'color': WoColors.blue},
      {'label': 'Moderate', 'return': 10.0, 'color': WoColors.mint},
      {'label': 'Aggressive', 'return': 15.0, 'color': WoColors.orange},
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const WoSectionHeader('What-If Analysis', padding: EdgeInsets.fromLTRB(2, 8, 2, 4)),
        Text('SIP needed at different return rates', style: WoText.caption()),
        const SizedBox(height: 12),
        ...scenarios.map((scenario) {
          final rate = scenario['return'] as double;
          final label = scenario['label'] as String;
          final color = scenario['color'] as Color;

          final sip = _shortfall > 0
              ? FinancialCalculations.calculateMonthlySIPForGoal(_shortfall, rate, monthsLeft)
              : 0.0;

          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: WoColors.inputFill,
              borderRadius: BorderRadius.circular(WoRadius.control),
              border: Border.all(color: color.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 40,
                  decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: WoText.bodyHi()),
                      Text('${rate.toStringAsFixed(0)}% annual return', style: WoText.caption(color: WoColors.textLo)),
                    ],
                  ),
                ),
                Text(
                  _shortfall > 0 ? _formatCurrency(sip) : 'N/A',
                  style: WoText.num(color: color, size: 16),
                ),
                Text('/mo', style: WoText.caption(color: WoColors.textLo)),
              ],
            ),
          );
        }),
        const SizedBox(height: 16),

        // Custom Scenario Slider
        Container(
          padding: const EdgeInsets.all(16),
          decoration: woWell(radius: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Custom Scenario', style: WoText.bodyHi()),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('Expected Return: ', style: WoText.caption()),
                  Text('${_expectedReturn.toStringAsFixed(1)}%', style: WoText.num(color: WoColors.gold)),
                ],
              ),
              Slider(
                value: _expectedReturn,
                min: 1,
                max: 25,
                divisions: 24,
                activeColor: WoColors.gold,
                inactiveColor: WoColors.borderHi,
                onChanged: (value) => setState(() => _expectedReturn = value),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('1%', style: WoText.caption(color: WoColors.textLo)),
                  Text('25%', style: WoText.caption(color: WoColors.textLo)),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showLinkAssetSheet() {
    final availableAssets = _assets.where((a) => !_linkedAssets.any((la) => la.id == a.id)).toList();
    String? selectedAssetId;
    double allocation = 100;

    if (availableAssets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No more assets to link')));
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => WoSheet(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Link Asset to Goal', style: WoText.title()),
              const SizedBox(height: 20),

              // Asset Dropdown
              DropdownButtonFormField<String>(
                initialValue: selectedAssetId,
                dropdownColor: WoColors.surface,
                style: WoText.bodyHi(),
                decoration: woInput('Select Asset'),
                items: availableAssets.map((a) => DropdownMenuItem(
                  value: a.id,
                  child: Text('${a.name} (${_formatCurrency(a.currentValue)})'),
                )).toList(),
                onChanged: (value) => setModalState(() => selectedAssetId = value),
              ),
              const SizedBox(height: 16),

              // Allocation Slider
              Text('Allocation: ${allocation.toStringAsFixed(0)}%', style: WoText.bodyHi()),
              Slider(
                value: allocation,
                min: 1,
                max: 100,
                divisions: 99,
                activeColor: WoColors.gold,
                inactiveColor: WoColors.borderHi,
                onChanged: (value) => setModalState(() => allocation = value),
              ),
              Text('How much of this asset to allocate to the goal', style: WoText.caption(color: WoColors.textLo)),

              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: selectedAssetId == null ? null : () async {
                    await _repo!.insertGoalAssetMapping(GoalAssetMappingsCompanion(
                      goalId: Value(widget.goal.id),
                      assetId: Value(selectedAssetId!),
                      allocationPercent: Value(allocation),
                    ));
                    if (!context.mounted) return;
                    Navigator.pop(context);
                    _loadData();
                    HapticFeedback.mediumImpact();
                  },
                  style: WoButtons.primary,
                  child: const Text('Link Asset'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatCurrency(double amount) => NumberFormat.currency(symbol: 'AED ', decimalDigits: 0).format(amount);
}
