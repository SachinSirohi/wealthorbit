import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/wo_design.dart';
import '../../../core/utils/financial_calculations.dart';

/// XIRR Calculator - Calculate returns from investment transactions
class XIRRCalculatorSheet extends StatefulWidget {
  final String? investmentName;
  final List<Map<String, dynamic>>? initialTransactions;

  const XIRRCalculatorSheet({
    super.key,
    this.investmentName,
    this.initialTransactions,
  });

  @override
  State<XIRRCalculatorSheet> createState() => _XIRRCalculatorSheetState();
}

class _XIRRCalculatorSheetState extends State<XIRRCalculatorSheet> {
  final List<_CashflowEntry> _entries = [];
  double? _xirrResult;
  double? _absoluteReturn;
  double? _totalInvested;
  double? _currentValue;

  @override
  void initState() {
    super.initState();
    if (widget.initialTransactions != null) {
      for (final tx in widget.initialTransactions!) {
        _entries.add(_CashflowEntry(
          amount: tx['amount'] as double,
          date: tx['date'] as DateTime,
          isInvestment: tx['isInvestment'] as bool? ?? true,
        ));
      }
    } else {
      // Add sample entries for demo
      _entries.add(_CashflowEntry(amount: 0, date: DateTime.now(), isInvestment: true));
    }
  }

  void _addEntry() {
    setState(() {
      _entries.add(_CashflowEntry(amount: 0, date: DateTime.now(), isInvestment: true));
    });
  }

  void _removeEntry(int index) {
    if (_entries.length > 1) {
      setState(() {
        _entries.removeAt(index);
        _xirrResult = null;
      });
    }
  }

  void _calculateXIRR() {
    if (_entries.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least 2 entries (investments + current value)')),
      );
      return;
    }

    // Convert entries to cashflows
    final cashflows = <double>[];
    final dates = <DateTime>[];
    double invested = 0;
    double? exitValue;

    for (final entry in _entries) {
      if (entry.isInvestment) {
        cashflows.add(-entry.amount); // Investments are negative cashflow
        invested += entry.amount;
      } else {
        cashflows.add(entry.amount); // Redemptions/current value are positive
        exitValue = entry.amount;
      }
      dates.add(entry.date);
    }

    if (!cashflows.any((c) => c < 0) || !cashflows.any((c) => c > 0)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Need both investments and current value/redemptions')),
      );
      return;
    }

    final xirr = FinancialCalculations.calculateXIRR(cashflows, dates);
    final absoluteRet = exitValue != null && invested > 0
        ? ((exitValue - invested) / invested * 100)
        : 0.0;

    setState(() {
      _xirrResult = xirr * 100;
      _absoluteReturn = absoluteRet;
      _totalInvested = invested;
      _currentValue = exitValue;
    });

    HapticFeedback.mediumImpact();
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
          // Handle
          const SizedBox(height: 8),
          const WoSheetHandle(),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Row(
              children: [
                WoIconBubble(Icons.calculate_outlined, color: WoColors.mint, size: 46),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'XIRR Calculator',
                        style: WoText.title(),
                      ),
                      if (widget.investmentName != null)
                        Text(
                          widget.investmentName!,
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
          ),

          // Result Card (if calculated)
          if (_xirrResult != null) _buildResultCard(),

          // Instructions
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: WoNotice(
              'Add investments (negative) and current value/redemptions (positive) with dates',
              color: WoColors.blue,
              icon: Icons.info_outline,
            ),
          ),

          const SizedBox(height: 12),

          // Entries List
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: _entries.length,
              itemBuilder: (context, index) => _buildEntryCard(index),
            ),
          ),

          // Actions
          _buildBottomActions(),
        ],
      ),
    );
  }

  Widget _buildResultCard() {
    final isPositive = (_xirrResult ?? 0) >= 0;
    final accent = isPositive ? WoColors.mint : WoColors.red;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: woCard(tint: accent),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildResultMetric('XIRR', '${_xirrResult!.toStringAsFixed(2)}%', true),
                _buildResultMetric('Absolute', '${_absoluteReturn!.toStringAsFixed(1)}%', false),
              ],
            ),
            const SizedBox(height: 16),
            Container(height: 1, color: WoColors.border),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildResultMetric('Invested', _formatCurrency(_totalInvested ?? 0), false),
                _buildResultMetric('Current', _formatCurrency(_currentValue ?? 0), false),
              ],
            ),
          ],
        ),
      ).animate().fadeIn().scale(begin: const Offset(0.95, 0.95)),
    );
  }

  Widget _buildResultMetric(String label, String value, bool isPrimary) {
    final accent = (_xirrResult ?? 0) >= 0 ? WoColors.mint : WoColors.red;
    return Column(
      children: [
        Text(
          value,
          style: isPrimary ? WoText.display(color: accent) : WoText.num(size: 18),
        ),
        Text(
          label,
          style: WoText.caption(),
        ),
      ],
    );
  }

  Widget _buildEntryCard(int index) {
    final entry = _entries[index];
    final entryColor = entry.isInvestment ? WoColors.red : WoColors.mint;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: WoColors.inputFill,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: entryColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Type Toggle
              GestureDetector(
                onTap: () => setState(() => entry.isInvestment = !entry.isInvestment),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: entryColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(WoRadius.chip),
                    border: Border.all(color: entryColor.withValues(alpha: 0.3), width: 0.6),
                  ),
                  child: Text(
                    entry.isInvestment ? '− Investment' : '+ Value/Redeem',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: entryColor,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              if (_entries.length > 1)
                IconButton(
                  onPressed: () => _removeEntry(index),
                  icon: Icon(Icons.delete_outline, color: WoColors.textLo, size: 20),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              // Amount
              Expanded(
                flex: 2,
                child: TextField(
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: WoText.bodyHi(),
                  decoration: woInput('Amount').copyWith(
                    prefixText: 'AED ',
                    prefixStyle: WoText.body(color: WoColors.textLo),
                    fillColor: WoColors.surface,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  onChanged: (value) {
                    entry.amount = double.tryParse(value) ?? 0;
                    _xirrResult = null;
                  },
                ),
              ),
              const SizedBox(width: 12),
              // Date picker
              Expanded(
                flex: 2,
                child: GestureDetector(
                  onTap: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: entry.date,
                      firstDate: DateTime(2000),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (date != null) {
                      setState(() {
                        entry.date = date;
                        _xirrResult = null;
                      });
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: WoColors.surface,
                      borderRadius: BorderRadius.circular(WoRadius.control),
                      border: Border.all(color: WoColors.border),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.calendar_today, color: WoColors.textLo, size: 16),
                        const SizedBox(width: 8),
                        Text(
                          DateFormat('dd MMM yyyy').format(entry.date),
                          style: WoText.bodyHi(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBottomActions() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: WoColors.surfaceLo,
        border: Border(top: BorderSide(color: WoColors.border, width: 1)),
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _addEntry,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Entry'),
                style: WoButtons.ghost,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _calculateXIRR,
                icon: const Icon(Icons.calculate, size: 18),
                label: const Text('Calculate'),
                style: WoButtons.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatCurrency(double amount) => NumberFormat.currency(symbol: 'AED ', decimalDigits: 0).format(amount);
}

class _CashflowEntry {
  double amount;
  DateTime date;
  bool isInvestment;

  _CashflowEntry({
    required this.amount,
    required this.date,
    required this.isInvestment,
  });
}
