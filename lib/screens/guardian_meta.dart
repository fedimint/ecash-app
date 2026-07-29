import 'dart:convert';

import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Meta fields this screen exposes as guided flows. Everything else in the
/// document is preserved untouched and summarised as "other changes".
enum _MetaField { federationName, profilePicture, welcomeMessage, expiryDate }

extension _MetaFieldKey on _MetaField {
  String get key => switch (this) {
    _MetaField.federationName => 'federation_name',
    _MetaField.profilePicture => 'fedi:federation_icon_url',
    _MetaField.welcomeMessage => 'welcome_message',
    _MetaField.expiryDate => 'federation_expiry_timestamp',
  };

  String label(BuildContext context) => switch (this) {
    _MetaField.federationName => context.l10n.guardianMetaFederationName,
    _MetaField.profilePicture => context.l10n.guardianMetaProfilePicture,
    _MetaField.welcomeMessage => context.l10n.guardianMetaWelcomeMessage,
    _MetaField.expiryDate => context.l10n.guardianMetaExpiryDate,
  };

  IconData get icon => switch (this) {
    _MetaField.federationName => Icons.badge_outlined,
    _MetaField.profilePicture => Icons.image_outlined,
    _MetaField.welcomeMessage => Icons.waving_hand_outlined,
    _MetaField.expiryDate => Icons.event_busy_outlined,
  };
}

/// The expiry is stored as Unix seconds, as a JSON string — the same encoding
/// the guardian web UI writes. Returns null when unset or unparseable.
DateTime? _parseExpiry(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final seconds = int.tryParse(raw.trim());
  if (seconds == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
}

/// Renders a stored meta value for display. Only the expiry needs translating
/// out of its raw form; everything else is already human-readable.
String _displayValue(BuildContext context, _MetaField field, String? raw) {
  if (raw == null || raw.isEmpty) {
    return field == _MetaField.expiryDate
        ? context.l10n.guardianMetaNeverExpires
        : context.l10n.guardianMetaNotSet;
  }
  if (field != _MetaField.expiryDate) return raw;

  final date = _parseExpiry(raw);
  return date == null ? raw : DateFormat.yMMMd().add_jm().format(date);
}

/// A single human-readable difference between two meta documents.
class _MetaChange {
  final String label;
  final String? from;
  final String? to;

  const _MetaChange({required this.label, this.from, this.to});
}

/// View and propose federation settings stored in the meta module.
///
/// The meta module holds one JSON document that changes by consensus: a
/// proposal only takes effect once a threshold of guardians submit the exact
/// same document. There is no "reject" — declining simply means not voting.
class GuardianMetaScreen extends StatefulWidget {
  final FederationSelector fed;
  final PeerStatus peer;
  final String password;

  const GuardianMetaScreen({
    super.key,
    required this.fed,
    required this.peer,
    required this.password,
  });

  @override
  State<GuardianMetaScreen> createState() => _GuardianMetaScreenState();
}

class _GuardianMetaScreenState extends State<GuardianMetaScreen> {
  GuardianMetaState? _state;
  Object? _error;
  bool _busy = false;

  /// Guardian names by peer id, so proposals can name who backs them rather
  /// than showing bare peer numbers.
  Map<int, String> _guardianNames = {};

  /// Proposals the operator chose to hide. The protocol has no "reject", so
  /// dismissing is deliberately local and forgotten on reload.
  final Set<String> _dismissed = {};

  @override
  void initState() {
    super.initState();
    _loadGuardianNames();
    _load();
  }

  Future<void> _loadGuardianNames() async {
    try {
      final meta = await getFederationMeta(
        federationId: widget.fed.federationId,
      );
      if (!mounted) return;
      setState(() {
        _guardianNames = {for (final g in meta.guardians) g.peerId: g.name};
      });
    } catch (e) {
      // Falls back to "Guardian N" labels; not worth failing the screen over.
      AppLogger.instance.warn("Could not load guardian names: $e");
    }
  }

  String _guardianLabel(int peerId) =>
      _guardianNames[peerId] ??
      context.l10n.guardianMetaPeerFallback(peerId.toString());

  Future<void> _load() async {
    setState(() {
      _error = null;
    });
    try {
      final state = await guardianMetaState(
        federationId: widget.fed.federationId,
        peer: widget.peer.peerId,
        password: widget.password,
      );
      if (!mounted) return;
      setState(() {
        _state = state;
      });
    } catch (e) {
      AppLogger.instance.error("Could not load meta state: $e");
      if (!mounted) return;
      setState(() {
        _error = e;
      });
    }
  }

  Map<String, dynamic> _decode(String? json) {
    if (json == null) return {};
    try {
      final decoded = jsonDecode(json);
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      return {};
    }
  }

  Map<String, dynamic> get _consensus => _decode(_state?.consensusJson);

  void _showToast(String message, IconData icon) {
    ToastService().show(
      message: message,
      duration: const Duration(seconds: 5),
      onTap: () {},
      icon: Icon(icon),
    );
  }

  /// Identity of the currently displayed state, used to detect when a
  /// submission has landed.
  String _signature(GuardianMetaState state) =>
      '${state.revision}|'
      '${state.proposals.map((p) => '${p.valueHex}:${p.peerIds.join(',')}').join('|')}';

  /// Reload until the state changes, or we give up waiting.
  ///
  /// Submitting only records a *desired* value on the guardian; it becomes a
  /// visible submission one consensus round later. Reloading immediately would
  /// race that round and show stale data, so poll until it lands.
  Future<void> _loadUntilChanged(String before, BigInt? beforeRevision) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      try {
        final state = await guardianMetaState(
          federationId: widget.fed.federationId,
          peer: widget.peer.peerId,
          password: widget.password,
        );
        if (!mounted) return;
        setState(() {
          _state = state;
        });
        if (_signature(state) == before) continue;

        // A new revision means the threshold was reached and these settings
        // are now live. Refresh the app's meta cache rather than letting the
        // rest of the app show stale values until its periodic refresh.
        if (state.revision != beforeRevision) {
          await _refreshAppMeta();
        }
        return;
      } catch (e) {
        AppLogger.instance.warn("Meta reload failed while polling: $e");
      }
    }
  }

  Future<void> _refreshAppMeta() async {
    try {
      await refreshFederationMeta(federationId: widget.fed.federationId);
    } catch (e) {
      AppLogger.instance.warn("Could not refresh cached federation meta: $e");
    }
  }

  /// Runs a submission and refreshes, reporting the outcome as a toast.
  Future<void> _submit(
    Future<void> Function() action,
    String successMessage,
  ) async {
    if (_busy) return;
    final before = _state == null ? '' : _signature(_state!);
    final beforeRevision = _state?.revision;
    setState(() {
      _busy = true;
    });
    try {
      await action();
      if (!mounted) return;
      _showToast(successMessage, Icons.check);
      await _loadUntilChanged(before, beforeRevision);
    } catch (e) {
      AppLogger.instance.error("Meta submission failed: $e");
      if (!mounted) return;
      _showToast(context.l10n.guardianMetaCouldNotSubmit, Icons.error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  // --- Diffing ---

  /// Human-readable differences between the current consensus and a proposal.
  /// Recognised fields get friendly labels; anything else is counted so an
  /// unfamiliar key never hides a change.
  (List<_MetaChange>, int) _changes(Map<String, dynamic> proposal) {
    final consensus = _consensus;
    final changes = <_MetaChange>[];
    final recognised = {for (final f in _MetaField.values) f.key: f};

    final keys = {...consensus.keys, ...proposal.keys};
    var otherCount = 0;

    for (final key in keys) {
      final before = consensus[key];
      final after = proposal[key];
      if (before == after) continue;

      final field = recognised[key];
      if (field == null) {
        otherCount++;
        continue;
      }
      changes.add(
        _MetaChange(
          label: field.label(context),
          from:
              before == null
                  ? null
                  : _displayValue(context, field, before.toString()),
          to:
              after == null
                  ? null
                  : _displayValue(context, field, after.toString()),
        ),
      );
    }

    return (changes, otherCount);
  }

  // --- Edit flows ---

  /// A bordered, tappable row showing a chosen value. Used for the expiry
  /// date and time, which open native pickers instead of a keyboard.
  Widget _pickerTile({
    required ThemeData theme,
    required IconData icon,
    required String text,
    required bool isPlaceholder,
    required VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.grey.withValues(alpha: enabled ? 0.4 : 0.2),
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: enabled ? theme.colorScheme.primary : Colors.grey,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: isPlaceholder || !enabled ? Colors.grey : null,
                ),
              ),
            ),
            Icon(
              Icons.edit_outlined,
              size: 18,
              color: enabled ? Colors.grey : Colors.grey.withValues(alpha: 0.4),
            ),
          ],
        ),
      ),
    );
  }

  /// Expiry uses a date picker rather than a text field. The chosen day is
  /// stored as its final second in local time, so a federation set to expire
  /// "on the 5th" stays usable through all of the 5th.
  Future<void> _onEditExpiry(String current) async {
    final existing = _parseExpiry(current);
    DateTime? selected = existing;

    final result = await showModalBottomSheet<({String? value})>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: StatefulBuilder(
            builder: (sbContext, setSheetState) {
              final theme = Theme.of(sbContext);
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sbContext.l10n.guardianMetaExpiryDate,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    sbContext.l10n.guardianMetaExpiryHelp,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _pickerTile(
                    theme: theme,
                    icon: Icons.calendar_today_outlined,
                    // Default to the end of the chosen day, so an expiry set
                    // "on the 5th" leaves the federation usable through it.
                    text:
                        selected == null
                            ? sbContext.l10n.guardianMetaChooseDate
                            : DateFormat.yMMMd().format(selected!),
                    isPlaceholder: selected == null,
                    onTap: () async {
                      final now = DateTime.now();
                      final picked = await showDatePicker(
                        context: sbContext,
                        initialDate:
                            selected != null && selected!.isAfter(now)
                                ? selected!
                                : now.add(const Duration(days: 365)),
                        firstDate: now,
                        lastDate: DateTime(now.year + 20),
                      );
                      if (picked == null) return;
                      setSheetState(() {
                        selected = DateTime(
                          picked.year,
                          picked.month,
                          picked.day,
                          selected?.hour ?? 23,
                          selected?.minute ?? 59,
                          selected == null ? 59 : 0,
                        );
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  _pickerTile(
                    theme: theme,
                    icon: Icons.schedule_outlined,
                    text:
                        selected == null
                            ? sbContext.l10n.guardianMetaChooseTime
                            : DateFormat.jm().format(selected!),
                    isPlaceholder: selected == null,
                    // A time alone is meaningless, so require the date first.
                    onTap:
                        selected == null
                            ? null
                            : () async {
                              final picked = await showTimePicker(
                                context: sbContext,
                                initialTime: TimeOfDay.fromDateTime(selected!),
                              );
                              if (picked == null) return;
                              setSheetState(() {
                                selected = DateTime(
                                  selected!.year,
                                  selected!.month,
                                  selected!.day,
                                  picked.hour,
                                  picked.minute,
                                );
                              });
                            },
                  ),
                  const SizedBox(height: 12),
                  Text(
                    sbContext.l10n.guardianMetaThresholdHint(
                      _state!.threshold.toString(),
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      if (existing != null)
                        TextButton(
                          onPressed:
                              () =>
                                  Navigator.of(sheetContext).pop((value: null)),
                          child: Text(sbContext.l10n.guardianMetaClear),
                        ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        child: Text(sbContext.l10n.cancel),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed:
                            selected == null
                                ? null
                                : () => Navigator.of(sheetContext).pop((
                                  value:
                                      (selected!.millisecondsSinceEpoch ~/ 1000)
                                          .toString(),
                                )),
                        child: Text(sbContext.l10n.guardianMetaPropose),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        );
      },
    );

    if (result == null || !mounted) return;
    if (result.value == (current.isEmpty ? null : current)) return;

    await _submit(
      () => guardianMetaProposeField(
        federationId: widget.fed.federationId,
        peer: widget.peer.peerId,
        password: widget.password,
        field: _MetaField.expiryDate.key,
        value: result.value,
      ),
      context.l10n.guardianMetaProposed,
    );
  }

  Future<void> _onEditField(_MetaField field) async {
    final current = _consensus[field.key]?.toString() ?? '';
    if (field == _MetaField.expiryDate) {
      return _onEditExpiry(current);
    }
    final controller = TextEditingController(text: current);
    final isPicture = field == _MetaField.profilePicture;
    final isMultiline = field == _MetaField.welcomeMessage;

    final result = await showModalBottomSheet<({String? value})>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 20,
          ),
          child: StatefulBuilder(
            builder: (sbContext, setSheetState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    field.label(sbContext),
                    style: Theme.of(sbContext).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    sbContext.l10n.guardianMetaThresholdHint(
                      _state!.threshold.toString(),
                    ),
                    style: Theme.of(
                      sbContext,
                    ).textTheme.bodySmall?.copyWith(color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    minLines: isMultiline ? 3 : 1,
                    maxLines: isMultiline ? 6 : 1,
                    keyboardType:
                        isPicture ? TextInputType.url : TextInputType.text,
                    decoration: InputDecoration(
                      labelText:
                          isPicture
                              ? sbContext.l10n.guardianMetaImageUrlLabel
                              : field.label(sbContext),
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: isPicture ? (_) => setSheetState(() {}) : null,
                  ),
                  if (isPicture && controller.text.trim().isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.network(
                          controller.text.trim(),
                          width: 96,
                          height: 96,
                          fit: BoxFit.cover,
                          errorBuilder:
                              (_, __, ___) => Text(
                                sbContext.l10n.guardianMetaImagePreviewFailed,
                                style: const TextStyle(color: Colors.orange),
                              ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      if (current.isNotEmpty)
                        TextButton(
                          onPressed:
                              () =>
                                  Navigator.of(sheetContext).pop((value: null)),
                          child: Text(sbContext.l10n.guardianMetaClear),
                        ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        child: Text(sbContext.l10n.cancel),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () {
                          final text = controller.text.trim();
                          Navigator.of(
                            sheetContext,
                          ).pop((value: text.isEmpty ? null : text));
                        },
                        child: Text(sbContext.l10n.guardianMetaPropose),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        );
      },
    );

    if (result == null || !mounted) return;
    if (result.value == (current.isEmpty ? null : current)) return;

    await _submit(
      () => guardianMetaProposeField(
        federationId: widget.fed.federationId,
        peer: widget.peer.peerId,
        password: widget.password,
        field: field.key,
        value: result.value,
      ),
      context.l10n.guardianMetaProposed,
    );
  }

  // --- Build ---

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(context.l10n.guardianMetaTitle),
      ),
      body: SafeArea(child: _buildBody(theme)),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
              const SizedBox(height: 16),
              Text(
                context.l10n.guardianMetaCouldNotLoad,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: Text(context.l10n.retry),
              ),
            ],
          ),
        ),
      );
    }

    final state = _state;
    if (state == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final visibleProposals =
        state.proposals.where((p) => !_dismissed.contains(p.valueHex)).toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          _sectionHeader(theme, context.l10n.guardianMetaCurrentSettings),
          const SizedBox(height: 8),
          _buildSettingsCard(theme),
          const SizedBox(height: 24),
          _sectionHeader(theme, context.l10n.guardianMetaPendingProposals),
          const SizedBox(height: 8),
          if (visibleProposals.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  context.l10n.guardianMetaNoProposals,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.grey,
                  ),
                ),
              ),
            )
          else
            for (final proposal in visibleProposals) ...[
              _buildProposalCard(theme, state, proposal),
              const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }

  Widget _sectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: Colors.grey,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildSettingsCard(ThemeData theme) {
    final consensus = _consensus;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final field in _MetaField.values) ...[
            _buildSettingRow(theme, field, consensus[field.key]?.toString()),
            if (field != _MetaField.values.last)
              Divider(height: 1, color: Colors.grey.withValues(alpha: 0.15)),
          ],
        ],
      ),
    );
  }

  Widget _buildSettingRow(ThemeData theme, _MetaField field, String? value) {
    final isPicture = field == _MetaField.profilePicture;
    final hasValue = value != null && value.isNotEmpty;

    return InkWell(
      onTap: _busy ? null : () => _onEditField(field),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(field.icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    field.label(context),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _displayValue(context, field, value),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: hasValue ? null : Colors.grey,
                      fontStyle: hasValue ? null : FontStyle.italic,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (isPicture && hasValue) ...[
              const SizedBox(width: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  value,
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                  errorBuilder:
                      (_, __, ___) => const Icon(
                        Icons.broken_image_outlined,
                        size: 20,
                        color: Colors.grey,
                      ),
                ),
              ),
            ],
            const SizedBox(width: 8),
            const Icon(Icons.edit_outlined, size: 18, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _buildProposalCard(
    ThemeData theme,
    GuardianMetaState state,
    GuardianMetaProposal proposal,
  ) {
    final proposed = _decode(proposal.valueJson);
    final (changes, otherCount) = _changes(proposed);
    final votes = proposal.peerIds.length;
    final threshold = state.threshold;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border:
            proposal.isOurs
                ? Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.4),
                )
                : null,
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (proposal.isOurs) ...[
                Icon(
                  Icons.person_outline,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  context.l10n.guardianMetaYourProposal,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
              ],
              Text(
                context.l10n.guardianMetaVotes(
                  votes.toString(),
                  threshold.toString(),
                ),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: votes >= threshold ? Colors.green : Colors.grey,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: threshold == 0 ? 0 : (votes / threshold).clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: Colors.grey.withValues(alpha: 0.2),
              valueColor: AlwaysStoppedAnimation<Color>(
                votes >= threshold ? Colors.green : theme.colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.how_to_vote_outlined,
                size: 14,
                color: Colors.grey,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  context.l10n.guardianMetaBackedBy(
                    proposal.peerIds.map(_guardianLabel).join(', '),
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (changes.isEmpty && otherCount == 0)
            Text(
              context.l10n.guardianMetaNoChanges,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
            )
          else ...[
            for (final change in changes) _buildChangeRow(theme, change),
            if (otherCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  context.l10n.guardianMetaOtherChanges(otherCount.toString()),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // Close only hides the card. Withdraw is the only action here
              // that submits anything: cancelling a vote means submitting the
              // current consensus value, so it is kept explicit and separate.
              TextButton(
                onPressed:
                    _busy
                        ? null
                        : () => setState(() {
                          _dismissed.add(proposal.valueHex);
                        }),
                child: Text(context.l10n.close),
              ),
              const SizedBox(width: 8),
              if (proposal.isOurs)
                TextButton(
                  onPressed:
                      _busy
                          ? null
                          : () => _submit(
                            () => guardianMetaWithdraw(
                              federationId: widget.fed.federationId,
                              peer: widget.peer.peerId,
                              password: widget.password,
                            ),
                            context.l10n.guardianMetaWithdrawn,
                          ),
                  child: Text(
                    context.l10n.guardianMetaWithdraw,
                    style: const TextStyle(color: Colors.orange),
                  ),
                )
              else ...[
                FilledButton(
                  onPressed:
                      _busy
                          ? null
                          : () => _submit(
                            () => guardianMetaAccept(
                              federationId: widget.fed.federationId,
                              peer: widget.peer.peerId,
                              password: widget.password,
                              valueHex: proposal.valueHex,
                            ),
                            context.l10n.guardianMetaAccepted,
                          ),
                  child: Text(context.l10n.guardianMetaAccept),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChangeRow(ThemeData theme, _MetaChange change) {
    final removed = change.to == null || change.to!.isEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            change.label,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
          ),
          const SizedBox(height: 2),
          if (removed)
            Text(
              context.l10n.guardianMetaRemoves(change.label),
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.orange),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (change.from != null && change.from!.isNotEmpty) ...[
                  Flexible(
                    child: Text(
                      change.from!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.grey,
                        decoration: TextDecoration.lineThrough,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Icon(
                      Icons.arrow_forward,
                      size: 12,
                      color: Colors.grey,
                    ),
                  ),
                ],
                Flexible(
                  child: Text(
                    change.to!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
