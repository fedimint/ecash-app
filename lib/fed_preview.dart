import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class FederationPreview extends StatelessWidget {
  final String federationName;
  final String inviteCode;
  final String? welcomeMessage;
  final String? imageUrl;

  const FederationPreview({
    super.key,
    required this.federationName,
    required this.inviteCode,
    this.welcomeMessage,
    this.imageUrl,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        child: Column(
          children: [
            Container(
              width: 40,
              height: 5,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
            if (imageUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.network(
                  imageUrl!,
                  height: 150,
                  fit: BoxFit.cover,
                ),
              ),
            const SizedBox(height: 16),
            Text(
              federationName,
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            if (welcomeMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                welcomeMessage!,
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 24),
            QrImageView(
              data: inviteCode,
              version: QrVersions.auto,
              size: 200.0,
              backgroundColor: Colors.white,
            ),
            const SizedBox(height: 16),
            SelectableText(
              inviteCode,
              style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: inviteCode));
                // TODO: This does not appear to work, perhaps use FlutterToast
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("Invite code copied")),
                );
              },
              icon: const Icon(Icons.copy),
              label: const Text("Copy Invite Code"),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}