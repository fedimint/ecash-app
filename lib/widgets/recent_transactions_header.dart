import 'package:flutter/material.dart';

class RecentTransactionsHeader extends StatelessWidget {
  const RecentTransactionsHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        "Recent Transactions",
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}

