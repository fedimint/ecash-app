import 'package:flutter/material.dart';
import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/utils.dart'; // for formatBalance
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

        return SingleChildScrollView(
          scrollDirection: Axis.vertical,
          child: DataTable(
            headingRowColor: WidgetStatePropertyAll(theme.colorScheme.surface),
            dataRowColor: WidgetStatePropertyAll(const Color(0xFF1A1A1A)),
            headingTextStyle: theme.textTheme.titleLarge,
            dataTextStyle: theme.textTheme.bodyLarge,
            columns: [
              DataColumn(label: Text(context.l10n.denomination)),
              DataColumn(label: Text(context.l10n.countLabel)),
            ],
            rows:
                summary.map((entry) {
                  final (denom, count) = entry;
                  return DataRow(
                    cells: [
                      DataCell(
                        Text(formatBalance(denom, true, bitcoinDisplay)),
                      ),
                      DataCell(Text(count.toString())),
                    ],
                  );
                }).toList(),
          ),
        );
      },
    );
  }
}
