import 'dart:convert';

import 'package:carbine/lib.dart';
import 'package:carbine/request.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:numpad_layout/widgets/numpad.dart';

class NumberPad extends StatefulWidget {
  final FederationSelector fed;
  const NumberPad({super.key, required this.fed});

  @override
  State<NumberPad> createState() => _NumberPadState();
}

class _NumberPadState extends State<NumberPad> {
  String _rawAmount = '';
  bool _creating = false;
  double? _btcPriceUsd;

  @override
  void initState() {
    super.initState();
    _fetchPrice();
  }

  Future<void> _fetchPrice() async {
    try {
      final uri = Uri.parse('https://mempool.space/api/v1/prices');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _btcPriceUsd = (data['USD'] as num).toDouble();
        });
      } else {
        debugPrint('Failed to load price data');
      }
    } catch (e) {
      debugPrint('Error fetching price: $e');
    }
  }

  String _formatAmount(String value) {
    if (value.isEmpty) return '0';
    final number = int.tryParse(value) ?? 0;
    final formatter = NumberFormat('#,###', 'en_US');
    return formatter.format(number).replaceAll(',', ' ');
  }

  String _calculateUsdValue() {
    if (_btcPriceUsd == null) return '';
    final sats = int.tryParse(_rawAmount) ?? 0;
    final usdValue = (_btcPriceUsd! * sats) / 100000000;
    return '\$${usdValue.toStringAsFixed(2)}';
  }

  Future<void> _onConfirm() async {
    setState(() => _creating = true);
    final amountSats = BigInt.tryParse(_rawAmount);
    if (amountSats != null) {
      final amountMsats = amountSats * BigInt.from(1000);
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
    setState(() => _creating = false);
  }

  @override
  Widget build(BuildContext context) {
    final usdText = _calculateUsdValue();

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
          const SizedBox(height: 8),
          Text(
            usdText,
            style: const TextStyle(fontSize: 24, color: Colors.grey),
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
                  icon: const Icon(Icons.backspace),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _onConfirm,
                child: _creating
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
