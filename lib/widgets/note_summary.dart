import 'package:flutter/material.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/utils.dart'; // for formatBalance

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

    return FutureBuilder<List<(BigInt, BigInt)>>(
      future: _summaryFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          AppLogger.instance.error("Error loading note summary: ${snapshot.error}");
          return Center(
            child: Text(
              'Could not load note summary',
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.redAccent),
            ),
          );
        }

        final summary = snapshot.data!;
        if (summary.isEmpty) {
          return const Center(child: Text("No notes available"));
        }

        return SingleChildScrollView(
          scrollDirection: Axis.vertical,
          child: DataTable(
            headingRowColor: WidgetStatePropertyAll(theme.colorScheme.surface),
            dataRowColor: WidgetStatePropertyAll(const Color(0xFF1A1A1A)),
            headingTextStyle: theme.textTheme.titleLarge,
            dataTextStyle: theme.textTheme.bodyLarge,
            columns: const [
              DataColumn(label: Text('Denomination')),
              DataColumn(label: Text('Count')),
            ],
            rows: summary.map((entry) {
              final (denom, count) = entry;
              return DataRow(
                cells: [
                  DataCell(Text(formatBalance(denom, true))),
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

