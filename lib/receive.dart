import 'package:carbine/lib.dart';
import 'package:carbine/request.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:numpad_layout/widgets/numpad.dart';

class Receive extends StatefulWidget {
  final FederationSelector fed;
  const Receive({Key? key, required this.fed}) : super(key: key);

  @override
  State<Receive> createState() => _ReceiveState();
}

class _ReceiveState extends State<Receive> {
  String _rawAmount = '';
  bool _creatingInvoice = false;

  String _formatAmount(String value) {
    if (value.isEmpty) return '0';
    final number = int.tryParse(value) ?? 0;
    final formatter = NumberFormat('#,###', 'en_US');
    return formatter.format(number).replaceAll(',', ' ');
  }

  Future<void> _onConfirm() async {
    setState(() {
      _creatingInvoice = true;
    });
    final amountMsats = BigInt.tryParse(_rawAmount);
    if (amountMsats != null) {
      final invoice = await receive(federationId: widget.fed.federationId, amountMsats: amountMsats);
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (context) => SizedBox(
          height: MediaQuery.of(context).size.height,
          child: Request(invoice: invoice.$1, fed: widget.fed, operationId: invoice.$2),
        ),
      );
    }
    setState(() {
      _creatingInvoice = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Enter Amount', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Column(
        children: [
          const SizedBox(height: 24),
          Text(
            _formatAmount(_rawAmount),
            style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: Center(
              child: NumPad(
                arabicDigits: false,
                onType: (value) {
                  setState(() {
                    _rawAmount += value.toString();
                  });
                },
                rightWidget: IconButton(
                  onPressed: () {
                    setState(() {
                      if (_rawAmount.isNotEmpty) {
                        _rawAmount = _rawAmount.substring(0, _rawAmount.length - 1);
                      } 
                    });
                  },
                  icon: const Icon(Icons.backspace)
                ),
              )
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _onConfirm,
                child: _creatingInvoice
                  ? const CircularProgressIndicator(color: Colors.white)
                  : const Text('Confirm', style: TextStyle(fontSize: 20)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}