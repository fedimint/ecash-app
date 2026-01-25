import 'package:ecashapp/lib.dart';
import 'package:ecashapp/nostr.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum _IdentityMethod { npub, nip05 }

enum _DialogState { identityInput, loadingFollows, profileList }

class ImportFollowsDialog extends StatefulWidget {
  final VoidCallback onImportComplete;
  final VoidCallback onSkip;

  const ImportFollowsDialog({
    super.key,
    required this.onImportComplete,
    required this.onSkip,
  });

  @override
  State<ImportFollowsDialog> createState() => _ImportFollowsDialogState();
}

class _ImportFollowsDialogState extends State<ImportFollowsDialog> {
  // Identity input state
  _IdentityMethod _method = _IdentityMethod.nip05;
  final TextEditingController _inputController = TextEditingController();
  bool _resolvingIdentity = false;
  String? _identityError;

  // Follows/profile state
  _DialogState _dialogState = _DialogState.identityInput;
  bool _importing = false;
  List<NostrProfile> _profiles = [];
  Set<String> _selectedNpubs = {};
  String? _errorMessage;

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  String get _hintText {
    switch (_method) {
      case _IdentityMethod.npub:
        return 'npub1...';
      case _IdentityMethod.nip05:
        return 'user@domain.com';
    }
  }

  String get _labelText {
    switch (_method) {
      case _IdentityMethod.npub:
        return 'Nostr Public Key (npub)';
      case _IdentityMethod.nip05:
        return 'NIP-05 Identifier';
    }
  }

  bool _isValidInput() {
    final input = _inputController.text.trim();
    if (input.isEmpty) return false;

    switch (_method) {
      case _IdentityMethod.npub:
        return input.startsWith('npub1') && input.length >= 60;
      case _IdentityMethod.nip05:
        return input.contains('@') && input.split('@').length == 2;
    }
  }

  Future<void> _lookUpFollows() async {
    if (!_isValidInput()) return;

    setState(() {
      _resolvingIdentity = true;
      _identityError = null;
    });

    try {
      final input = _inputController.text.trim();
      String npub;

      // Resolve nip-05 to npub if needed
      if (_method == _IdentityMethod.nip05) {
        npub = await verifyNip05(nip05Id: input);
      } else {
        npub = input;
      }

      setState(() {
        _resolvingIdentity = false;
        _dialogState = _DialogState.loadingFollows;
      });

      // Fetch follows for the provided npub
      final follows = await getFollowsForPubkey(npub: npub);
      if (follows.isEmpty) {
        setState(() {
          _dialogState = _DialogState.profileList;
          _errorMessage = 'No follows found for this identity';
        });
        return;
      }

      // Fetch profiles for the follows
      final profiles = await fetchNostrProfiles(npubs: follows);

      setState(() {
        _profiles = profiles;
        // Select all profiles with lightning addresses by default
        _selectedNpubs =
            profiles
                .where((p) => p.lud16 != null && p.lud16!.isNotEmpty)
                .map((p) => p.npub)
                .toSet();
        _dialogState = _DialogState.profileList;
      });
    } catch (e) {
      AppLogger.instance.error('Failed to load follows: $e');
      setState(() {
        _resolvingIdentity = false;
        if (_dialogState == _DialogState.loadingFollows) {
          _dialogState = _DialogState.profileList;
          _errorMessage = 'Failed to load follows from Nostr';
        } else {
          _identityError =
              _method == _IdentityMethod.nip05
                  ? 'Could not verify NIP-05 identifier'
                  : 'Could not find this npub on Nostr';
        }
      });
    }
  }

  void _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data == null || data.text == null || data.text!.isEmpty) {
      ToastService().show(
        message: 'Clipboard is empty',
        duration: const Duration(seconds: 2),
        onTap: () {},
        icon: const Icon(Icons.warning),
      );
      return;
    }

    String input = data.text!.trim();

    // Handle nostr: URI scheme
    if (input.toLowerCase().startsWith('nostr:')) {
      input = input.substring(6);
    }

    // Determine the method based on content
    if (input.startsWith('npub1')) {
      setState(() {
        _method = _IdentityMethod.npub;
        _inputController.text = input;
        _identityError = null;
      });
    } else if (input.contains('@')) {
      setState(() {
        _method = _IdentityMethod.nip05;
        _inputController.text = input;
        _identityError = null;
      });
    } else {
      ToastService().show(
        message: 'Unrecognized format',
        duration: const Duration(seconds: 3),
        onTap: () {},
        icon: const Icon(Icons.warning),
      );
    }
  }

  Future<void> _importSelected() async {
    if (_selectedNpubs.isEmpty) {
      ToastService().show(
        message: 'Please select at least one contact',
        duration: const Duration(seconds: 2),
        onTap: () {},
        icon: const Icon(Icons.warning),
      );
      return;
    }

    setState(() => _importing = true);

    try {
      final selectedProfiles =
          _profiles.where((p) => _selectedNpubs.contains(p.npub)).toList();

      final count = await importContacts(profiles: selectedProfiles);

      ToastService().show(
        message: 'Imported $count contacts',
        duration: const Duration(seconds: 2),
        onTap: () {},
        icon: const Icon(Icons.check),
      );

      widget.onImportComplete();
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      AppLogger.instance.error('Failed to import contacts: $e');
      ToastService().show(
        message: 'Failed to import contacts',
        duration: const Duration(seconds: 3),
        onTap: () {},
        icon: const Icon(Icons.error),
      );
      setState(() => _importing = false);
    }
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedNpubs.length == _profiles.length) {
        _selectedNpubs.clear();
      } else {
        _selectedNpubs = _profiles.map((p) => p.npub).toSet();
      }
    });
  }

  void _selectWithLightning() {
    setState(() {
      _selectedNpubs =
          _profiles
              .where((p) => p.lud16 != null && p.lud16!.isNotEmpty)
              .map((p) => p.npub)
              .toSet();
    });
  }

  @override
  Widget build(BuildContext context) {
    switch (_dialogState) {
      case _DialogState.identityInput:
        return _buildIdentityInput(context);
      case _DialogState.loadingFollows:
        return _buildLoading(context);
      case _DialogState.profileList:
        return _buildProfileList(context);
    }
  }

  Widget _buildIdentityInput(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Import Contacts',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Enter your Nostr identity to import your follows as contacts',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          // Method selector
          SegmentedButton<_IdentityMethod>(
            segments: const [
              ButtonSegment(
                value: _IdentityMethod.nip05,
                label: Text('NIP-05'),
                icon: Icon(Icons.alternate_email, size: 18),
              ),
              ButtonSegment(
                value: _IdentityMethod.npub,
                label: Text('npub'),
                icon: Icon(Icons.key, size: 18),
              ),
            ],
            selected: {_method},
            onSelectionChanged: (selection) {
              setState(() {
                _method = selection.first;
                _identityError = null;
              });
            },
          ),
          const SizedBox(height: 24),

          // Input field
          TextField(
            controller: _inputController,
            decoration: InputDecoration(
              labelText: _labelText,
              hintText: _hintText,
              errorText: _identityError,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste),
                onPressed: _pasteFromClipboard,
                tooltip: 'Paste from clipboard',
              ),
            ),
            keyboardType:
                _method == _IdentityMethod.nip05
                    ? TextInputType.emailAddress
                    : TextInputType.text,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) {
              setState(() {
                if (_identityError != null) {
                  _identityError = null;
                }
              });
            },
            onSubmitted: (_) {
              if (_isValidInput()) {
                _lookUpFollows();
              }
            },
          ),
          const SizedBox(height: 8),

          // Help text
          Text(
            _method == _IdentityMethod.nip05
                ? 'Enter your NIP-05 identifier like user@domain.com'
                : 'Enter your Nostr public key starting with npub1',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 24),

          // Action buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed:
                      _resolvingIdentity
                          ? null
                          : () {
                            widget.onSkip();
                            Navigator.of(context).pop();
                          },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.primary,
                    side: BorderSide(color: theme.colorScheme.primary),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Skip'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton(
                  onPressed:
                      _resolvingIdentity || !_isValidInput()
                          ? null
                          : _lookUpFollows,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child:
                      _resolvingIdentity
                          ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : const Text('Look Up'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLoading(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 24),
          Text(
            'Loading your Nostr follows...',
            style: theme.textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildProfileList(BuildContext context) {
    final theme = Theme.of(context);

    if (_errorMessage != null || _profiles.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.people_outline,
              size: 64,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              _errorMessage ?? 'No follows found',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'You can add contacts manually instead',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () {
                  widget.onSkip();
                  Navigator.of(context).pop();
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.primary,
                  side: BorderSide(color: theme.colorScheme.primary),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('Continue'),
              ),
            ),
          ],
        ),
      );
    }

    final profilesWithLn =
        _profiles.where((p) => p.lud16 != null && p.lud16!.isNotEmpty).length;

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Text(
                  'Import Contacts',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Found ${_profiles.length} follows ($profilesWithLn with Lightning Address)',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),

          // Selection controls
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: _toggleSelectAll,
                  icon: Icon(
                    _selectedNpubs.length == _profiles.length
                        ? Icons.deselect
                        : Icons.select_all,
                    size: 18,
                  ),
                  label: Text(
                    _selectedNpubs.length == _profiles.length
                        ? 'Deselect All'
                        : 'Select All',
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _selectWithLightning,
                  icon: const Icon(Icons.bolt, size: 18, color: Colors.amber),
                  label: const Text('With LN'),
                ),
              ],
            ),
          ),

          // Profile list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _profiles.length,
              itemBuilder: (context, index) {
                final profile = _profiles[index];
                final isSelected = _selectedNpubs.contains(profile.npub);
                final hasLn =
                    profile.lud16 != null && profile.lud16!.isNotEmpty;

                String displayName =
                    profile.displayName ??
                    profile.name ??
                    '${profile.npub.substring(0, 8)}...';

                return CheckboxListTile(
                  value: isSelected,
                  onChanged: (value) {
                    setState(() {
                      if (value == true) {
                        _selectedNpubs.add(profile.npub);
                      } else {
                        _selectedNpubs.remove(profile.npub);
                      }
                    });
                  },
                  secondary: CircleAvatar(
                    radius: 20,
                    backgroundColor: theme.colorScheme.primary.withValues(
                      alpha: 0.2,
                    ),
                    backgroundImage:
                        profile.picture != null && profile.picture!.isNotEmpty
                            ? NetworkImage(profile.picture!)
                            : null,
                    child:
                        profile.picture == null || profile.picture!.isEmpty
                            ? Icon(
                              Icons.person,
                              color: theme.colorScheme.primary,
                              size: 20,
                            )
                            : null,
                  ),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (hasLn) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.bolt, size: 16, color: Colors.amber),
                      ],
                    ],
                  ),
                  subtitle:
                      profile.nip05 != null && profile.nip05!.isNotEmpty
                          ? Text(
                            profile.nip05!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          )
                          : null,
                );
              },
            ),
          ),

          // Action buttons
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        _importing
                            ? null
                            : () {
                              widget.onSkip();
                              Navigator.of(context).pop();
                            },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.primary,
                      side: BorderSide(color: theme.colorScheme.primary),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Skip'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _importing ? null : _importSelected,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child:
                        _importing
                            ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                            : Text('Import (${_selectedNpubs.length})'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
