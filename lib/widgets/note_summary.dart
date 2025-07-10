import 'package:carbine/lib.dart';
import 'package:carbine/multimint.dart';
import 'package:flutter/material.dart';
// Assumes get_note_summary is defined here

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
          return Center(child: Text('Error loading note summary: ${snapshot.error}'));
        }

        final summary = snapshot.data!;
        if (summary.isEmpty) {
          return const Center(child: Text("No notes available"));
        }

        return SingleChildScrollView(
          child: DataTable(
            headingRowColor: WidgetStatePropertyAll(theme.colorScheme.surfaceContainerHighest),
            columns: const [
              DataColumn(label: Text('Denomination')),
              DataColumn(label: Text('Count')),
            ],
            rows: summary.map((entry) {
              final (denom, count) = entry;
              return DataRow(
                cells: [
                  DataCell(Text('${denom.toString()} sats')),
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
