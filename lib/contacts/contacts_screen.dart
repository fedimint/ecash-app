import 'dart:async';

import 'package:ecashapp/contacts/contact_item.dart';
import 'package:ecashapp/contacts/contact_profile.dart';
import 'package:ecashapp/contacts/import_follows_dialog.dart';
import 'package:ecashapp/db.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
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
  List<Contact> _contacts = [];
  bool _loading = true;
  bool _hasSynced = false;
  final TextEditingController _searchController = TextEditingController();

  // Pagination state
  final ScrollController _scrollController = ScrollController();
  bool _hasMore = true;
  bool _isFetchingMore = false;
  Contact? _lastContact;

  // Search state
  Timer? _searchDebounce;
  String _currentSearchQuery = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _scrollController.addListener(_onScroll);
    _initialize();
  }

  @override
  void dispose() {
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

    if (!hasSynced && mounted) {
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
            await setContactsImported();
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

  void _showContactProfile(Contact contact) {
    showAppModalBottomSheet(
      context: context,
      childBuilder: () async {
        return ContactProfile(
          contact: contact,
          selectedFederation: widget.selectedFederation,
          onContactUpdated: () async {
            await _refreshContacts();
          },
        );
      },
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
                  const PopupMenuItem(
                    value: 'sync',
                    child: ListTile(
                      leading: Icon(Icons.sync),
                      title: Text('Sync from Nostr'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  if (_hasSynced)
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
          _loading
              ? const Center(child: CircularProgressIndicator())
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
                                        : 'No contacts yet',
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(
                                          color: theme.colorScheme.onSurface
                                              .withValues(alpha: 0.6),
                                        ),
                                  ),
                                  const SizedBox(height: 8),
                                  if (_searchController.text.isEmpty)
                                    Text(
                                      'Sync your contacts from Nostr',
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
                                    _contacts.length + (_hasMore ? 1 : 0),
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
                                    onTap: () => _showContactProfile(contact),
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
