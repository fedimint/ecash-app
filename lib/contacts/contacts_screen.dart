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
  List<Contact> _filteredContacts = [];
  bool _loading = true;
  bool _hasSynced = false;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initialize();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final query = _searchController.text.toLowerCase();
    if (query.isEmpty) {
      setState(() {
        _filteredContacts = _contacts;
      });
    } else {
      setState(() {
        _filteredContacts =
            _contacts.where((contact) {
              return contact.npub.toLowerCase().contains(query) ||
                  (contact.name?.toLowerCase().contains(query) ?? false) ||
                  (contact.displayName?.toLowerCase().contains(query) ??
                      false) ||
                  (contact.nip05?.toLowerCase().contains(query) ?? false) ||
                  (contact.lud16?.toLowerCase().contains(query) ?? false);
            }).toList();
      });
    }
  }

  Future<void> _initialize() async {
    final hasSynced = await hasImportedContacts();
    final contacts = await getAllContacts();

    setState(() {
      _hasSynced = hasSynced;
      _contacts = contacts;
      _filteredContacts = contacts;
      _loading = false;
    });

    // Show sync dialog if first time
    if (!hasSynced && mounted) {
      _showSyncDialog();
    }
  }

  Future<void> _refreshContacts() async {
    final contacts = await getAllContacts();
    setState(() {
      _contacts = contacts;
      _onSearchChanged(); // Re-apply search filter
    });
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
                        _filteredContacts.isEmpty
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
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                itemCount: _filteredContacts.length,
                                itemBuilder: (context, index) {
                                  final contact = _filteredContacts[index];
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
