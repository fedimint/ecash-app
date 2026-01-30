import 'package:ecashapp/db.dart';
import 'package:flutter/material.dart';

class ContactItem extends StatelessWidget {
  final Contact contact;
  final VoidCallback onTap;

  const ContactItem({super.key, required this.contact, required this.onTap});

  String get displayName {
    if (contact.displayName != null && contact.displayName!.isNotEmpty) {
      return contact.displayName!;
    }
    if (contact.name != null && contact.name!.isNotEmpty) {
      return contact.name!;
    }
    // Truncate npub for display
    final npub = contact.npub;
    if (npub.length > 16) {
      return '${npub.substring(0, 8)}...${npub.substring(npub.length - 8)}';
    }
    return npub;
  }

  String? get secondaryText {
    // Show NIP-05 if available and verified
    if (contact.nip05 != null && contact.nip05!.isNotEmpty) {
      return contact.nip05;
    }
    // Show lightning address if available
    if (contact.lud16 != null && contact.lud16!.isNotEmpty) {
      return contact.lud16;
    }
    return null;
  }

  bool get hasLightningAddress =>
      contact.lud16 != null && contact.lud16!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // Profile picture
                CircleAvatar(
                  radius: 24,
                  backgroundColor: theme.colorScheme.primary.withValues(
                    alpha: 0.2,
                  ),
                  backgroundImage:
                      contact.picture != null && contact.picture!.isNotEmpty
                          ? NetworkImage(contact.picture!)
                          : null,
                  child:
                      contact.picture == null || contact.picture!.isEmpty
                          ? Icon(
                            Icons.person,
                            color: theme.colorScheme.primary,
                            size: 28,
                          )
                          : null,
                ),
                const SizedBox(width: 12),
                // Name and secondary info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              displayName,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.onSurface,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (contact.nip05Verified) ...[
                            const SizedBox(width: 4),
                            Icon(
                              Icons.verified,
                              size: 16,
                              color: theme.colorScheme.primary,
                            ),
                          ],
                        ],
                      ),
                      if (secondaryText != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          secondaryText!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.6,
                            ),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                // Lightning indicator
                if (hasLightningAddress)
                  Icon(Icons.bolt, color: Colors.amber, size: 20)
                else
                  Icon(
                    Icons.bolt,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
                    size: 20,
                  ),
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
