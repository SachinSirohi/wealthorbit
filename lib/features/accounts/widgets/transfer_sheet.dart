import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/wo_design.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/app_repository.dart';

/// Bottom sheet to move money between accounts, or pay a credit-card bill.
///
/// When [creditCard] is provided the sheet runs in "Pay Bill" mode: the
/// destination is fixed to that card and `payCreditCardBill` is used (which
/// also reduces a linked liability's outstanding amount).
class TransferSheet extends StatefulWidget {
  final AppRepository repository;
  final List<Account> accounts;
  final Account? creditCard;

  const TransferSheet({
    super.key,
    required this.repository,
    required this.accounts,
    this.creditCard,
  });

  static Future<bool?> show(
    BuildContext context, {
    required AppRepository repository,
    required List<Account> accounts,
    Account? creditCard,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => TransferSheet(
        repository: repository,
        accounts: accounts,
        creditCard: creditCard,
      ),
    );
  }

  @override
  State<TransferSheet> createState() => _TransferSheetState();
}

class _TransferSheetState extends State<TransferSheet> {
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();
  String? _fromId;
  String? _toId;
  DateTime _date = DateTime.now();
  bool _saving = false;

  bool get _isBillPay => widget.creditCard != null;

  @override
  void initState() {
    super.initState();
    if (_isBillPay) {
      _toId = widget.creditCard!.id;
      // Default funding account = first non-card account.
      _fromId = widget.accounts
          .firstWhere((a) => a.type != 'credit_card', orElse: () => widget.accounts.first)
          .id;
    } else {
      if (widget.accounts.isNotEmpty) _fromId = widget.accounts.first.id;
      if (widget.accounts.length > 1) _toId = widget.accounts[1].id;
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final amount = double.tryParse(_amountController.text) ?? 0;
    if (amount <= 0 || _fromId == null || _toId == null || _fromId == _toId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick two different accounts and a valid amount')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      if (_isBillPay) {
        await widget.repository.payCreditCardBill(
          fromAccountId: _fromId!,
          creditCardAccountId: _toId!,
          amount: amount,
          date: _date,
        );
      } else {
        await widget.repository.createTransfer(
          fromAccountId: _fromId!,
          toAccountId: _toId!,
          amount: amount,
          date: _date,
          note: _noteController.text,
        );
      }
      HapticFeedback.mediumImpact();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return WoSheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_isBillPay ? 'Pay Credit Card Bill' : 'Transfer Money', style: WoText.title()),
          const SizedBox(height: 20),
          _accountDropdown(
            label: 'From',
            value: _fromId,
            onChanged: (v) => setState(() => _fromId = v),
          ),
          const SizedBox(height: 14),
          _accountDropdown(
            label: _isBillPay ? 'To (Card)' : 'To',
            value: _toId,
            enabled: !_isBillPay,
            onChanged: (v) => setState(() => _toId = v),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: WoText.bodyHi(),
            decoration: woInput('Amount'),
          ),
          const SizedBox(height: 14),
          if (!_isBillPay) ...[
            TextField(
              controller: _noteController,
              style: WoText.bodyHi(),
              decoration: woInput('Note (optional)'),
            ),
            const SizedBox(height: 14),
          ],
          InkWell(
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime(2015),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (picked != null) setState(() => _date = picked);
            },
            child: InputDecorator(
              decoration: woInput('Date'),
              child: Text(
                DateFormat('MMM d, yyyy').format(_date),
                style: WoText.bodyHi(),
              ),
            ),
          ),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _saving ? null : _submit,
              style: WoButtons.primary,
              child: _saving
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                  : Text(_isBillPay ? 'Pay Bill' : 'Transfer'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _accountDropdown({
    required String label,
    required String? value,
    required ValueChanged<String?> onChanged,
    bool enabled = true,
  }) {
    return InputDecorator(
      decoration: woInput(label),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: WoColors.surface,
          icon: Icon(CupertinoIcons.chevron_down, size: 14, color: WoColors.textMid),
          onChanged: enabled ? onChanged : null,
          items: widget.accounts
              .map((a) => DropdownMenuItem(
                    value: a.id,
                    child: Text(
                      '${a.name} (${a.currencyCode})',
                      style: WoText.bodyHi(),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ))
              .toList(),
        ),
      ),
    );
  }
}
