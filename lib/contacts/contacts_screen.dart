import 'package:ecashapp/contacts/add_contact_dialog.dart';
import 'package:ecashapp/contacts/contact_item.dart';
import 'package:ecashapp/contacts/contact_profile.dart';
import 'package:ecashapp/contacts/import_follows_dialog.dart';
import 'package:ecashapp/db.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/theme.dart';
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
  bool _hasImported = false;
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
    final hasImported = await hasImportedContacts();
    final contacts = await getAllContacts();

    setState(() {
      _hasImported = hasImported;
      _contacts = contacts;
      _filteredContacts = contacts;
      _loading = false;
    });

    // Show import dialog if first time
    if (!hasImported && mounted) {
      _showImportDialog();
    }
  }

  Future<void> _refreshContacts() async {
    final contacts = await getAllContacts();
    setState(() {
      _contacts = contacts;
      _onSearchChanged(); // Re-apply search filter
    });
  }

  void _showImportDialog() {
    showAppModalBottomSheet(
      context: context,
      childBuilder: () async {
        return ImportFollowsDialog(
          onImportComplete: () async {
            await setContactsImported();
            await _refreshContacts();
            setState(() {
              _hasImported = true;
            });
          },
          onSkip: () async {
            await setContactsImported();
            setState(() {
              _hasImported = true;
            });
          },
        );
      },
    );
  }

  void _showAddContactDialog() {
    showAppModalBottomSheet(
      context: context,
      childBuilder: () async {
        return AddContactDialog(
          onContactAdded: () async {
            await _refreshContacts();
          },
        );
      },
    );
  }

  void _showContactProfile(Contact contact) {
    showAppModalBottomSheet(
      context: context,
      childBuilder: () async {
        return ContactProfile(
          contact: contact,
          selectedFederation: widget.selectedFederation,
          onContactDeleted: () async {
            await _refreshContacts();
          },
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
          if (_hasImported)
            IconButton(
              icon: const Icon(Icons.download),
              onPressed: _showImportDialog,
              tooltip: 'Import from Nostr',
            ),
          IconButton(
            icon: const Icon(Icons.person_add),
            onPressed: _showAddContactDialog,
            tooltip: 'Add contact',
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
                                      'Add contacts manually or import from Nostr',
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
