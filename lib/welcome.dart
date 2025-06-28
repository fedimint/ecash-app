import 'package:carbine/discover.dart';
import 'package:carbine/multimint.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';
import 'package:url_launcher/url_launcher.dart'; // Add to pubspec.yaml

class WelcomeWidget extends StatefulWidget {
  final void Function(FederationSelector fed, bool recovering) onJoin;
  const WelcomeWidget({super.key, required this.onJoin});

  @override
  State<WelcomeWidget> createState() => _WelcomeWidgetState();
}

class _WelcomeWidgetState extends State<WelcomeWidget> {
  final PageController _controller = PageController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get isMobile {
    return defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android ||
        kIsWeb;
  }

  Widget _buildPage({required Widget content}) {
    return Center(
      child: Padding(padding: const EdgeInsets.all(24.0), child: content),
    );
  }

  Widget _buildFedimintIntroPage(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.security, size: 80, color: Theme.of(context).primaryColor),
        const SizedBox(height: 32),
        const Text(
          'What is Fedimint?',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            style: DefaultTextStyle.of(context).style.copyWith(fontSize: 16),
            children: [
              const TextSpan(
                text:
                    'Fedimint is an open-source protocol that lets communities securely and privately hold and spend Bitcoin together using federated Chaumian ecash.\n\n',
              ),
              const TextSpan(
                text:
                    'It enables scalable, community-based custody with privacy at its core. With Fedimint, you don’t need to trust a single custodian — you trust your community.\n\n',
              ),
              TextSpan(
                text: 'Learn more at fedimint.org',
                style: const TextStyle(
                  color: Colors.blue,
                  decoration: TextDecoration.underline,
                ),
                recognizer:
                    TapGestureRecognizer()
                      ..onTap = () async {
                        const url = 'https://fedimint.org';
                        if (await canLaunch(url)) {
                          await launch(url);
                        }
                      },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDiscoverPage(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.explore, size: 80, color: Theme.of(context).primaryColor),
        const SizedBox(height: 32),
        const Text(
          'Getting Started',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        const Text(
          "To get started, you will need to join your community's federation by copying or scanning the join code.",
          style: TextStyle(fontSize: 16),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            style: DefaultTextStyle.of(context).style.copyWith(fontSize: 16),
            children: [
              const TextSpan(
                text:
                    'If your community does not have a federation, you can discover new federations through ',
              ),
              TextSpan(
                text: 'Nostr',
                style: const TextStyle(
                  color: Colors.blue,
                  decoration: TextDecoration.underline,
                ),
                recognizer:
                    TapGestureRecognizer()
                      ..onTap = () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder:
                                (context) => Discover(onJoin: widget.onJoin),
                          ),
                        );
                      },
              ),
              const TextSpan(text: ' or by visiting '),
              TextSpan(
                text: 'Fedimint Observer',
                style: const TextStyle(
                  color: Colors.blue,
                  decoration: TextDecoration.underline,
                ),
                recognizer:
                    TapGestureRecognizer()
                      ..onTap = () async {
                        const url = 'https://observer.fedimint.org';
                        if (await canLaunch(url)) {
                          await launch(url);
                        }
                      },
              ),
              const TextSpan(text: '.'),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: PageView(
            controller: _controller,
            children: [
              _buildPage(content: _buildFedimintIntroPage(context)),
              _buildPage(content: _buildDiscoverPage(context)),
            ],
          ),
        ),
        if (!isMobile) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  if (_controller.page! > 0) {
                    _controller.previousPage(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    );
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.arrow_forward),
                onPressed: () {
                  if (_controller.page! < 1) {
                    _controller.nextPage(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    );
                  }
                },
              ),
            ],
          ),
        ],
        Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: SmoothPageIndicator(
            controller: _controller,
            count: 2,
            effect: const WormEffect(
              dotHeight: 10,
              dotWidth: 10,
              spacing: 12,
              activeDotColor: Colors.blueAccent,
            ),
          ),
        ),
      ],
    );
  }
}
