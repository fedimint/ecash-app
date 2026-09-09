import 'package:ecashapp/detail_row.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Lets the user read and export the invite codes for the federations they
/// have joined.
///
/// The seed phrase restores funds but records nothing about *which*
/// federations hold them, and the Nostr backup of these codes is best effort
/// by design (relays may prune). Without this screen the user has no
/// self-custodied copy of their federation membership.
///
/// Invite codes are not secrets — they are the same strings handed out to
/// invite people to a federation, and hold no spending authority — so unlike
/// the seed phrase this screen is deliberately not behind the PIN gate.
class InviteCodesScreen extends StatefulWidget {
  const InviteCodesScreen({super.key});

  @override
  State<InviteCodesScreen> createState() => _InviteCodesScreenState();
}

class _InviteCodesScreenState extends State<InviteCodesScreen> {
  List<(FederationSelector, String)>? _inviteCodes;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final codes = await federationInviteCodes();
      if (!mounted) return;
      setState(() {
        _inviteCodes = codes;
        _loading = false;
      });
    } catch (e) {
      AppLogger.instance.error('Could not load invite codes: $e');
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  /// Plain text intended to be pasted next to a written seed phrase, so each
  /// code is labelled with the federation it belongs to rather than being an
  /// anonymous blob.
  String _asExportText(List<(FederationSelector, String)> codes) {
    return codes
        .map((entry) => '${entry.$1.federationName}\n${entry.$2}')
        .join('\n\n');
  }

  void _copyAll(List<(FederationSelector, String)> codes) {
    Clipboard.setData(ClipboardData(text: _asExportText(codes)));
    ToastService().show(
      message: context.l10n.allInviteCodesCopied,
      duration: const Duration(seconds: 5),
      onTap: () {},
      icon: const Icon(Icons.check),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.inviteCodesTitle)),
      body: Builder(
        builder: (context) {
          if (_loading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (_failed) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  context.l10n.couldNotLoadInviteCodes,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            );
          }

          final codes = _inviteCodes ?? const [];
          if (codes.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  context.l10n.noFederationsToExport,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                context.l10n.inviteCodesExplanation,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              ...codes.map(
                (entry) => Card(
                  elevation: 2,
                  margin: const EdgeInsets.only(bottom: 12),
                  color: theme.colorScheme.surface,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    // Shown in full, wrapping, rather than abbreviated. This
                    // screen exists so the codes can be recorded next to a
                    // written seed phrase, and `abbreviate` renders anything
                    // over 14 characters as `first7...last7`, which cannot be
                    // transcribed or checked against a copy made earlier. The
                    // row already uses a monospace face, which is what makes
                    // reading a long code back character by character workable.
                    child: CopyableDetailRow(
                      label: entry.$1.federationName,
                      value: entry.$2,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _copyAll(codes),
                  icon: const Icon(Icons.copy_all),
                  label: Text(context.l10n.copyAllInviteCodes),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.primary,
                    side: BorderSide(color: theme.colorScheme.primary),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
