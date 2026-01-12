import 'package:flutter/material.dart';
import 'package:ecashapp/widgets/numpad/numpad_button.dart';

class CustomNumPad extends StatelessWidget {
  final ValueChanged<int> onDigitPressed;
  final VoidCallback onBackspace;
  final VoidCallback? onLeftAction;
  final bool leftActionLoading;
  final Widget? leftWidget;

  const CustomNumPad({
    super.key,
    required this.onDigitPressed,
    required this.onBackspace,
    this.onLeftAction,
    this.leftActionLoading = false,
    this.leftWidget,
  });

  Widget _buildDigitRow(List<String> digits) {
    return SizedBox(
      height: 64,
      child: Row(
        children: digits.map((digit) {
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: NumPadButton(
                label: digit,
                onPressed: () => onDigitPressed(int.parse(digit)),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildBottomRow() {
    return SizedBox(
      height: 64,
      child: Row(
        children: [
          // Left button (custom widget, MAX, or empty spacer)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: leftWidget ??
                  (onLeftAction != null
                      ? NumPadButton(
                          label: 'MAX',
                          onPressed: onLeftAction!,
                          isSpecial: true,
                          isLoading: leftActionLoading,
                        )
                      : const SizedBox()),
            ),
          ),

          // Zero button
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: NumPadButton(
                label: '0',
                onPressed: () => onDigitPressed(0),
              ),
            ),
          ),

          // Backspace button
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: NumPadButton(
                label: '',
                onPressed: onBackspace,
                isSpecial: true,
                child: const Icon(
                  Icons.backspace_outlined,
                  color: Colors.grey,
                  size: 24,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildDigitRow(['1', '2', '3']),
        const SizedBox(height: 8),
        _buildDigitRow(['4', '5', '6']),
        const SizedBox(height: 8),
        _buildDigitRow(['7', '8', '9']),
        const SizedBox(height: 8),
        _buildBottomRow(),
      ],
    );
  }
}
