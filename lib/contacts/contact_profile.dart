import 'package:ecashapp/db.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/number_pad.dart';
import 'package:ecashapp/models.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

class ContactProfile extends StatefulWidget {
  final Contact contact;
  final FederationSelector? selectedFederation;
  final VoidCallback onContactDeleted;
  final VoidCallback onContactUpdated;

  const ContactProfile({
    super.key,
    required this.contact,
    this.selectedFederation,
    required this.onContactDeleted,
    required this.onContactUpdated,
  });

  @override
  State<ContactProfile> createState() => _ContactProfileState();
}

class _ContactProfileState extends State<ContactProfile> {
  late Contact _contact;
  List<(BigInt, ContactPayment)> _payments = [];
  bool _loadingPayments = true;
  bool _refreshing = false;
  bool _showAllPayments = false;

  @override
  void initState() {
    super.initState();
    _contact = widget.contact;
    _loadPaymentHistory();
  }

  Future<void> _loadPaymentHistory() async {
    final payments = await getContactPayments(npub: _contact.npub, limit: 20);
    setState(() {
      _payments = payments;
      _loadingPayments = false;
    });
  }

  Future<void> _refreshProfile() async {
    setState(() => _refreshing = true);
    try {
      final updated = await refreshContactProfile(npub: _contact.npub);
      setState(() {
        _contact = updated;
      });
      widget.onContactUpdated();
      ToastService().show(
        message: 'Profile refreshed',
        duration: const Duration(seconds: 2),
        onTap: () {},
        icon: const Icon(Icons.check),
      );
    } catch (e) {
      AppLogger.instance.error('Failed to refresh profile: $e');
      ToastService().show(
        message: 'Failed to refresh profile',
        duration: const Duration(seconds: 3),
        onTap: () {},
        icon: const Icon(Icons.error),
      );
    } finally {
      setState(() => _refreshing = false);
    }
  }

  Future<void> _deleteContact() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Delete Contact'),
            content: Text('Are you sure you want to delete $_displayName?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Delete'),
              ),
            ],
          ),
    );

    if (confirmed == true) {
      await deleteContact(npub: _contact.npub);
      widget.onContactDeleted();
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  void _payContact() async {
    if (_contact.lud16 == null || _contact.lud16!.isEmpty) {
      ToastService().show(
        message: 'This contact has no Lightning Address',
        duration: const Duration(seconds: 3),
        onTap: () {},
        icon: const Icon(Icons.warning),
      );
      return;
    }

    if (widget.selectedFederation == null) {
      ToastService().show(
        message: 'Please select a federation first',
        duration: const Duration(seconds: 3),
        onTap: () {},
        icon: const Icon(Icons.warning),
      );
      return;
    }

    // Get BTC prices for the number pad
    final btcPrices = <FiatCurrency, double>{};
    final prices = await getAllBtcPrices();
    if (prices != null) {
      for (final (currency, price) in prices) {
        btcPrices[currency] = price.toDouble();
      }
    }

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) => NumberPad(
              fed: widget.selectedFederation!,
              paymentType: PaymentType.lightning,
              btcPrices: btcPrices,
              lightningAddressOrLnurl: _contact.lud16,
            ),
      ),
    );
  }

  String get _displayName {
    if (_contact.displayName != null && _contact.displayName!.isNotEmpty) {
      return _contact.displayName!;
    }
    if (_contact.name != null && _contact.name!.isNotEmpty) {
      return _contact.name!;
    }
    final npub = _contact.npub;
    if (npub.length > 16) {
      return '${npub.substring(0, 8)}...${npub.substring(npub.length - 8)}';
    }
    return npub;
  }

  String _formatTimestamp(BigInt timestampMs) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestampMs.toInt());
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      return DateFormat.jm().format(date);
    } else if (diff.inDays == 1) {
      return 'Yesterday';
    } else if (diff.inDays < 7) {
      return DateFormat.E().format(date);
    } else {
      return DateFormat.yMMMd().format(date);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );
    final hasLightningAddress =
        _contact.lud16 != null && _contact.lud16!.isNotEmpty;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Profile header
          CircleAvatar(
            radius: 48,
            backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
            backgroundImage:
                _contact.picture != null && _contact.picture!.isNotEmpty
                    ? NetworkImage(_contact.picture!)
                    : null,
            child:
                _contact.picture == null || _contact.picture!.isEmpty
                    ? Icon(
                      Icons.person,
                      color: theme.colorScheme.primary,
                      size: 48,
                    )
                    : null,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  _displayName,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              if (_contact.nip05Verified) ...[
                const SizedBox(width: 8),
                Icon(
                  Icons.verified,
                  color: theme.colorScheme.primary,
                  size: 24,
                ),
              ],
            ],
          ),
          if (_contact.nip05 != null && _contact.nip05!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              _contact.nip05!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
          if (_contact.about != null && _contact.about!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              _contact.about!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          // Lightning Address (inline, only if present)
          if (hasLightningAddress) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.bolt, color: Colors.amber, size: 18),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    _contact.lud16!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _contact.lud16!));
                    ToastService().show(
                      message: 'Copied to clipboard',
                      duration: const Duration(seconds: 2),
                      onTap: () {},
                      icon: const Icon(Icons.check),
                    );
                  },
                ),
              ],
            ),
          ],

          const SizedBox(height: 24),

          // Hero Pay button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: hasLightningAddress ? _payContact : null,
              icon: const Icon(Icons.bolt, color: Colors.black),
              label: Text('Pay $_displayName'),
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: Colors.black,
                disabledBackgroundColor: theme.colorScheme.primary.withValues(
                  alpha: 0.3,
                ),
                disabledForegroundColor: Colors.black.withValues(alpha: 0.5),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),

          // Payment history (only shown if payments exist)
          if (!_loadingPayments && _payments.isNotEmpty) ...[
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Payment History',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Column(
              children: [
                ...(_showAllPayments ? _payments : _payments.take(3)).map((
                  entry,
                ) {
                  final (timestamp, payment) = entry;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.arrow_upward,
                          color: theme.colorScheme.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                formatBalance(
                                  payment.amountMsats,
                                  false,
                                  bitcoinDisplay,
                                ),
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (payment.note != null &&
                                  payment.note!.isNotEmpty)
                                Text(
                                  payment.note!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.5),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ),
                        Text(
                          _formatTimestamp(timestamp),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                if (_payments.length > 3 && !_showAllPayments)
                  TextButton(
                    onPressed: () => setState(() => _showAllPayments = true),
                    child: Text(
                      'Show all ${_payments.length} payments',
                      style: TextStyle(color: theme.colorScheme.primary),
                    ),
                  ),
              ],
            ),
          ],

          const SizedBox(height: 32),

          // Minimal footer
          Divider(color: theme.colorScheme.outlineVariant),
          const SizedBox(height: 16),

          // npub row - subtle, copyable
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  _contact.npub,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: _contact.npub));
                  ToastService().show(
                    message: 'npub copied to clipboard',
                    duration: const Duration(seconds: 2),
                    onTap: () {},
                    icon: const Icon(Icons.check),
                  );
                },
                child: Icon(
                  Icons.copy,
                  size: 14,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Action text links
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: _refreshing ? null : _refreshProfile,
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
                child:
                    _refreshing
                        ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : Text(
                          'Refresh',
                          style: TextStyle(color: theme.colorScheme.primary),
                        ),
              ),
              Text(
                ' • ',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                ),
              ),
              TextButton(
                onPressed: _deleteContact,
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
                child: Text(
                  'Delete',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
