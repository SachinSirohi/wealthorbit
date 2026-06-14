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

class AssetsScreen extends StatefulWidget {
  const AssetsScreen({super.key});

  @override
  State<AssetsScreen> createState() => _AssetsScreenState();
}

class _AssetsScreenState extends State<AssetsScreen> {
  AppRepository? _repo;
  List<Asset> _assets = [];
  bool _isLoading = true;
  double _totalValue = 0;
  // Per-type totals already converted into the base currency.
  Map<String, double> _byTypeBase = {};

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
      final assets = await _repo!.getAllAssets();
      if (!mounted) return;
      // Convert each holding into the base currency before aggregating.
      double total = 0;
      final byTypeBase = <String, double>{};
      for (final a in assets) {
        final base = await _repo!.toBase(a.currentValue, a.currencyCode);
        total += base;
        byTypeBase[a.type] = (byTypeBase[a.type] ?? 0) + base;
      }

      if (!mounted) return;
      setState(() {
        _assets = assets;
        _totalValue = total;
        _byTypeBase = byTypeBase;
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
          _buildTotalCard(),
          _buildAssetBreakdown(),
          if (_isLoading)
            SliverFillRemaining(
              child: Center(child: CircularProgressIndicator(color: WoColors.gold)),
            )
          else if (_assets.isEmpty)
            _buildEmptyState()
          else
            _buildAssetList(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddAssetSheet(),
        backgroundColor: WoColors.gold,
        icon: const Icon(CupertinoIcons.add, color: Colors.black),
        label: Text('Add Asset', style: GoogleFonts.poppins(color: Colors.black, fontWeight: FontWeight.w600)),
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
        title: Text(
          'Assets',
          style: WoText.display(),
        ),
        titlePadding: const EdgeInsets.only(left: 20, bottom: 16),
      ),
    );
  }

  Widget _buildTotalCard() {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(24),
        decoration: woCard(goldGlow: true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('TOTAL ASSET VALUE', style: WoText.label()),
            const SizedBox(height: 8),
            Text(
              _formatCurrency(_totalValue),
              style: WoText.hero(),
            ),
            const SizedBox(height: 4),
            Text('${_assets.length} assets tracked', style: WoText.caption()),
          ],
        ),
      ).animate().fadeIn().slideY(begin: 0.1),
    );
  }

  Widget _buildAssetBreakdown() {
    final byType = _byTypeBase;

    if (byType.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(16),
        decoration: woCard(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ALLOCATION', style: WoText.label()),
            const SizedBox(height: 12),
            ...byType.entries.map((e) {
              final percent = _totalValue > 0 ? (e.value / _totalValue * 100) : 0;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_getTypeLabel(e.key), style: WoText.bodyHi()),
                        Text('${percent.toStringAsFixed(1)}%', style: WoText.caption()),
                      ],
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: percent / 100,
                      backgroundColor: WoColors.inputFill,
                      valueColor: AlwaysStoppedAnimation(_getTypeColor(e.key)),
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ).animate().fadeIn(delay: 100.ms),
    );
  }

  String _getTypeLabel(String type) {
    final labels = {
      'real_estate': 'Real Estate',
      'stocks': 'Stocks',
      'mutual_funds': 'Mutual Funds',
      'fixed_deposit': 'Fixed Deposits',
      'gold': 'Gold',
      'crypto': 'Cryptocurrency',
      'ppf': 'PPF',
      'nps': 'NPS',
      'other': 'Other',
    };
    return labels[type] ?? type.toUpperCase();
  }

  Color _getTypeColor(String type) {
    final colors = {
      'real_estate': WoColors.blue,
      'stocks': WoColors.mint,
      'mutual_funds': WoColors.indigo,
      'fixed_deposit': WoColors.orange,
      'gold': WoColors.gold,
      'crypto': WoColors.teal,
      'ppf': WoColors.teal,
      'nps': WoColors.indigo,
      'other': WoColors.textMid,
    };
    return colors[type] ?? WoColors.textMid;
  }

  Widget _buildEmptyState() {
    return const SliverFillRemaining(
      child: WoEmptyState(
        icon: CupertinoIcons.chart_pie,
        title: 'No assets yet',
        hint: 'Add your investments & properties',
      ),
    );
  }

  Widget _buildAssetList() {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final asset = _assets[index];
          return _buildAssetTile(asset).animate(delay: (index * 50).ms).fadeIn().slideX(begin: 0.05);
        },
        childCount: _assets.length,
      ),
    );
  }

  Widget _buildAssetTile(Asset asset) {
    final gain = asset.currentValue - asset.purchaseValue;
    final gainPercent = asset.purchaseValue > 0 ? (gain / asset.purchaseValue * 100) : 0;
    final isPositive = gain >= 0;
    final gainColor = isPositive ? WoColors.mint : WoColors.red;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      decoration: woCard(radius: 18),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: WoIconBubble(_getTypeIcon(asset.type), color: _getTypeColor(asset.type), size: 48),
        title: Text(
          asset.name,
          style: WoText.subtitle(),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_getTypeLabel(asset.type), style: WoText.caption()),
            Text(asset.geography, style: WoText.caption(color: WoColors.textLo)),
          ],
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              _formatCurrency(asset.currentValue, asset.currencyCode),
              style: WoText.num(),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isPositive ? CupertinoIcons.arrow_up : CupertinoIcons.arrow_down,
                  color: gainColor,
                  size: 12,
                ),
                Text(
                  '${gainPercent.abs().toStringAsFixed(1)}%',
                  style: WoText.caption(color: gainColor),
                ),
              ],
            ),
          ],
        ),
        onTap: () => _showEditAssetSheet(asset),
      ),
    );
  }

  IconData _getTypeIcon(String type) {
    final icons = {
      'real_estate': CupertinoIcons.house_fill,
      'stocks': CupertinoIcons.graph_square_fill,
      'mutual_funds': CupertinoIcons.chart_pie_fill,
      'fixed_deposit': CupertinoIcons.lock_fill,
      'gold': CupertinoIcons.gift_fill,
      'crypto': CupertinoIcons.bitcoin,
      'ppf': CupertinoIcons.shield_fill,
      'nps': CupertinoIcons.person_crop_circle_fill,
      'other': CupertinoIcons.cube_fill,
    };
    return icons[type] ?? CupertinoIcons.circle;
  }

  void _showAddAssetSheet() => _showAssetSheet(null);
  void _showEditAssetSheet(Asset asset) => _showAssetSheet(asset);

  void _showAssetSheet(Asset? existing) {
    final isEditing = existing != null;
    final nameController = TextEditingController(text: existing?.name ?? '');
    final purchaseValueController = TextEditingController(text: existing?.purchaseValue.toString() ?? '');
    final currentValueController = TextEditingController(text: existing?.currentValue.toString() ?? '');
    final geographyController = TextEditingController(text: existing?.geography ?? '');
    String type = existing?.type ?? 'stocks';
    String currency = existing?.currencyCode ?? 'AED';
    bool isLiquid = existing?.isLiquid ?? true;

    final types = ['real_estate', 'stocks', 'mutual_funds', 'fixed_deposit', 'gold', 'crypto', 'ppf', 'nps', 'other'];
    final currencies = ['AED', 'USD', 'INR', 'EUR', 'GBP'];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Container(
          height: MediaQuery.of(context).size.height * 0.85,
          decoration: BoxDecoration(
            color: WoColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 8),
              const WoSheetHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      isEditing ? 'Edit Asset' : 'Add Asset',
                      style: WoText.title(),
                    ),
                    if (isEditing)
                      IconButton(
                        icon: Icon(CupertinoIcons.trash, color: WoColors.red),
                        onPressed: () async {
                          await _repo!.deleteAsset(existing.id);
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
                    children: [
                      // Asset Name
                      TextField(
                        controller: nameController,
                        style: WoText.bodyHi(),
                        decoration: woInput('Asset Name'),
                      ),
                      const SizedBox(height: 16),
                      // Asset Type
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: woWell(),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: type,
                            dropdownColor: WoColors.surface,
                            isExpanded: true,
                            items: types.map((t) => DropdownMenuItem(value: t, child: Text(_getTypeLabel(t), style: WoText.bodyHi()))).toList(),
                            onChanged: (val) => setSheetState(() => type = val!),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Currency
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: woWell(),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: currency,
                            dropdownColor: WoColors.surface,
                            isExpanded: true,
                            items: currencies.map((c) => DropdownMenuItem(value: c, child: Text(c, style: WoText.bodyHi()))).toList(),
                            onChanged: (val) => setSheetState(() => currency = val!),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Purchase Value
                      TextField(
                        controller: purchaseValueController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: WoText.bodyHi(),
                        decoration: woInput('Purchase Value'),
                      ),
                      const SizedBox(height: 16),
                      // Current Value
                      TextField(
                        controller: currentValueController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: WoText.bodyHi(),
                        decoration: woInput('Current Value'),
                      ),
                      const SizedBox(height: 16),
                      // Geography
                      TextField(
                        controller: geographyController,
                        style: WoText.bodyHi(),
                        decoration: woInput('Geography (e.g., UAE, India)'),
                      ),
                      const SizedBox(height: 16),
                      // Liquid Toggle
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: woWell(),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Liquid Asset', style: WoText.bodyHi()),
                            CupertinoSwitch(
                              value: isLiquid,
                              activeTrackColor: WoColors.gold,
                              onChanged: (val) => setSheetState(() => isLiquid = val),
                            ),
                          ],
                        ),
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
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Please enter asset name')));
                        return;
                      }

                      final purchaseValue = double.tryParse(purchaseValueController.text) ?? 0;
                      final currentValue = double.tryParse(currentValueController.text) ?? purchaseValue;

                      final asset = AssetsCompanion(
                        id: isEditing ? Value(existing.id) : Value(DateTime.now().millisecondsSinceEpoch.toString()),
                        name: Value(nameController.text),
                        type: Value(type),
                        currencyCode: Value(currency),
                        purchaseValue: Value(purchaseValue),
                        currentValue: Value(currentValue),
                        geography: Value(geographyController.text.isNotEmpty ? geographyController.text : 'UAE'),
                        isLiquid: Value(isLiquid),
                        purchaseDate: Value(DateTime.now()),
                      );

                      if (isEditing) {
                        await _repo!.updateAsset(existing.id, asset);
                      } else {
                        await _repo!.insertAsset(asset);
                      }

                      if (!context.mounted) return;
                      Navigator.pop(context);
                      _loadData();
                      HapticFeedback.mediumImpact();
                    },
                    style: WoButtons.primary,
                    child: Text(isEditing ? 'Update' : 'Add Asset'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatCurrency(double amount, [String currency = 'AED']) {
    return NumberFormat.currency(symbol: '$currency ', decimalDigits: 0).format(amount);
  }
}
