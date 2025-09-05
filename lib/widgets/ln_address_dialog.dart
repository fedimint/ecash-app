import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

void showLightningAddressDialog(
  BuildContext context,
  String username,
  String domain,
  String lnurl,
) async {
  final lnAddress = '$username@$domain';

  showDialog(
    context: context,
    builder: (context) {
      return _LightningAddressDialog(
        addresses: [lnAddress, lnurl],
        titles: ['Lightning Address', 'LNURL'],
      );
    },
  );
}

class _LightningAddressDialog extends StatefulWidget {
  final List<String> addresses;
  final List<String> titles;

  const _LightningAddressDialog({
    required this.addresses,
    required this.titles,
  });

  @override
  State<_LightningAddressDialog> createState() =>
      _LightningAddressDialogState();
}

class _LightningAddressDialogState extends State<_LightningAddressDialog> {
  int _currentPage = 0;
  final PageController _pageController = PageController();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int page) {
    setState(() {
      _currentPage = page;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      title: Center(
        child: Text(widget.titles[_currentPage], textAlign: TextAlign.center),
      ),
      content: SizedBox(
        width: 320,
        height: 360,
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  PageView.builder(
                    controller: _pageController,
                    itemCount: widget.addresses.length,
                    onPageChanged: _onPageChanged,
                    itemBuilder: (context, index) {
                      return _LightningAddressPage(
                        data: widget.addresses[index],
                        title: widget.titles[_currentPage],
                      );
                    },
                  ),
                  if (!isMobile) ...[
                    // Left arrow button
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        iconSize: 32,
                        icon: Icon(
                          Icons.arrow_back_ios,
                          color:
                              _currentPage == 0
                                  ? Colors.grey.shade400
                                  : Theme.of(context).colorScheme.primary,
                        ),
                        onPressed:
                            _currentPage == 0
                                ? null
                                : () {
                                  _pageController.previousPage(
                                    duration: const Duration(milliseconds: 300),
                                    curve: Curves.easeInOut,
                                  );
                                },
                      ),
                    ),
                    // Right arrow button
                    Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        iconSize: 32,
                        icon: Icon(
                          Icons.arrow_forward_ios,
                          color:
                              _currentPage == widget.addresses.length - 1
                                  ? Colors.grey.shade400
                                  : Theme.of(context).colorScheme.primary,
                        ),
                        onPressed:
                            _currentPage == widget.addresses.length - 1
                                ? null
                                : () {
                                  _pageController.nextPage(
                                    duration: const Duration(milliseconds: 300),
                                    curve: Curves.easeInOut,
                                  );
                                },
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            _buildPageIndicator(),
          ],
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.primary,
          ),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Close"),
        ),
      ],
    );
  }

  Widget _buildPageIndicator() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(widget.addresses.length, (index) {
        final isActive = index == _currentPage;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          margin: const EdgeInsets.symmetric(horizontal: 6),
          width: isActive ? 16 : 8,
          height: 8,
          decoration: BoxDecoration(
            color:
                isActive
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.primary.withOpacity(0.3),
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}

class _LightningAddressPage extends StatelessWidget {
  final String data;
  final String title;

  const _LightningAddressPage({required this.data, required this.title});

  @override
  Widget build(BuildContext context) {
    String toastText;
    if (data.contains('@')) {
      toastText = data;
    } else {
      toastText = getAbbreviatedText(data);
    }
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ],
              border: Border.all(
                color: Theme.of(context).colorScheme.primary.withOpacity(0.7),
                width: 1.5,
              ),
            ),
            child: SizedBox(
              width: 200,
              height: 200,
              child: QrImageView(
                data: data,
                version: QrVersions.auto,
                backgroundColor: Colors.white,
                padding: EdgeInsets.zero,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.copy, size: 18, color: Colors.black),
              label: Text("Copy $title", style: TextStyle(color: Colors.black)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 4,
              ),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: data));
                ToastService().show(
                  message: "Copied $toastText",
                  duration: const Duration(seconds: 5),
                  onTap: () {},
                  icon: Icon(Icons.check),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
