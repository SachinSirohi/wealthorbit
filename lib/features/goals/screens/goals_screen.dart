import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:drift/drift.dart' show Value;
import 'package:intl/intl.dart';
import '../../../core/theme/wo_design.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/app_repository.dart';
import '../widgets/goal_detail_sheet.dart';

class GoalsScreen extends StatefulWidget {
  const GoalsScreen({super.key});

  @override
  State<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends State<GoalsScreen> {
  AppRepository? _repo;
  List<Goal> _goals = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initializeData();
  }

  Future<void> _initializeData() async {
    try {
      _repo = await AppRepository.getInstance();
      if (!mounted) return;
      await _loadData();
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final goals = await _repo!.getAllGoals();

      if (!mounted) return;
      setState(() {
        _goals = goals;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WoColors.bg,
      body: CustomScrollView(
        slivers: [
          _buildAppBar(),
          _buildSummaryCard(),
          if (_isLoading)
            SliverFillRemaining(
              child: Center(child: CircularProgressIndicator(color: WoColors.gold)),
            )
          else if (_goals.isEmpty)
            _buildEmptyState()
          else
            _buildGoalsList(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddGoalSheet(),
        backgroundColor: WoColors.gold,
        icon: const Icon(CupertinoIcons.add, color: Colors.black),
        label: Text('Add Goal', style: GoogleFonts.poppins(color: Colors.black, fontWeight: FontWeight.w600)),
      ).animate().scale(delay: 300.ms),
    );
  }

  Widget _buildAppBar() {
    return SliverAppBar(
      expandedHeight: 100,
      floating: true,
      pinned: true,
      backgroundColor: WoColors.bg,
      flexibleSpace: FlexibleSpaceBar(
        title: Text('Financial Goals', style: WoText.display()),
        titlePadding: const EdgeInsets.only(left: 20, bottom: 16),
      ),
    );
  }

  Widget _buildSummaryCard() {
    final totalTarget = _goals.fold(0.0, (sum, g) => sum + g.targetAmount);
    final activeCount = _goals.where((g) => g.status == 'active').length;
    final achievedCount = _goals.where((g) => g.status == 'achieved').length;

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(24),
        decoration: woCard(goldGlow: true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('GOALS OVERVIEW', style: WoText.label()),
            const SizedBox(height: 8),
            Text(_formatCurrency(totalTarget), style: WoText.display()),
            Text('Total Target Amount', style: WoText.caption()),
            const SizedBox(height: 16),
            Row(
              children: [
                _buildStat('Active', activeCount.toString(), WoColors.mint),
                const SizedBox(width: 24),
                _buildStat('Achieved', achievedCount.toString(), WoColors.gold),
                const SizedBox(width: 24),
                _buildStat('Total', _goals.length.toString(), WoColors.textHi),
              ],
            ),
          ],
        ),
      ).animate().fadeIn().slideY(begin: 0.1),
    );
  }

  Widget _buildStat(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: WoText.num(color: color, size: 20)),
        Text(label, style: WoText.caption(color: WoColors.textLo)),
      ],
    );
  }

  Widget _buildEmptyState() {
    return const SliverFillRemaining(
      child: WoEmptyState(
        icon: CupertinoIcons.flag_fill,
        title: 'No goals yet',
        hint: 'Set financial goals to track your progress',
      ),
    );
  }

  Widget _buildGoalsList() {
    return SliverPadding(
      padding: const EdgeInsets.only(bottom: 100),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final goal = _goals[index];
            return _buildGoalCard(goal).animate(delay: (index * 50).ms).fadeIn().slideX(begin: 0.05);
          },
          childCount: _goals.length,
        ),
      ),
    );
  }

  Widget _buildGoalCard(Goal goal) {
    final daysLeft = goal.targetDate.difference(DateTime.now()).inDays;
    final isPastDue = daysLeft < 0;
    final isAchieved = goal.status == 'achieved';

    Color getStatusColor() {
      if (isAchieved) return WoColors.mint;
      if (isPastDue) return WoColors.red;
      if (goal.priority == 'high') return WoColors.orange;
      return WoColors.blue;
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      decoration: woCard(radius: 18),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: WoIconBubble(
          isAchieved ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.flag_fill,
          color: getStatusColor(),
          size: 48,
        ),
        title: Text(goal.name, style: WoText.subtitle()),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Target: ${_formatCurrency(goal.targetAmount)}',
              style: WoText.caption(),
            ),
            Text(
              isPastDue
                  ? 'Past due by ${daysLeft.abs()} days'
                  : isAchieved
                      ? 'Achieved!'
                      : '$daysLeft days left',
              style: WoText.caption(
                color: isPastDue ? WoColors.red : isAchieved ? WoColors.mint : WoColors.textLo,
              ),
            ),
          ],
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            WoChip(goal.priority.toUpperCase(), color: getStatusColor()),
            const SizedBox(height: 4),
            Text(
              DateFormat('MMM yyyy').format(goal.targetDate),
              style: WoText.caption(color: WoColors.textLo),
            ),
          ],
        ),
        onTap: () => _showGoalDetailSheet(goal),
        onLongPress: () => _showEditGoalSheet(goal),
      ),
    );
  }

  void _showAddGoalSheet() => _showGoalSheet(null);
  void _showEditGoalSheet(Goal goal) => _showGoalSheet(goal);

  void _showGoalDetailSheet(Goal goal) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GoalDetailSheet(goal: goal),
    ).then((_) => _loadData());
  }

  void _showGoalSheet(Goal? existing) {
    final isEditing = existing != null;
    final nameController = TextEditingController(text: existing?.name ?? '');
    final targetController = TextEditingController(text: existing?.targetAmount.toString() ?? '');
    String priority = existing?.priority ?? 'medium';
    DateTime targetDate = existing?.targetDate ?? DateTime.now().add(const Duration(days: 365));

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Container(
          height: MediaQuery.of(context).size.height * 0.75,
          decoration: BoxDecoration(color: WoColors.surface, borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
          child: Column(
            children: [
              const SizedBox(height: 8),
              const WoSheetHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(isEditing ? 'Edit Goal' : 'Add Goal', style: WoText.title()),
                    if (isEditing)
                      IconButton(
                        icon: Icon(CupertinoIcons.trash, color: WoColors.red),
                        onPressed: () async {
                          await _repo!.deleteGoal(existing.id);
                          if (!context.mounted) return;
                          Navigator.pop(context);
                          _loadData();
                          HapticFeedback.heavyImpact();
                        },
                      ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: nameController,
                        style: WoText.bodyHi(),
                        decoration: woInput('Goal Name'),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: targetController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: WoText.bodyHi(),
                        decoration: woInput('Target Amount').copyWith(
                          prefixText: 'AED ',
                          prefixStyle: WoText.body(color: WoColors.textLo),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Priority
                      Text('PRIORITY', style: WoText.label()),
                      const SizedBox(height: 8),
                      Row(
                        children: ['low', 'medium', 'high'].map((p) => Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: ChoiceChip(
                              label: Text(p.toUpperCase()),
                              selected: priority == p,
                              onSelected: (sel) => setSheetState(() => priority = p),
                              selectedColor: WoColors.gold,
                              labelStyle: GoogleFonts.poppins(color: priority == p ? Colors.black : WoColors.textMid, fontSize: 12),
                              backgroundColor: WoColors.inputFill,
                              side: BorderSide(color: WoColors.border),
                            ),
                          ),
                        )).toList(),
                      ),
                      const SizedBox(height: 16),
                      // Target Date
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('Target Date', style: WoText.caption()),
                        subtitle: Text(DateFormat('MMMM d, yyyy').format(targetDate), style: WoText.subtitle()),
                        trailing: Icon(CupertinoIcons.calendar, color: WoColors.gold),
                        onTap: () async {
                          final date = await showDatePicker(
                            context: context,
                            initialDate: targetDate,
                            firstDate: DateTime.now(),
                            lastDate: DateTime.now().add(const Duration(days: 365 * 30)),
                          );
                          if (date != null) setSheetState(() => targetDate = date);
                        },
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      if (nameController.text.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter goal name')));
                        return;
                      }

                      final target = double.tryParse(targetController.text) ?? 0;
                      if (target <= 0) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter a valid target amount')));
                        return;
                      }

                      final goal = GoalsCompanion(
                        id: isEditing ? Value(existing.id) : Value(DateTime.now().millisecondsSinceEpoch.toString()),
                        name: Value(nameController.text),
                        currencyCode: const Value('AED'),
                        targetAmount: Value(target),
                        targetDate: Value(targetDate),
                        priority: Value(priority),
                        status: const Value('active'),
                      );

                      if (isEditing) {
                        await _repo!.updateGoal(existing.id, goal);
                      } else {
                        await _repo!.insertGoal(goal);
                      }

                      if (!context.mounted) return;
                      Navigator.pop(context);
                      _loadData();
                      HapticFeedback.mediumImpact();
                    },
                    style: WoButtons.primary,
                    child: Text(isEditing ? 'Update' : 'Add Goal'),
                  ),
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
