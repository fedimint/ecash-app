import 'package:carbine/lib.dart';
import 'package:flutter/material.dart';
import 'dart:async';

class Mnemonic extends StatefulWidget {
  final List<String> words;
  final bool hasAck;

  const Mnemonic({super.key, required this.words, required this.hasAck})
    : assert(words.length == 12, 'Mnemonic must contain exactly 12 words');

  @override
  State<Mnemonic> createState() => _MnemonicState();
}

class _MnemonicState extends State<Mnemonic> {
  double _progress = 0.0;
  Timer? _timer;

  static const int holdDurationMs = 1500;
  static const int tickIntervalMs = 50;

  void _startHold() {
    _timer?.cancel();
    _progress = 0.0;
    _timer = Timer.periodic(const Duration(milliseconds: tickIntervalMs), (
      timer,
    ) {
      setState(() {
        _progress += tickIntervalMs / holdDurationMs;
        if (_progress >= 1.0) {
          _progress = 1.0;
          _timer?.cancel();
          _onHoldComplete();
        }
      });
    });
  }

  void _cancelHold() {
    _timer?.cancel();
    setState(() {
      _progress = 0.0;
    });
  }

  Future<void> _onHoldComplete() async {
    await ackSeedPhrase();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color baseColor = theme.colorScheme.primary;
    final Color fillColor = Color(0xFF001F3F);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.hasAck) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning, color: Colors.orange),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Please acknowledge that you have written your seed phrase down by holding the button below',
                    style: const TextStyle(color: Colors.orange),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          "Your Recovery Phrase",
          style: theme.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 12,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            childAspectRatio: 5,
            crossAxisSpacing: 16,
            mainAxisSpacing: 8,
          ),
          itemBuilder: (context, index) {
            return Row(
              children: [
                Text("${index + 1}. ", style: theme.textTheme.bodyMedium),
                Expanded(
                  child: Text(
                    widget.words[index],
                    style: theme.textTheme.bodyLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            );
          },
        ),
        if (!widget.hasAck) ...[
          const SizedBox(height: 32),
          GestureDetector(
            onLongPressStart: (_) => _startHold(),
            onLongPressEnd: (_) => _cancelHold(),
            onLongPressCancel: _cancelHold,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final fillWidth = constraints.maxWidth * _progress;
                return Container(
                  decoration: BoxDecoration(
                    color: baseColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Stack(
                    children: [
                      // Fill progress bar container:
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 50),
                        width: fillWidth,
                        decoration: BoxDecoration(
                          color: fillColor,
                          borderRadius: BorderRadius.horizontal(
                            left: Radius.circular(12),
                            right: Radius.circular(_progress == 1 ? 12 : 0),
                          ),
                        ),
                        height:
                            48, // matches button height padding + line height
                      ),

                      // Centered text:
                      SizedBox(
                        height: 48,
                        child: Center(
                          child: Text(
                            "I have written my seed down",
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: Colors.black,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 24),
        ],
      ],
    );
  }
}
