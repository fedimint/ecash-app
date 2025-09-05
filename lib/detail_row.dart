import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CopyableDetailRow extends StatefulWidget {
  final String label;
  final String value;
  final bool showCopyButton;
  final bool abbreviate; // NEW optional parameter
  final Widget? additionalAction;

  const CopyableDetailRow({
    super.key,
    required this.label,
    required this.value,
    this.showCopyButton = true,
    this.abbreviate = false, // default false
    this.additionalAction,
  });

  @override
  State<CopyableDetailRow> createState() => _CopyableDetailRowState();
}

class _CopyableDetailRowState extends State<CopyableDetailRow> {
  bool _isCopied = false;

  void _copyToClipboard() {
    Clipboard.setData(
      ClipboardData(text: widget.value),
    ); // always copy full text
    setState(() => _isCopied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _isCopied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Decide displayed text based on abbreviate flag
    final displayValue =
        widget.abbreviate ? getAbbreviatedText(widget.value) : widget.value;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              widget.label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.7),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.only(right: 8),
            height: 20,
            width: 2,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(0.7),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Value text with possible abbreviation
                Expanded(
                  child: Text(
                    displayValue,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontFamily: 'monospace',
                      height: 1.4,
                    ),
                    softWrap: true,
                  ),
                ),
                if (widget.additionalAction != null) widget.additionalAction!,
                // Optional copy button
                if (widget.showCopyButton)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: IconButton(
                      iconSize: 20,
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      onPressed: _copyToClipboard,
                      icon: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        transitionBuilder:
                            (child, anim) =>
                                ScaleTransition(scale: anim, child: child),
                        child:
                            _isCopied
                                ? Icon(
                                  Icons.check,
                                  key: const ValueKey('copied'),
                                  color: theme.colorScheme.primary,
                                )
                                : Icon(
                                  Icons.copy,
                                  key: const ValueKey('copy'),
                                  color: theme.colorScheme.primary,
                                ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
