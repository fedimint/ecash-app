import 'package:ecashapp/lib.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum _IdentityMethod { npub, nip05 }

class ImportFollowsDialog extends StatefulWidget {
  final VoidCallback onImportComplete;

  const ImportFollowsDialog({super.key, required this.onImportComplete});

  @override
  State<ImportFollowsDialog> createState() => _ImportFollowsDialogState();
}

class _ImportFollowsDialogState extends State<ImportFollowsDialog> {
  _IdentityMethod _method = _IdentityMethod.nip05;
  final TextEditingController _inputController = TextEditingController();
  bool _processing = false;
  String? _identityError;

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  String _hintText(BuildContext context) {
    switch (_method) {
      case _IdentityMethod.npub:
        return 'npub1...';
      case _IdentityMethod.nip05:
        return 'user@domain.com';
    }
  }

  String _labelText(BuildContext context) {
    switch (_method) {
      case _IdentityMethod.npub:
        return context.l10n.nostrPublicKeyNpub;
      case _IdentityMethod.nip05:
        return context.l10n.nip05Identifier;
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

  Future<void> _startSync() async {
    if (!_isValidInput()) return;

    setState(() {
      _processing = true;
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

      // Start background sync (non-blocking)
      syncContacts(npub: npub);

      ToastService().show(
        message: context.l10n.syncingContactsInBackground,
        duration: const Duration(seconds: 2),
        onTap: () {},
        icon: const Icon(Icons.sync),
      );

      widget.onImportComplete();
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      AppLogger.instance.error('Failed to start contact sync: $e');
      setState(() {
        _processing = false;
        _identityError =
            _method == _IdentityMethod.nip05
                ? context.l10n.couldNotVerifyNip05
                : context.l10n.couldNotFindNpub;
      });
    }
  }

  void _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data == null || data.text == null || data.text!.isEmpty) {
      ToastService().show(
        message: context.l10n.clipboardIsEmpty,
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
        message: context.l10n.unrecognizedFormat,
        duration: const Duration(seconds: 3),
        onTap: () {},
        icon: const Icon(Icons.warning),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.l10n.syncContactsTitle,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.syncContactsDescription,
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
              labelText: _labelText(context),
              hintText: _hintText(context),
              errorText: _identityError,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste),
                onPressed: _pasteFromClipboard,
                tooltip: context.l10n.pasteFromClipboardTooltip,
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
                _startSync();
              }
            },
          ),
          const SizedBox(height: 8),

          // Help text
          Text(
            _method == _IdentityMethod.nip05
                ? context.l10n.enterNip05Hint
                : context.l10n.enterNpubHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 24),

          // Action button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _processing || !_isValidInput() ? null : _startSync,
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child:
                  _processing
                      ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : Text(context.l10n.startSyncing),
            ),
          ),
        ],
      ),
    );
  }
}
