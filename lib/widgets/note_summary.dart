import 'package:flutter/material.dart';
import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/utils.dart';
import 'package:provider/provider.dart';

class NoteSummary extends StatefulWidget {
  final FederationSelector fed;

  const NoteSummary({super.key, required this.fed});

  @override
  State<NoteSummary> createState() => _NoteSummaryState();
}

class _NoteSummaryState extends State<NoteSummary> {
  late Future<List<(BigInt, BigInt)>> _summaryFuture;

  @override
  void initState() {
    super.initState();
    _summaryFuture = getNoteSummary(federationId: widget.fed.federationId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );

    return FutureBuilder<List<(BigInt, BigInt)>>(
      future: _summaryFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          AppLogger.instance.error(
            "Error loading note summary: ${snapshot.error}",
          );
          return Center(
            child: Text(
              context.l10n.couldNotLoadNoteSummary,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.redAccent,
              ),
            ),
          );
        }

        final summary = snapshot.data!;
        if (summary.isEmpty) {
          return Center(child: Text(context.l10n.noNotesAvailable));
        }

        return ListView.separated(
          itemCount: summary.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          padding: const EdgeInsets.only(top: 8),
          itemBuilder: (context, index) {
            final (denom, count) = summary[index];
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.15),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.receipt_long,
                    color: theme.colorScheme.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      formatBalance(denom, true, bitcoinDisplay),
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      'x${count.toString()}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
