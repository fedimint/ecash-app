import 'package:ecashapp/db.dart';
import 'package:ecashapp/lib.dart';
import 'package:flutter/material.dart';

/// A quick picker for selecting a contact with a lightning address.
/// Used in the send flow to quickly select a contact to pay.
class ContactPicker extends StatefulWidget {
  final void Function(Contact contact) onContactSelected;

  const ContactPicker({super.key, required this.onContactSelected});

  @override
  State<ContactPicker> createState() => _ContactPickerState();
}

class _ContactPickerState extends State<ContactPicker> {
  List<Contact> _contacts = [];
  List<Contact> _filteredContacts = [];
  bool _loading = true;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadContacts();
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
              return (contact.name?.toLowerCase().contains(query) ?? false) ||
                  (contact.displayName?.toLowerCase().contains(query) ??
                      false) ||
                  (contact.nip05?.toLowerCase().contains(query) ?? false) ||
                  (contact.lud16?.toLowerCase().contains(query) ?? false);
            }).toList();
      });
    }
  }

  Future<void> _loadContacts() async {
    final allContacts = await getAllContacts();
    // Filter to only contacts with lightning addresses
    final payableContacts =
        allContacts
            .where((c) => c.lud16 != null && c.lud16!.isNotEmpty)
            .toList();

    setState(() {
      _contacts = payableContacts;
      _filteredContacts = payableContacts;
      _loading = false;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Select Contact',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),

        // Search bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search contacts...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon:
                  _searchController.text.isNotEmpty
                      ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => _searchController.clear(),
                      )
                      : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),

        // Contact list
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(32),
            child: CircularProgressIndicator(),
          )
        else if (_filteredContacts.isEmpty)
          Padding(
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
                  _searchController.text.isNotEmpty
                      ? 'No contacts found'
                      : 'No payable contacts',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                if (_searchController.text.isEmpty)
                  Text(
                    'Add contacts with Lightning Addresses',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
              ],
            ),
          )
        else
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.all(8),
              itemCount: _filteredContacts.length,
              itemBuilder: (context, index) {
                final contact = _filteredContacts[index];
                return _ContactPickerItem(
                  contact: contact,
                  displayName: _getDisplayName(contact),
                  onTap: () {
                    widget.onContactSelected(contact);
                    Navigator.of(context).pop();
                  },
                );
              },
            ),
          ),

        // Cancel button
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.primary,
                side: BorderSide(color: theme.colorScheme.primary),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Cancel'),
            ),
          ),
        ),
      ],
    );
  }
}

class _ContactPickerItem extends StatelessWidget {
  final Contact contact;
  final String displayName;
  final VoidCallback onTap;

  const _ContactPickerItem({
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
