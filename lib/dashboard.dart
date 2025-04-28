import 'package:carbine/lib.dart';
import 'package:carbine/receive.dart';
import 'package:carbine/scan.dart';
import 'package:flutter/material.dart';

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

  PaymentType _selectedPaymentType = PaymentType.lightning;

  @override
  void initState() {
    super.initState();
    _loadBalance();
  }

  Future<void> _loadBalance() async {
    final bal = await balance(federationId: widget.fed.federationId);
    setState(() {
      balanceMsats = bal;
      isLoadingBalance = false;
    });
  }

  void _onSendPressed() async {
    await Navigator.push(context, MaterialPageRoute(builder: (context) => ScanQRPage(selectedFed: widget.fed)));
    _loadBalance();
  }

  void _onReceivePressed() async {
    await Navigator.push(context, MaterialPageRoute(builder: (context) => Receive(fed: widget.fed)));
    _loadBalance();
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
          Text(
            name,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),

          if (isLoadingBalance)
            const CircularProgressIndicator()
          else
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
                child: Column(
                  children: [
                    const Text(
                      'Balance',
                      style: TextStyle(fontSize: 20, color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${balanceMsats ?? 0} msats',
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 24),

          // New: SegmentedButton with icons
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
              padding: MaterialStateProperty.all(const EdgeInsets.symmetric(vertical: 20, horizontal: 24)),
              shape: MaterialStateProperty.all(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(40),
                ),
              ),
              textStyle: MaterialStateProperty.all(
                const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              backgroundColor: MaterialStateProperty.resolveWith((states) {
                if (states.contains(MaterialState.selected)) {
                  return Theme.of(context).colorScheme.primary;
                }
                return Theme.of(context).colorScheme.surfaceVariant;
              }),
              foregroundColor: MaterialStateProperty.resolveWith((states) {
                if (states.contains(MaterialState.selected)) {
                  return Colors.white;
                }
                return Colors.black87;
              }),
              side: MaterialStateProperty.all(
                const BorderSide(color: Colors.transparent),
              ),
              shadowColor: MaterialStateProperty.all(Colors.black.withOpacity(0.2)),
              elevation: MaterialStateProperty.resolveWith<double>((states) {
                if (states.contains(MaterialState.selected)) {
                  return 6; // higher elevation when selected
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
        ],
      ),
    );
  }
}
