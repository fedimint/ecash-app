import 'dart:async';

import 'package:ecashapp/db.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/number_pad.dart';
import 'package:ecashapp/pay_preview.dart';
import 'package:ecashapp/scan.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/models.dart';
import 'package:flutter/material.dart';

sealed class _DetectedInput {
  const _DetectedInput();
}

class _DetectedBolt11 extends _DetectedInput {
  final String invoice;
  const _DetectedBolt11(this.invoice);
}

class _DetectedLnAddress extends _DetectedInput {
  final String address;
  const _DetectedLnAddress(this.address);
}

class RecipientEntry extends StatefulWidget {
  final FederationSelector fed;
  final Map<FiatCurrency, double> btcPrices;
  final String? prefilledRecipient;

  const RecipientEntry({
    super.key,
    required this.fed,
    required this.btcPrices,
    this.prefilledRecipient,
  });

  @override
  State<RecipientEntry> createState() => _RecipientEntryState();
}

class _RecipientEntryState extends State<RecipientEntry> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<Contact> _contacts = [];
  List<Contact> _filteredContacts = [];
  bool _loadingContacts = true;

  Timer? _searchDebounce;
  String _currentQuery = '';

  _DetectedInput? _parsedInput;

  @override
  void initState() {
    super.initState();
    _loadContacts();
    _inputController.addListener(_onInputChanged);

    if (widget.prefilledRecipient != null) {
      _inputController.text = widget.prefilledRecipient!;
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _inputController.removeListener(_onInputChanged);
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onInputChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      final query = _inputController.text.trim();
      if (query == _currentQuery) return;
      _currentQuery = query;
      _filterContacts(query);
      _tryParseInput(query);
    });
  }

  Future<void> _loadContacts() async {
    try {
      final allContacts = await getAllContacts();
      final payable =
          allContacts
              .where((c) => c.lud16 != null && c.lud16!.isNotEmpty)
              .toList();
      if (!mounted) return;
      setState(() {
        _contacts = payable;
        _filteredContacts = payable;
        _loadingContacts = false;
      });
    } catch (e) {
      AppLogger.instance.error('Failed to load contacts: $e');
      if (!mounted) return;
      setState(() => _loadingContacts = false);
    }
  }

  void _filterContacts(String query) {
    if (query.isEmpty) {
      setState(() => _filteredContacts = _contacts);
      return;
    }
    final lower = query.toLowerCase();
    setState(() {
      _filteredContacts =
          _contacts.where((contact) {
            return (contact.name?.toLowerCase().contains(lower) ?? false) ||
                (contact.displayName?.toLowerCase().contains(lower) ?? false) ||
                (contact.nip05?.toLowerCase().contains(lower) ?? false) ||
                (contact.lud16?.toLowerCase().contains(lower) ?? false);
          }).toList();
    });
  }

  void _tryParseInput(String text) {
    if (text.isEmpty) {
      setState(() => _parsedInput = null);
      return;
    }

    final trimmed = text.trim();
    final lower = trimmed.toLowerCase();

    final isBolt11 =
        lower.startsWith('lnbc') ||
        lower.startsWith('lntb') ||
        lower.startsWith('lnbcrt') ||
        lower.startsWith('lntbs');

    final atIndex = lower.indexOf('@');
    final isLnAddress = atIndex > 0 && atIndex == lower.lastIndexOf('@');

    final isLnurl = lower.startsWith('lnurl') || lower.startsWith('lightning:');

    setState(() {
      if (isBolt11) {
        _parsedInput = _DetectedBolt11(trimmed);
      } else if (isLnAddress || isLnurl) {
        _parsedInput = _DetectedLnAddress(trimmed);
      } else {
        _parsedInput = null;
      }
    });
  }

  String _getDisplayName(Contact contact) {
    if (contact.displayName != null && contact.displayName!.isNotEmpty) {
      return contact.displayName!;
    }
    if (contact.name != null && contact.name!.isNotEmpty) {
      return contact.name!;
    }
    final npub = contact.npub;
    if (npub.length > 16) {
      return '${npub.substring(0, 8)}...${npub.substring(npub.length - 8)}';
    }
    return npub;
  }

  void _selectContact(Contact contact) {
    _navigateToNumberPad(contact.lud16!);
  }

  void _selectParsedInput() {
    switch (_parsedInput!) {
      case _DetectedBolt11(:final invoice):
        _showPreviewForBolt11(invoice);
      case _DetectedLnAddress(:final address):
        _navigateToNumberPad(address);
    }
  }

  Future<void> _showPreviewForBolt11(String bolt11) async {
    try {
      await showAppModalBottomSheet(
        context: context,
        errorMessage:
            'Invalid lightning invoice. Please check the invoice and try again.',
        childBuilder: () async {
          final preview = await paymentPreview(
            federationId: widget.fed.federationId,
            bolt11: bolt11,
          );
          return PaymentPreviewWidget(fed: widget.fed, paymentPreview: preview);
        },
      );
    } catch (e) {
      AppLogger.instance.error('Error showing payment preview: $e');
      ToastService().show(
        message: 'Could not get payment details',
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: const Icon(Icons.error),
      );
    }
  }

  void _navigateToNumberPad(String lnAddressOrLnurl) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => NumberPad(
              fed: widget.fed,
              paymentType: PaymentType.lightning,
              btcPrices: widget.btcPrices,
              lightningAddressOrLnurl: lnAddressOrLnurl,
            ),
      ),
    );
  }

  void _openScanner() async {
    final scannedText = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder:
            (_) => ScanQRPage(
              selectedFed: widget.fed,
              paymentType: PaymentType.lightning,
              interceptMode: true,
              onPay: (_, _) {},
            ),
      ),
    );

    if (scannedText == null || !mounted) return;

    try {
      final result = await parseScannedTextForFederation(
        text: scannedText,
        federation: widget.fed,
      );
      final parsed = result.$1;

      if (parsed is ParsedText_LightningInvoice) {
        if (!mounted) return;
        _showPreviewForBolt11(parsed.field0);
      } else if (parsed is ParsedText_LightningAddressOrLnurl) {
        if (!mounted) return;
        _inputController.text = parsed.field0;
      }
    } catch (e) {
      AppLogger.instance.error('Error parsing scanned text: $e');
      ToastService().show(
        message: 'Could not parse scanned code',
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: const Icon(Icons.error),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'Send To',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
          actions: [
            IconButton(
              icon: const Icon(Icons.qr_code_scanner),
              onPressed: _openScanner,
              tooltip: 'Scan QR code',
            ),
          ],
        ),
        body: Column(
          children: [
            // "To" input field
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _inputController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'To',
                  hintText: 'Name, lightning address, or invoice',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon:
                      _inputController.text.isNotEmpty
                          ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _inputController.clear();
                              setState(() {
                                _parsedInput = null;
                                _filteredContacts = _contacts;
                                _currentQuery = '';
                              });
                            },
                          )
                          : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
            ),

            // Content area
            Expanded(child: _buildContent(theme)),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    final items = <Widget>[];

    // Parsed input suggestion
    if (_parsedInput != null) {
      items.add(_buildParsedInputTile(theme));
      items.add(const Divider());
    }

    // Contact list (only shown when user has typed something)
    if (_currentQuery.isNotEmpty) {
      if (_loadingContacts) {
        items.add(
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          ),
        );
      } else if (_filteredContacts.isEmpty && _parsedInput == null) {
        items.add(_buildEmptyState(theme));
      } else {
        for (final contact in _filteredContacts) {
          items.add(
            _ContactTile(
              contact: contact,
              displayName: _getDisplayName(contact),
              onTap: () => _selectContact(contact),
            ),
          );
        }
      }
    }

    return ListView(controller: _scrollController, children: items);
  }

  Widget _buildParsedInputTile(ThemeData theme) {
    final String title;
    final String subtitle;
    final IconData icon;

    switch (_parsedInput!) {
      case _DetectedBolt11(:final invoice):
        title = 'Lightning Invoice';
        subtitle = getAbbreviatedText(invoice);
        icon = Icons.flash_on;
      case _DetectedLnAddress(:final address):
        title = address;
        subtitle = 'Lightning Address';
        icon = Icons.alternate_email;
    }

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Colors.amber.withValues(alpha: 0.2),
        child: Icon(icon, color: Colors.amber),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(subtitle),
      onTap: _selectParsedInput,
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          Icon(
            Icons.people_outline,
            size: 48,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 12),
          Text(
            'No contacts found',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          Text(
            'Try a lightning address or invoice instead',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  final Contact contact;
  final String displayName;
  final VoidCallback onTap;

  const _ContactTile({
    required this.contact,
    required this.displayName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
        backgroundImage:
            contact.picture != null && contact.picture!.isNotEmpty
                ? NetworkImage(contact.picture!)
                : null,
        child:
            contact.picture == null || contact.picture!.isEmpty
                ? Icon(Icons.person, color: theme.colorScheme.primary, size: 20)
                : null,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (contact.nip05Verified) ...[
            const SizedBox(width: 4),
            Icon(Icons.verified, size: 14, color: theme.colorScheme.primary),
          ],
        ],
      ),
      subtitle: Text(
        contact.lud16!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
      trailing: const Icon(Icons.bolt, color: Colors.amber, size: 20),
    );
  }
}
