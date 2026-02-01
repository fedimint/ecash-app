import 'package:ecashapp/lib.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum _IdentityMethod { npub, nip05 }

enum _DialogState { identityInput, loadingFollows, syncPreview }

class ImportFollowsDialog extends StatefulWidget {
  final VoidCallback onImportComplete;

  const ImportFollowsDialog({super.key, required this.onImportComplete});

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
  bool _syncing = false;
  String? _resolvedNpub;
  int _totalFollows = 0;
  int _profilesWithLn = 0;
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
        _resolvedNpub = npub;
        _dialogState = _DialogState.loadingFollows;
      });

      // Fetch follows for the provided npub
      final follows = await getFollowsForPubkey(npub: npub);
      if (follows.isEmpty) {
        setState(() {
          _dialogState = _DialogState.syncPreview;
          _errorMessage = 'No follows found for this identity';
        });
        return;
      }

      // Fetch profiles for the follows to count those with lightning addresses
      final profiles = await fetchNostrProfiles(npubs: follows);
      final withLn =
          profiles.where((p) => p.lud16 != null && p.lud16!.isNotEmpty).length;

      setState(() {
        _totalFollows = profiles.length;
        _profilesWithLn = withLn;
        _dialogState = _DialogState.syncPreview;
      });
    } catch (e) {
      AppLogger.instance.error('Failed to load follows: $e');
      setState(() {
        _resolvingIdentity = false;
        if (_dialogState == _DialogState.loadingFollows) {
          _dialogState = _DialogState.syncPreview;
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

  Future<void> _startSync() async {
    if (_resolvedNpub == null || _profilesWithLn == 0) {
      ToastService().show(
        message: 'No contacts with Lightning Address to sync',
        duration: const Duration(seconds: 2),
        onTap: () {},
        icon: const Icon(Icons.warning),
      );
      return;
    }

    setState(() => _syncing = true);

    try {
      // Setup sync configuration with the resolved npub
      await setupContactSync(npub: _resolvedNpub!);

      // Trigger immediate sync
      final (added, _, _) = await syncContactsNow();

      ToastService().show(
        message: 'Synced $added contacts',
        duration: const Duration(seconds: 2),
        onTap: () {},
        icon: const Icon(Icons.check),
      );

      widget.onImportComplete();
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      AppLogger.instance.error('Failed to sync contacts: $e');
      ToastService().show(
        message: 'Failed to sync contacts',
        duration: const Duration(seconds: 3),
        onTap: () {},
        icon: const Icon(Icons.error),
      );
      setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_dialogState) {
      case _DialogState.identityInput:
        return _buildIdentityInput(context);
      case _DialogState.loadingFollows:
        return _buildLoading(context);
      case _DialogState.syncPreview:
        return _buildSyncPreview(context);
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
            'Sync Contacts',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Enter your Nostr identity to sync your follows as contacts. Contacts will be updated automatically.',
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

          // Action button (single button, no skip)
          SizedBox(
            width: double.infinity,
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

  Widget _buildSyncPreview(BuildContext context) {
    final theme = Theme.of(context);

    if (_errorMessage != null || _profilesWithLn == 0) {
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
              _errorMessage ?? 'No contacts with Lightning Address found',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _totalFollows > 0
                  ? 'Found $_totalFollows follows, but none have a Lightning Address set up.'
                  : 'Only contacts with Lightning Addresses can be synced.',
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
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.sync, size: 64, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            'Ready to Sync',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Found $_totalFollows follows',
            style: theme.textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.bolt, size: 18, color: Colors.amber),
              const SizedBox(width: 4),
              Text(
                '$_profilesWithLn with Lightning Address',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 20,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Only contacts with Lightning Addresses will be synced. Your contacts will update automatically.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Action button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _syncing ? null : _startSync,
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child:
                  _syncing
                      ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : const Text('Start Syncing'),
            ),
          ),
        ],
      ),
    );
  }
}
