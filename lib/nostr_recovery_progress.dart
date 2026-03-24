import 'dart:async';

import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/multimint.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

/// Tracks the status of an individual Nostr relay during recovery.
class _RelayEntry {
  final String url;
  RelayStatusKind status;

  _RelayEntry({required this.url, required this.status});
}

/// A rich recovery progress screen that replaces the bland spinner.
/// Shows relay connection statuses, recovery phase, and federation progress.
class NostrRecoveryProgress extends StatefulWidget {
  final Stream<MultimintEvent> events;
  final String? rejoinHost;
  final String? rejoinPeer;
  final int recoverySecondsRemaining;

  const NostrRecoveryProgress({
    super.key,
    required this.events,
    this.rejoinHost,
    this.rejoinPeer,
    this.recoverySecondsRemaining = 30,
  });

  @override
  State<NostrRecoveryProgress> createState() => _NostrRecoveryProgressState();
}

class _NostrRecoveryProgressState extends State<NostrRecoveryProgress> {
  final List<_RelayEntry> _relays = [];
  NostrRecoveryPhase? _phase;
  late final StreamSubscription<MultimintEvent> _subscription;
  Timer? _fetchTimer;
  int _fetchElapsedSeconds = 0;

  @override
  void initState() {
    super.initState();
    _subscription = widget.events.listen(_onEvent);
  }

  void _onEvent(MultimintEvent event) {
    if (!mounted) return;
    if (event is MultimintEvent_NostrRelayStatus) {
      setState(() {
        final url = event.field0;
        final status = event.field1;
        final idx = _relays.indexWhere((r) => r.url == url);
        if (idx >= 0) {
          _relays[idx].status = status;
        } else {
          _relays.add(_RelayEntry(url: url, status: status));
        }
      });
    } else if (event is MultimintEvent_NostrRecoveryPhase) {
      setState(() {
        _phase = event.field0;
      });
      if (event.field0 is NostrRecoveryPhase_FetchingBackup) {
        _startFetchTimer();
      } else {
        _stopFetchTimer();
      }
    }
  }

  void _startFetchTimer() {
    _fetchTimer?.cancel();
    _fetchElapsedSeconds = 0;
    _fetchTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _fetchElapsedSeconds++);
    });
  }

  void _stopFetchTimer() {
    _fetchTimer?.cancel();
    _fetchTimer = null;
  }

  @override
  void dispose() {
    _subscription.cancel();
    _fetchTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Phase header
            _PhaseHeader(phase: _phase, theme: theme, l10n: l10n),
            const SizedBox(height: 32),
            // Relay list
            if (_relays.isNotEmpty) ...[
              _RelayStatusList(relays: _relays, theme: theme),
              const SizedBox(height: 24),
            ],
            // Fetching activity indicator
            if (_phase is NostrRecoveryPhase_FetchingBackup) ...[
              _FetchingIndicator(
                elapsedSeconds: _fetchElapsedSeconds,
                theme: theme,
                l10n: l10n,
              ),
              const SizedBox(height: 24),
            ],
            // Rejoin status
            if (widget.rejoinHost != null) ...[
              _RejoinStatus(
                host: widget.rejoinHost!,
                peer: widget.rejoinPeer ?? '',
                secondsRemaining: widget.recoverySecondsRemaining,
                theme: theme,
                l10n: l10n,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Animated header showing the current recovery phase with a stepper.
class _PhaseHeader extends StatelessWidget {
  final NostrRecoveryPhase? phase;
  final ThemeData theme;
  final dynamic l10n;

  const _PhaseHeader({
    required this.phase,
    required this.theme,
    required this.l10n,
  });

  int get _phaseIndex {
    return switch (phase) {
      NostrRecoveryPhase_ConnectingToRelays() => 0,
      NostrRecoveryPhase_FetchingBackup() => 1,
      NostrRecoveryPhase_DecryptingInvites() => 2,
      NostrRecoveryPhase_RejoiningFederations() => 3,
      null => -1,
    };
  }

  @override
  Widget build(BuildContext context) {
    final steps = [
      l10n.recoveryPhaseConnecting,
      l10n.recoveryPhaseFetching,
      l10n.recoveryPhaseDecrypting,
      _rejoiningLabel,
    ];

    return Column(
      children: [
        // Pulsing icon
        Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.primary.withOpacity(0.1),
              ),
              child: Icon(
                Icons.satellite_alt_rounded,
                size: 32,
                color: theme.colorScheme.primary,
              ),
            )
            .animate(onPlay: (controller) => controller.repeat(reverse: true))
            .scale(
              begin: const Offset(1.0, 1.0),
              end: const Offset(1.08, 1.08),
              duration: 1500.ms,
              curve: Curves.easeInOut,
            ),
        const SizedBox(height: 16),
        Text(
          l10n.retrievingFederationBackup,
          style: theme.textTheme.titleLarge?.copyWith(fontSize: 18),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        // Step indicators
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(steps.length, (i) {
            final isActive = i == _phaseIndex;
            final isDone = i < _phaseIndex;
            return Expanded(
              child: _StepDot(
                label: steps[i],
                isActive: isActive,
                isDone: isDone,
                theme: theme,
              ),
            );
          }),
        ),
      ],
    );
  }

  String get _rejoiningLabel {
    if (phase is NostrRecoveryPhase_RejoiningFederations) {
      final count = (phase as NostrRecoveryPhase_RejoiningFederations).field0;
      return l10n.recoveryPhaseRejoining(count);
    }
    return l10n.recoveryPhaseRejoining(0);
  }
}

class _StepDot extends StatelessWidget {
  final String label;
  final bool isActive;
  final bool isDone;
  final ThemeData theme;

  const _StepDot({
    required this.label,
    required this.isActive,
    required this.isDone,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        isDone
            ? Colors.green
            : isActive
            ? theme.colorScheme.primary
            : Colors.white24;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: isActive ? 12 : 8,
          height: isActive ? 12 : 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color:
                isDone ? Colors.green : (isActive ? color : Colors.transparent),
            border: Border.all(color: color, width: 2),
          ),
          child:
              isDone
                  ? const Icon(Icons.check, size: 8, color: Colors.white)
                  : null,
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: isActive ? Colors.white70 : Colors.white30,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
          ),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// Animated list of relay statuses.
class _RelayStatusList extends StatelessWidget {
  final List<_RelayEntry> relays;
  final ThemeData theme;

  const _RelayStatusList({required this.relays, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < relays.length; i++)
            _RelayRow(relay: relays[i], theme: theme)
                .animate()
                .fadeIn(duration: 300.ms, delay: Duration(milliseconds: i * 80))
                .slideX(
                  begin: -0.1,
                  end: 0,
                  duration: 300.ms,
                  delay: Duration(milliseconds: i * 80),
                  curve: Curves.easeOut,
                ),
        ],
      ),
    );
  }
}

/// Shows a scanning animation and elapsed timer during the backup fetch.
class _FetchingIndicator extends StatelessWidget {
  final int elapsedSeconds;
  final ThemeData theme;
  final dynamic l10n;

  const _FetchingIndicator({
    required this.elapsedSeconds,
    required this.theme,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.primary.withOpacity(0.15)),
      ),
      child: Column(
        children: [
          // Scanning bar animation
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 4,
              child: Stack(
                children: [
                  Container(color: theme.colorScheme.primary.withOpacity(0.1)),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      return Container(
                            width: constraints.maxWidth * 0.3,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              gradient: LinearGradient(
                                colors: [
                                  theme.colorScheme.primary.withOpacity(0.0),
                                  theme.colorScheme.primary.withOpacity(0.8),
                                  theme.colorScheme.primary.withOpacity(0.0),
                                ],
                              ),
                            ),
                          )
                          .animate(onPlay: (c) => c.repeat())
                          .slideX(
                            begin: -1.5,
                            end: 3.5,
                            duration: 2000.ms,
                            curve: Curves.easeInOut,
                          );
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.search_rounded,
                size: 16,
                color: theme.colorScheme.primary.withOpacity(0.7),
              ),
              const SizedBox(width: 8),
              Text(
                l10n.searchingForBackup(elapsedSeconds),
                style: TextStyle(fontSize: 13, color: Colors.white60),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RelayRow extends StatelessWidget {
  final _RelayEntry relay;
  final ThemeData theme;

  const _RelayRow({required this.relay, required this.theme});

  /// Strip the wss:// prefix for a cleaner display.
  String get _displayUrl {
    var url = relay.url;
    if (url.startsWith('wss://')) {
      url = url.substring(6);
    } else if (url.startsWith('ws://')) {
      url = url.substring(5);
    }
    return url;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          _StatusIndicator(status: relay.status, theme: theme),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _displayUrl,
              style: TextStyle(
                fontSize: 13,
                color: Colors.white60,
                fontFamily: 'monospace',
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _StatusLabel(status: relay.status),
        ],
      ),
    );
  }
}

class _StatusIndicator extends StatelessWidget {
  final RelayStatusKind status;
  final ThemeData theme;

  const _StatusIndicator({required this.status, required this.theme});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      RelayStatusKind.connecting => Colors.amber,
      RelayStatusKind.connected => Colors.green,
      RelayStatusKind.failed => Colors.red,
    };

    Widget dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.5),
            blurRadius: 6,
            spreadRadius: 1,
          ),
        ],
      ),
    );

    if (status == RelayStatusKind.connecting) {
      dot = dot
          .animate(onPlay: (c) => c.repeat(reverse: true))
          .fade(begin: 0.4, end: 1.0, duration: 800.ms);
    }

    return SizedBox(width: 12, height: 12, child: Center(child: dot));
  }
}

class _StatusLabel extends StatelessWidget {
  final RelayStatusKind status;

  const _StatusLabel({required this.status});

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (status) {
      RelayStatusKind.connecting => (
        context.l10n.relayStatusConnecting,
        Colors.amber,
      ),
      RelayStatusKind.connected => (
        context.l10n.relayStatusConnected,
        Colors.green,
      ),
      RelayStatusKind.failed => (context.l10n.relayStatusFailed, Colors.red),
    };

    return Text(
      text,
      style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500),
    );
  }
}

/// Shows the current rejoin attempt and timeout warning.
class _RejoinStatus extends StatelessWidget {
  final String host;
  final String peer;
  final int secondsRemaining;
  final ThemeData theme;
  final dynamic l10n;

  const _RejoinStatus({
    required this.host,
    required this.peer,
    required this.secondsRemaining,
    required this.theme,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.primary.withOpacity(0.2)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l10n.tryingToRejoin(host, peer),
                  style: const TextStyle(fontSize: 14, color: Colors.white70),
                ),
              ),
            ],
          ),
          if (secondsRemaining <= 15) ...[
            const SizedBox(height: 12),
            Text(
              l10n.peerMightBeOffline(secondsRemaining),
              style: const TextStyle(
                fontSize: 14,
                color: Colors.red,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}
