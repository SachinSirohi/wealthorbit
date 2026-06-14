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

/// SIP Manager - View and manage Systematic Investment Plans
class SIPManagerScreen extends StatefulWidget {
  const SIPManagerScreen({super.key});

  @override
  State<SIPManagerScreen> createState() => _SIPManagerScreenState();
}

class _SIPManagerScreenState extends State<SIPManagerScreen> {
  AppRepository? _repo;
  List<SipRecord> _sips = [];
  List<Asset> _assets = [];
  bool _isLoading = true;
  double _totalMonthlySIP = 0;
  double _totalAnnualSIP = 0;

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
      final sips = await _repo!.getAllSipRecords();
      if (!mounted) return;
      final assets = await _repo!.getAllAssets();
      if (!mounted) return;
      final activeSips = sips.where((s) => s.isActive).toList();
      final monthlyTotal = activeSips.fold(0.0, (sum, s) => sum + s.amount);

      if (!mounted) return;
      setState(() {
        _sips = sips;
        _assets = assets;
        _totalMonthlySIP = monthlyTotal;
        _totalAnnualSIP = monthlyTotal * 12;
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
        title: Text('SIP Manager', style: WoText.title()),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: WoColors.gold))
          : RefreshIndicator(
              onRefresh: _loadData,
              child: CustomScrollView(
                slivers: [
                  _buildSummaryCard(),
                  _buildSIPList(),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddSIPSheet(null),
        backgroundColor: WoColors.gold,
        icon: const Icon(Icons.add, color: Colors.black),
        label: Text('Add SIP', style: GoogleFonts.poppins(color: Colors.black, fontWeight: FontWeight.w600)),
      ).animate().scale(delay: 300.ms),
    );
  }

  Widget _buildSummaryCard() {
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
                    Text('MONTHLY SIP', style: WoText.label()),
                    const SizedBox(height: 6),
                    Text(
                      _formatCurrency(_totalMonthlySIP),
                      style: WoText.display(),
                    ),
                  ],
                ),
                WoChip(
                  '${_sips.where((s) => s.isActive).length} Active',
                  color: WoColors.mint,
                  icon: Icons.event_repeat,
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
                      Text('Annual Investment', style: WoText.caption(color: WoColors.textLo)),
                      Text(_formatCurrency(_totalAnnualSIP), style: WoText.num(size: 16)),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Total SIPs', style: WoText.caption(color: WoColors.textLo)),
                      Text('${_sips.length}', style: WoText.num(size: 16)),
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

  Widget _buildSIPList() {
    if (_sips.isEmpty) {
      return const SliverFillRemaining(
        child: WoEmptyState(
          icon: Icons.event_repeat,
          title: 'No SIPs yet',
          hint: 'Add systematic investment plans',
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.only(bottom: 100),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildSIPCard(_sips[index]).animate(delay: (index * 80).ms).fadeIn().slideX(begin: 0.05),
          childCount: _sips.length,
        ),
      ),
    );
  }

  Widget _buildSIPCard(SipRecord sip) {
    final asset = _assets.where((a) => a.id == sip.assetId).firstOrNull;
    final nextDate = _getNextSIPDate(sip.dayOfMonth);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: woCard(radius: 18, tint: sip.isActive ? WoColors.mint : null),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: WoIconBubble(
          Icons.event_repeat,
          color: sip.isActive ? WoColors.mint : WoColors.textLo,
          size: 48,
        ),
        title: Text(
          sip.name,
          style: WoText.subtitle(),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (asset != null)
              Text('→ ${asset.name}', style: WoText.caption()),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.calendar_today, size: 12, color: WoColors.textLo),
                const SizedBox(width: 4),
                Text('Day ${sip.dayOfMonth} • Next: ${DateFormat('dd MMM').format(nextDate)}',
                    style: WoText.caption(color: WoColors.textLo)),
              ],
            ),
          ],
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(_formatCurrency(sip.amount), style: WoText.num(size: 16)),
            const SizedBox(height: 4),
            WoChip(
              sip.isActive ? 'Active' : 'Paused',
              color: sip.isActive ? WoColors.mint : WoColors.textMid,
            ),
          ],
        ),
        onTap: () => _showAddSIPSheet(sip),
        onLongPress: () => _confirmDeleteSIP(sip),
      ),
    );
  }

  DateTime _getNextSIPDate(int dayOfMonth) {
    final now = DateTime.now();
    var nextDate = DateTime(now.year, now.month, dayOfMonth);
    if (nextDate.isBefore(now)) {
      nextDate = DateTime(now.year, now.month + 1, dayOfMonth);
    }
    return nextDate;
  }

  void _showAddSIPSheet(SipRecord? existing) {
    final isEditing = existing != null;
    final nameController = TextEditingController(text: existing?.name ?? '');
    final amountController = TextEditingController(text: existing?.amount.toStringAsFixed(0) ?? '');
    String? selectedAssetId = existing?.assetId;
    int dayOfMonth = existing?.dayOfMonth ?? 1;
    bool isActive = existing?.isActive ?? true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          height: MediaQuery.of(context).size.height * 0.7,
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          decoration: BoxDecoration(color: WoColors.surface, borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const WoSheetHandle(),
                Text(isEditing ? 'Edit SIP' : 'Add SIP', style: WoText.title()),
                const SizedBox(height: 20),

                // Name
                TextField(
                  controller: nameController,
                  style: WoText.bodyHi(),
                  decoration: woInput('SIP Name'),
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

                // Asset Dropdown
                DropdownButtonFormField<String>(
                  initialValue: selectedAssetId,
                  dropdownColor: WoColors.surface,
                  style: WoText.bodyHi(),
                  decoration: woInput('Target Investment'),
                  items: _assets
                      .where((a) => a.type != 'real_estate')
                      .map((a) => DropdownMenuItem(value: a.id, child: Text(a.name)))
                      .toList(),
                  onChanged: (value) => setModalState(() => selectedAssetId = value),
                ),
                const SizedBox(height: 12),

                // Day of Month
                Row(
                  children: [
                    Expanded(
                      child: Text('SIP Day of Month', style: WoText.body()),
                    ),
                    Container(
                      decoration: woWell(),
                      child: Row(
                        children: [
                          IconButton(
                            icon: Icon(Icons.remove, color: WoColors.textMid),
                            onPressed: () => setModalState(() => dayOfMonth = (dayOfMonth - 1).clamp(1, 28)),
                          ),
                          Text('$dayOfMonth', style: WoText.num(size: 18)),
                          IconButton(
                            icon: Icon(Icons.add, color: WoColors.textMid),
                            onPressed: () => setModalState(() => dayOfMonth = (dayOfMonth + 1).clamp(1, 28)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Active Toggle
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Active', style: WoText.body()),
                    CupertinoSwitch(
                      value: isActive,
                      activeTrackColor: WoColors.mint,
                      onChanged: (value) => setModalState(() => isActive = value),
                    ),
                  ],
                ),

                const Spacer(),

                // Save Button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      if (nameController.text.isEmpty || selectedAssetId == null) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please fill all fields')));
                        return;
                      }

                      final amount = double.tryParse(amountController.text) ?? 0;
                      final companion = SipRecordsCompanion(
                        id: isEditing ? Value(existing.id) : Value(DateTime.now().millisecondsSinceEpoch.toString()),
                        assetId: Value(selectedAssetId!),
                        name: Value(nameController.text),
                        amount: Value(amount),
                        currencyCode: const Value('AED'),
                        dayOfMonth: Value(dayOfMonth),
                        isActive: Value(isActive),
                        startDate: isEditing ? Value(existing.startDate) : Value(DateTime.now()),
                      );

                      if (isEditing) {
                        await _repo!.updateSipRecord(existing.id, companion);
                      } else {
                        await _repo!.insertSipRecord(companion);
                      }

                      if (!context.mounted) return;
                      Navigator.pop(context);
                      _loadData();
                      HapticFeedback.mediumImpact();
                    },
                    style: WoButtons.primary,
                    child: Text(isEditing ? 'Update SIP' : 'Add SIP'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _confirmDeleteSIP(SipRecord sip) {
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Delete SIP?'),
        content: Text('Are you sure you want to delete "${sip.name}"?'),
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
              await _repo!.deleteSipRecord(sip.id);
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
