import 'package:carbine/lib.dart';
import 'package:carbine/receive.dart';
import 'package:carbine/scan.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class Dashboard extends StatefulWidget {
  final FederationSelector fed;

  const Dashboard({super.key, required this.fed});

  @override
  State<Dashboard> createState() => _DashboardState();
}

enum PaymentType { lightning, onchain, ecash }

class _DashboardState extends State<Dashboard> {
  BigInt? balanceMsats;
  bool isLoadingBalance = true;
  bool isLoadingTransactions = true;
  List<Transaction> _transactions = [];

  PaymentType _selectedPaymentType = PaymentType.lightning;

  @override
  void initState() {
    super.initState();
    _loadBalance();
    _loadTransactions();
  }

  Future<void> _loadBalance() async {
    final bal = await balance(federationId: widget.fed.federationId);
    setState(() {
      balanceMsats = bal;
      isLoadingBalance = false;
    });
  }

  Future<void> _loadTransactions() async {
    final txs = await transactions(federationId: widget.fed.federationId, modules: ["ln", "lnv2"]);
    setState(() {
      _transactions = txs;
      isLoadingTransactions = false;
    });
  }

  void _onSendPressed() async {
    await Navigator.push(context, MaterialPageRoute(builder: (context) => ScanQRPage(selectedFed: widget.fed)));
    _loadBalance();
    _loadTransactions();
  }

  void _onReceivePressed() async {
    await Navigator.push(context, MaterialPageRoute(builder: (context) => Receive(fed: widget.fed)));
    _loadBalance();
    _loadTransactions();
  }

  String formatSats(BigInt? msats) {
    if (msats == null) return '0.00 sats';
    final sats = msats.toDouble() / 1000;

    final formatter = NumberFormat('#,##0.00', 'en_US');
    var formatted = formatter.format(sats);
    formatted = formatted.replaceAll(',', ' ');

    return '$formatted sats';
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.fed.federationName;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 32),
          ShaderMask(
            shaderCallback: (bounds) => LinearGradient(
              colors: [Theme.of(context).colorScheme.primary, Theme.of(context).colorScheme.secondary],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ).createShader(Rect.fromLTWH(0, 0, bounds.width, bounds.height)),
            child: Text(
              name.toUpperCase(),
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                    color: Colors.white, // Important: ShaderMask overrides this.
                    shadows: [
                      Shadow(
                        blurRadius: 10,
                        color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 48),

          if (isLoadingBalance)
            const CircularProgressIndicator()
          else
            Text(
              formatSats(balanceMsats),
              style: Theme.of(context).textTheme.displayLarge?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),

          const SizedBox(height: 48),

          SegmentedButton<PaymentType>(
            segments: const [
              ButtonSegment(
                value: PaymentType.lightning,
                label: Text('Lightning'),
                icon: Icon(Icons.flash_on),
              ),
              ButtonSegment(
                value: PaymentType.onchain,
                label: Text('Onchain'),
                icon: Icon(Icons.link),
              ),
              ButtonSegment(
                value: PaymentType.ecash,
                label: Text('Ecash'),
                icon: Icon(Icons.currency_bitcoin),
              ),
            ],
            selected: {_selectedPaymentType},
            onSelectionChanged: (newSelection) {
              setState(() {
                _selectedPaymentType = newSelection.first;
              });
            },
            style: ButtonStyle(
              padding: WidgetStateProperty.all(const EdgeInsets.symmetric(vertical: 20, horizontal: 24)),
              shape: WidgetStateProperty.all(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(40),
                ),
              ),
              textStyle: WidgetStateProperty.all(
                const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return Theme.of(context).colorScheme.primary;
                }
                return Theme.of(context).colorScheme.surfaceContainerHighest;
              }),
              foregroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return Colors.white;
                }
                return Colors.black87;
              }),
              side: WidgetStateProperty.all(
                const BorderSide(color: Colors.transparent),
              ),
              shadowColor: WidgetStateProperty.all(Colors.black.withOpacity(0.2)),
              elevation: WidgetStateProperty.resolveWith<double>((states) {
                if (states.contains(WidgetState.selected)) {
                  return 6;
                }
                return 0;
              }),
            ),
          ),

          const SizedBox(height: 48),

          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth > 400;
              return isWide
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _onReceivePressed,
                            icon: const Icon(Icons.download),
                            label: const Text("Receive"),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _onSendPressed,
                            icon: const Icon(Icons.upload),
                            label: const Text("Send"),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        ElevatedButton.icon(
                          onPressed: _onReceivePressed,
                          icon: const Icon(Icons.download),
                          label: const Text("Receive"),
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: _onSendPressed,
                          icon: const Icon(Icons.upload),
                          label: const Text("Send"),
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                          ),
                        ),
                      ],
                    );
            },
          ),

          const SizedBox(height: 48),

          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              "Recent Transactions",
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
          const SizedBox(height: 16),

          isLoadingTransactions
              ? const CircularProgressIndicator()
              : _transactions.isEmpty
                  ? const Text("No transactions yet.")
                  : SizedBox(
                      height: 300,
                      child: ListView.builder(
                        itemCount: _transactions.length,
                        itemBuilder: (context, index) {
                          final tx = _transactions[index];
                          final isIncoming = tx.received;
                          final date = DateTime.fromMillisecondsSinceEpoch(tx.timestamp.toInt());
                          final formattedDate = DateFormat.yMMMd().add_jm().format(date);
                          final formattedAmount = formatSats(tx.amount);

                          final icon = Icon(
                            isIncoming ? Icons.arrow_downward : Icons.arrow_upward,
                            color: isIncoming ? Colors.green : Colors.red,
                          );

                          final amountStyle = TextStyle(
                            fontWeight: FontWeight.bold,
                            color: isIncoming ? Colors.green : Colors.red,
                          );

                          return Card(
                            elevation: 2,
                            margin: const EdgeInsets.symmetric(vertical: 6),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: (isIncoming ? Colors.green.shade50 : Colors.red.shade50),
                                child: icon,
                              ),
                              title: Text(isIncoming ? "Received" : "Sent"),
                              subtitle: Text(formattedDate),
                              trailing: Text(formattedAmount, style: amountStyle),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}


