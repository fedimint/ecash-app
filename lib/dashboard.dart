
import 'package:carbine/lib.dart';
import 'package:carbine/scan.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class Dashboard extends StatefulWidget {
  final FederationSelector fed;

  const Dashboard({super.key, required this.fed});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  BigInt? balanceMsats;
  bool isLoadingBalance = true;

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

  Future<(String, OperationId)> _getInvoice(BigInt amount) async {
    final r = await receive(federationId: widget.fed.federationId, amountMsats: amount);
    return r;
  }

  void _showReceiveDialog(BuildContext context) {
    final amountController = TextEditingController();

    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text("Receive Amount"),
          content: TextField(
            controller: amountController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: "Amount (msats)",
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              child: const Text("Cancel"),
              onPressed: () => Navigator.pop(dialogContext),
            ),
            ElevatedButton(
              child: const Text("Generate QR"),
              onPressed: () {
                final amountText = amountController.text;
                final amount = BigInt.tryParse(amountText);
                if (amount != null) {
                  Navigator.pop(dialogContext);
                  _showQRCodeDialog(context, amount);
                }
              },
            ),
          ],
        );
      },
    );
  }

  void _showQRCodeDialog(BuildContext context, BigInt amount) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return Dialog(
          child: FutureBuilder<(String, OperationId)>(
            future: _getInvoice(amount),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const SizedBox(
                  height: 200,
                  width: 200,
                  child: Center(child: CircularProgressIndicator()),
                );
              } else if (snapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text("Error generating QR code"),
                      const SizedBox(height: 8),
                      Text('${snapshot.error}'),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text("Close"),
                      )
                    ],
                  ),
                );
              }

              final (invoice, opId) = snapshot.data!;

              // Start background task when QR is displayed
              _waitForPayment(context, opId);

              return Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        QrImageView(
                          data: invoice,
                          version: QrVersions.auto,
                          size: 200,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          invoice,
                          style: const TextStyle(fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            TextButton(
                              child: const Text("Copy"),
                              onPressed: () async {
                                await Clipboard.setData(ClipboardData(text: invoice));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text("Copied to clipboard")),
                                );
                              },
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text("Close"),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Spinner overlay (non-interfering)
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring: true,
                      child: Container(
                        color: Colors.black.withOpacity(0.3),
                        child: const Center(child: CircularProgressIndicator()),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  void _waitForPayment(BuildContext context, OperationId opId) async {
    await awaitReceive(federationId: widget.fed.federationId, operationId: opId);

    // Pop all dialogs
    Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);

    // TODO: Check state, verify success
    // Show success message
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Payment Success")),
    );

    // Refresh the balance
    _loadBalance();
  }

  void _onSendPressed() async {
    await Navigator.push(context, MaterialPageRoute(builder: (context) => ScanQRPage(selectedFed: widget.fed)));
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
                            onPressed: () => _showReceiveDialog(context),
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
                          onPressed: () => _showReceiveDialog(context),
                          icon: const Icon(Icons.download),
                          label: const Text("Receive"),
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: () => print("Send tapped"),
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