import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CopyableDetailRow extends StatefulWidget {
  final String label;
  final String value;
  final bool showCopyButton;
  final bool abbreviate; // NEW optional parameter
  final Widget? additionalAction;
  final double? labelWidth;

  const CopyableDetailRow({
    super.key,
    required this.label,
    required this.value,
    this.showCopyButton = true,
    this.abbreviate = false, // default false
    this.additionalAction,
    this.labelWidth,
  });

  @override
  State<CopyableDetailRow> createState() => _CopyableDetailRowState();
}

class _CopyableDetailRowState extends State<CopyableDetailRow> {
  bool _isCopied = false;

  /// Awaits the clipboard write before showing the copied tick. The platform
  /// call can reject — an unavailable channel, or a browser denying clipboard
  /// access — and the tick is the only signal the user gets, so showing it for
  /// a write that never happened tells them they hold something they do not.
  Future<void> _copyToClipboard() async {
    final failed = context.l10n.couldNotCopy;
    try {
      // always copy full text
      await Clipboard.setData(ClipboardData(text: widget.value));
    } catch (e) {
      AppLogger.instance.error('Could not copy to clipboard: $e');
      ToastService().show(
        message: failed,
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: const Icon(Icons.error),
      );
      return;
    }

    if (!mounted) return;
    setState(() => _isCopied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _isCopied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 400;

    // Decide displayed text based on abbreviate flag
    final displayValue =
        widget.abbreviate ? getAbbreviatedText(widget.value) : widget.value;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: widget.labelWidth ?? (isSmallScreen ? 110 : 120),
            child: Text(
              widget.label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.7),
                fontWeight: FontWeight.w600,
              ),
              softWrap: true,
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            height: 20,
            width: 2,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(0.7),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
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
