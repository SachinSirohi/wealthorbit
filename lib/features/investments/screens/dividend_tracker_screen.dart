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

/// Dividend Tracker - View and manage dividend income from investments
class DividendTrackerScreen extends StatefulWidget {
  const DividendTrackerScreen({super.key});

  @override
  State<DividendTrackerScreen> createState() => _DividendTrackerScreenState();
}

class _DividendTrackerScreenState extends State<DividendTrackerScreen> {
  AppRepository? _repo;
  List<Dividend> _dividends = [];
  List<Asset> _assets = [];
  bool _isLoading = true;
  double _totalDividendsThisYear = 0;
  double _totalDividendsAllTime = 0;
  int _selectedYear = DateTime.now().year;

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
      final dividends = await _repo!.getAllDividends();
      if (!mounted) return;
      final assets = await _repo!.getAllAssets();
      if (!mounted) return;

      final yearDividends = dividends.where((d) => d.paymentDate.year == _selectedYear);
      final totalYear = yearDividends.fold(0.0, (sum, d) => sum + d.amount);
      final totalAll = dividends.fold(0.0, (sum, d) => sum + d.amount);

      if (!mounted) return;
      setState(() {
        _dividends = dividends;
        _assets = assets;
        _totalDividendsThisYear = totalYear;
        _totalDividendsAllTime = totalAll;
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
      appBar: AppBar(
        backgroundColor: WoColors.bg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(CupertinoIcons.back, color: WoColors.textHi),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Dividend Tracker', style: WoText.title()),
        actions: [
          _buildYearSelector(),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: WoColors.gold))
          : RefreshIndicator(
              onRefresh: _loadData,
              child: CustomScrollView(
                slivers: [
                  _buildSummaryCard(),
                  _buildDividendsByAsset(),
                  _buildDividendList(),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddDividendSheet(null),
        backgroundColor: WoColors.gold,
        icon: const Icon(Icons.add, color: Colors.black),
        label: Text('Add Dividend', style: GoogleFonts.poppins(color: Colors.black, fontWeight: FontWeight.w600)),
      ).animate().scale(delay: 300.ms),
    );
  }

  Widget _buildYearSelector() {
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: DropdownButton<int>(
        value: _selectedYear,
        dropdownColor: WoColors.surface,
        style: WoText.bodyHi(),
        underline: const SizedBox(),
        iconEnabledColor: WoColors.textMid,
        items: List.generate(5, (i) => DateTime.now().year - i)
            .map((year) => DropdownMenuItem(value: year, child: Text('$year')))
            .toList(),
        onChanged: (year) {
          if (year != null) {
            setState(() => _selectedYear = year);
            _loadData();
          }
        },
      ),
    );
  }

  Widget _buildSummaryCard() {
    final yieldRate = _totalDividendsAllTime > 0 && _assets.isNotEmpty
        ? (_totalDividendsThisYear / _assets.fold(0.0, (sum, a) => sum + a.currentValue) * 100)
        : 0.0;

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(24),
        decoration: woCard(goldGlow: true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('DIVIDENDS $_selectedYear', style: WoText.label()),
                    const SizedBox(height: 6),
                    Text(
                      _formatCurrency(_totalDividendsThisYear),
                      style: WoText.display(),
                    ),
                  ],
                ),
                WoChip(
                  '${_dividends.where((d) => d.paymentDate.year == _selectedYear).length} Payments',
                  color: WoColors.indigo,
                  icon: Icons.monetization_on,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(height: 1, color: WoColors.border),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('All-Time Dividends', style: WoText.caption(color: WoColors.textLo)),
                      Text(_formatCurrency(_totalDividendsAllTime), style: WoText.num(size: 16)),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Yield Rate', style: WoText.caption(color: WoColors.textLo)),
                      Text('${yieldRate.toStringAsFixed(2)}%', style: WoText.num(size: 16)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ).animate().fadeIn().slideY(begin: 0.1),
    );
  }

  Widget _buildDividendsByAsset() {
    // Group dividends by asset for the selected year
    final yearDividends = _dividends.where((d) => d.paymentDate.year == _selectedYear).toList();
    final assetDividends = <String, double>{};

    for (final d in yearDividends) {
      assetDividends[d.assetId] = (assetDividends[d.assetId] ?? 0) + d.amount;
    }

    if (assetDividends.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: WoSectionHeader('By Investment', padding: EdgeInsets.fromLTRB(2, 0, 2, 12)),
          ),
          SizedBox(
            height: 100,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: assetDividends.length,
              itemBuilder: (context, index) {
                final assetId = assetDividends.keys.elementAt(index);
                final amount = assetDividends[assetId]!;
                final asset = _assets.where((a) => a.id == assetId).firstOrNull;

                return Container(
                  width: 140,
                  margin: const EdgeInsets.only(right: 12),
                  padding: const EdgeInsets.all(16),
                  decoration: woCard(radius: 18, tint: WoColors.indigo),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        asset?.name ?? 'Unknown',
                        style: WoText.bodyHi(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _formatCurrency(amount),
                        style: WoText.num(color: WoColors.indigo, size: 16),
                      ),
                    ],
                  ),
                ).animate(delay: (index * 50).ms).fadeIn().slideX(begin: 0.1);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDividendList() {
    final yearDividends = _dividends.where((d) => d.paymentDate.year == _selectedYear).toList();
    yearDividends.sort((a, b) => b.paymentDate.compareTo(a.paymentDate));

    if (yearDividends.isEmpty) {
      return SliverFillRemaining(
        child: WoEmptyState(
          icon: Icons.monetization_on_outlined,
          title: 'No dividends in $_selectedYear',
          hint: 'Add dividend income',
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildDividendCard(yearDividends[index]).animate(delay: (index * 60).ms).fadeIn().slideX(begin: 0.05),
          childCount: yearDividends.length,
        ),
      ),
    );
  }

  Widget _buildDividendCard(Dividend dividend) {
    final asset = _assets.where((a) => a.id == dividend.assetId).firstOrNull;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: woCard(radius: 18),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: WoIconBubble(
          dividend.isReinvested ? Icons.replay : Icons.payments,
          color: WoColors.indigo,
          size: 44,
        ),
        title: Text(
          asset?.name ?? 'Unknown Investment',
          style: WoText.subtitle(),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(DateFormat('dd MMM yyyy').format(dividend.paymentDate), style: WoText.caption()),
                if (dividend.isReinvested) ...[
                  const SizedBox(width: 8),
                  WoChip('DRIP', color: WoColors.mint),
                ],
              ],
            ),
            if (dividend.dividendType != 'cash')
              Text(dividend.dividendType.toUpperCase(), style: WoText.caption(color: WoColors.textLo)),
          ],
        ),
        trailing: Text(
          _formatCurrency(dividend.amount),
          style: WoText.num(color: WoColors.mint, size: 16),
        ),
        onTap: () => _showAddDividendSheet(dividend),
        onLongPress: () => _confirmDeleteDividend(dividend),
      ),
    );
  }

  void _showAddDividendSheet(Dividend? existing) {
    final isEditing = existing != null;
    final amountController = TextEditingController(text: existing?.amount.toStringAsFixed(0) ?? '');
    String? selectedAssetId = existing?.assetId;
    DateTime paymentDate = existing?.paymentDate ?? DateTime.now();
    DateTime exDate = existing?.exDate ?? DateTime.now().subtract(const Duration(days: 7));
    String dividendType = existing?.dividendType ?? 'cash';
    bool isReinvested = existing?.isReinvested ?? false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          height: MediaQuery.of(context).size.height * 0.75,
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          decoration: BoxDecoration(color: WoColors.surface, borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const WoSheetHandle(),
                Text(isEditing ? 'Edit Dividend' : 'Add Dividend', style: WoText.title()),
                const SizedBox(height: 20),

                // Asset Dropdown
                DropdownButtonFormField<String>(
                  initialValue: selectedAssetId,
                  dropdownColor: WoColors.surface,
                  style: WoText.bodyHi(),
                  decoration: woInput('Investment'),
                  items: _assets.map((a) => DropdownMenuItem(value: a.id, child: Text(a.name))).toList(),
                  onChanged: (value) => setModalState(() => selectedAssetId = value),
                ),
                const SizedBox(height: 12),

                // Amount
                TextField(
                  controller: amountController,
                  keyboardType: TextInputType.number,
                  style: WoText.bodyHi(),
                  decoration: woInput('Amount (AED)'),
                ),
                const SizedBox(height: 12),

                // Dates Row
                Row(
                  children: [
                    Expanded(
                      child: _buildDateButton('Ex-Date', exDate, (date) => setModalState(() => exDate = date)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildDateButton('Payment', paymentDate, (date) => setModalState(() => paymentDate = date)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Type Selector
                Row(
                  children: [
                    Text('Type: ', style: WoText.body()),
                    const SizedBox(width: 12),
                    ...['cash', 'stock', 'special'].map((type) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(type.toUpperCase()),
                        selected: dividendType == type,
                        selectedColor: WoColors.indigo,
                        backgroundColor: WoColors.inputFill,
                        side: BorderSide(color: WoColors.border),
                        labelStyle: GoogleFonts.inter(fontSize: 11, color: dividendType == type ? Colors.white : WoColors.textMid),
                        onSelected: (selected) => setModalState(() => dividendType = type),
                      ),
                    )),
                  ],
                ),
                const SizedBox(height: 12),

                // Reinvested Toggle
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Reinvested (DRIP)', style: WoText.body()),
                    CupertinoSwitch(
                      value: isReinvested,
                      activeTrackColor: WoColors.mint,
                      onChanged: (value) => setModalState(() => isReinvested = value),
                    ),
                  ],
                ),

                const Spacer(),

                // Save Button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      if (selectedAssetId == null) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select an investment')));
                        return;
                      }

                      final amount = double.tryParse(amountController.text) ?? 0;
                      final companion = DividendsCompanion(
                        id: isEditing ? Value(existing.id) : Value(DateTime.now().millisecondsSinceEpoch.toString()),
                        assetId: Value(selectedAssetId!),
                        amount: Value(amount),
                        currencyCode: const Value('AED'),
                        exDate: Value(exDate),
                        paymentDate: Value(paymentDate),
                        dividendType: Value(dividendType),
                        isReinvested: Value(isReinvested),
                      );

                      if (isEditing) {
                        await _repo!.updateDividend(existing.id, companion);
                      } else {
                        await _repo!.insertDividend(companion);
                      }

                      if (!context.mounted) return;
                      Navigator.pop(context);
                      _loadData();
                      HapticFeedback.mediumImpact();
                    },
                    style: WoButtons.primary,
                    child: Text(isEditing ? 'Update' : 'Add Dividend'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDateButton(String label, DateTime date, Function(DateTime) onDateSelected) {
    return GestureDetector(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: date,
          firstDate: DateTime(2000),
          lastDate: DateTime.now().add(const Duration(days: 365)),
        );
        if (picked != null) onDateSelected(picked);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: woWell(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: WoText.caption(color: WoColors.textLo)),
            const SizedBox(height: 4),
            Text(DateFormat('dd MMM').format(date), style: WoText.bodyHi()),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteDividend(Dividend dividend) {
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Delete Dividend?'),
        content: Text('Delete ${_formatCurrency(dividend.amount)} dividend?'),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () async {
              Navigator.pop(context);
              await _repo!.deleteDividend(dividend.id);
              _loadData();
              HapticFeedback.mediumImpact();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  String _formatCurrency(double amount) => NumberFormat.currency(symbol: 'AED ', decimalDigits: 0).format(amount);
}
