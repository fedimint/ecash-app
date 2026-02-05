import 'dart:async';

import 'package:ecashapp/contacts/contact_item.dart';
import 'package:ecashapp/contacts/import_follows_dialog.dart';
import 'package:ecashapp/db.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/models.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/number_pad.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/toast.dart';
import 'package:flutter/material.dart';

class ContactsScreen extends StatefulWidget {
  final FederationSelector? selectedFederation;

  const ContactsScreen({super.key, this.selectedFederation});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final List<Contact> _contacts = [];
  bool _loading = true;
  bool _hasSynced = false;
  bool _syncing = false;
  int _syncedCount = 0;
  final TextEditingController _searchController = TextEditingController();

  // Pagination state
  final ScrollController _scrollController = ScrollController();
  bool _hasMore = true;
  bool _isFetchingMore = false;
  Contact? _lastContact;

  // Search state
  Timer? _searchDebounce;
  String _currentSearchQuery = '';

  // Event subscription for sync events
  StreamSubscription<MultimintEvent>? _eventSubscription;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _scrollController.addListener(_onScroll);
    _subscribeToSyncEvents();
    _initialize();
  }

  void _subscribeToSyncEvents() {
    _eventSubscription = subscribeMultimintEvents().listen((event) {
      if (event is MultimintEvent_ContactSync) {
        final syncEvent = event.field0;
        if (syncEvent is ContactSyncEventKind_Started) {
          if (mounted) {
            setState(() {
              _syncing = true;
              _syncedCount = 0;
            });
          }
        } else if (syncEvent is ContactSyncEventKind_Progress) {
          if (mounted) {
            setState(() {
              _syncedCount = syncEvent.synced.toInt();
            });
          }
        } else if (syncEvent is ContactSyncEventKind_Completed) {
          if (mounted) {
            setState(() {
              _syncing = false;
              _hasSynced = true;
              _syncedCount = 0;
            });
            _refreshContacts();
          }
        } else if (syncEvent is ContactSyncEventKind_Error) {
          if (mounted) {
            setState(() {
              _syncing = false;
              _syncedCount = 0;
            });
          }
        }
      }
    });
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      final query = _searchController.text.trim();
      if (query == _currentSearchQuery) return;

      setState(() {
        _currentSearchQuery = query;
      });

      _loadContacts(); // Reset and load first page
    });
  }

  Future<void> _initialize() async {
    final hasSynced = await hasImportedContacts();
    setState(() {
      _hasSynced = hasSynced;
      _loading = false;
    });

    await _loadContacts(); // Load first page

    if (!_syncing && !hasSynced && mounted) {
      _showSyncDialog();
    }
  }

  Future<void> _loadContacts({bool loadMore = false}) async {
    if (_isFetchingMore) return;

    setState(() => _isFetchingMore = true);

    if (!loadMore) {
      setState(() {
        _contacts.clear();
        _hasMore = true;
        _lastContact = null;
      });
    }

    try {
      final newContacts =
          _currentSearchQuery.isEmpty
              ? await paginateContacts(
                cursorLastPaidAt: loadMore ? _lastContact?.lastPaidAt : null,
                cursorCreatedAt: loadMore ? _lastContact?.createdAt : null,
                cursorNpub: loadMore ? _lastContact?.npub : null,
                limit: 10,
              )
              : await paginateSearchContacts(
                query: _currentSearchQuery,
                cursorLastPaidAt: loadMore ? _lastContact?.lastPaidAt : null,
                cursorCreatedAt: loadMore ? _lastContact?.createdAt : null,
                cursorNpub: loadMore ? _lastContact?.npub : null,
                limit: 10,
              );

      if (!mounted) return;

      setState(() {
        _contacts.addAll(newContacts);
        if (newContacts.length < 10) _hasMore = false;
        if (newContacts.isNotEmpty) _lastContact = newContacts.last;
        _isFetchingMore = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _isFetchingMore = false);
      }
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 100 &&
        !_isFetchingMore &&
        _hasMore) {
      _loadContacts(loadMore: true);
    }
  }

  Future<void> _refreshContacts() async {
    await _loadContacts(); // Reload first page
  }

  void _showSyncDialog() {
    showAppModalBottomSheet(
      context: context,
      childBuilder: () async {
        return ImportFollowsDialog(
          onImportComplete: () async {
            await _refreshContacts();
            setState(() {
              _hasSynced = true;
            });
          },
        );
      },
    );
  }

  Future<void> _stopSyncingAndClearContacts() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Stop Syncing'),
            content: const Text(
              'This will remove all synced contacts and stop automatic syncing. You can set up syncing again later.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Stop Syncing'),
              ),
            ],
          ),
    );

    if (confirmed == true) {
      final count = await clearContactsAndStopSync();
      await _refreshContacts();
      setState(() {
        _hasSynced = false;
      });
      if (mounted) {
        ToastService().show(
          message: 'Removed $count contacts',
          duration: const Duration(seconds: 2),
          onTap: () {},
          icon: const Icon(Icons.check),
        );
      }
    }
  }

  void _payContact(Contact contact) async {
    // Validate Federation Selection
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

    // Navigate to NumberPad
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) => NumberPad(
              fed: widget.selectedFederation!,
              paymentType: PaymentType.lightning,
              btcPrices: btcPrices,
              lightningAddressOrLnurl: contact.lud16,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              switch (value) {
                case 'sync':
                  _showSyncDialog();
                  break;
                case 'stop':
                  _stopSyncingAndClearContacts();
                  break;
              }
            },
            itemBuilder:
                (context) => [
                  if (!_syncing && !_hasSynced)
                    const PopupMenuItem(
                      value: 'sync',
                      child: ListTile(
                        leading: Icon(Icons.sync),
                        title: Text('Sync from Nostr'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  if (_syncing || _hasSynced)
                    PopupMenuItem(
                      value: 'stop',
                      child: ListTile(
                        leading: Icon(
                          Icons.sync_disabled,
                          color: theme.colorScheme.error,
                        ),
                        title: Text(
                          'Stop Syncing',
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                ],
          ),
        ],
      ),
      body:
          _loading || _syncing
              ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(),
                    if (_syncing) ...[
                      const SizedBox(height: 24),
                      Text(
                        _syncedCount > 0
                            ? 'Syncing contacts: $_syncedCount synced'
                            : 'Syncing contacts...',
                        style: theme.textTheme.bodyLarge,
                      ),
                    ],
                  ],
                ),
              )
              : Column(
                children: [
                  // Search bar
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search contacts...',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon:
                            _searchController.text.isNotEmpty
                                ? IconButton(
                                  icon: const Icon(Icons.clear),
                                  onPressed: () {
                                    _searchController.clear();
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
                  // Contact list
                  Expanded(
                    child:
                        _contacts.isEmpty && !_isFetchingMore
                            ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.people_outline,
                                    size: 64,
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.3),
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    _searchController.text.isNotEmpty
                                        ? 'No contacts found'
                                        : 'No payable contacts',
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(
                                          color: theme.colorScheme.onSurface
                                              .withValues(alpha: 0.6),
                                        ),
                                  ),
                                  const SizedBox(height: 8),
                                  if (_searchController.text.isEmpty)
                                    Text(
                                      'Sync contacts with Lightning Addresses',
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: theme.colorScheme.onSurface
                                                .withValues(alpha: 0.4),
                                          ),
                                      textAlign: TextAlign.center,
                                    ),
                                ],
                              ),
                            )
                            : RefreshIndicator(
                              onRefresh: _refreshContacts,
                              child: ListView.builder(
                                controller: _scrollController,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                itemCount:
                                    _contacts.length +
                                    (_isFetchingMore ? 1 : 0),
                                itemBuilder: (context, index) {
                                  if (index >= _contacts.length) {
                                    // Loading indicator for next page
                                    return const Padding(
                                      padding: EdgeInsets.symmetric(
                                        vertical: 12.0,
                                      ),
                                      child: Center(
                                        child: CircularProgressIndicator(),
                                      ),
                                    );
                                  }

                                  final contact = _contacts[index];
                                  return ContactItem(
                                    contact: contact,
                                    onTap: () => _payContact(contact),
                                  );
                                },
                              ),
                            ),
                  ),
                ],
              ),
    );
  }
}
