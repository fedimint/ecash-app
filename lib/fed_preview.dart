import 'package:carbine/lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class FederationPreview extends StatefulWidget {
  final String federationName;
  final String inviteCode;
  final String? welcomeMessage;
  final String? imageUrl;
  final bool joinable;

  const FederationPreview({
    super.key,
    required this.federationName,
    required this.inviteCode,
    this.welcomeMessage,
    this.imageUrl,
    required this.joinable,
  });

  @override
  State<FederationPreview> createState() => _FederationPreviewState();
}

class _FederationPreviewState extends State<FederationPreview> {
  bool isJoining = false; 

  Future<void> _onButtonPressed() async {
    if (widget.joinable) {
      setState(() {
        isJoining = true;
      });
      try {
        final fed = await joinFederation(inviteCode: widget.inviteCode);
        print('Successfully joined federation');
        if (mounted) {
          Navigator.of(context).pop(fed);
        }
      } catch (e) {
        print('Could not join federation $e');
        setState(() {
          isJoining = false;
        });
      }
    } else {
      // TODO: show toast here
      Clipboard.setData(ClipboardData(text: widget.inviteCode));
      print('Invite code copied');
    }
  }

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
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: widget.imageUrl != null
                  ? Image.network(
                      widget.imageUrl!,
                      height: 150,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return Image.asset(
                          'assets/images/fedimint.png',
                          height: 150,
                          fit: BoxFit.cover,
                        );
                      },
                    )
                  : Image.asset(
                      'assets/images/fedimint.png',
                      height: 150,
                      fit: BoxFit.cover,
                    ),
            ),
            const SizedBox(height: 16),
            Text(
              widget.federationName,
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            if (widget.welcomeMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                widget.welcomeMessage!,
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 24),
            QrImageView(
              data: widget.inviteCode,
              version: QrVersions.auto,
              size: 200.0,
              backgroundColor: Colors.white,
            ),
            const SizedBox(height: 16),
            SelectableText(
              widget.inviteCode,
              style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _onButtonPressed,
                child: isJoining 
                  ? const CircularProgressIndicator(color: Colors.white)
                  : Text(widget.joinable ? "Join Federation" : "Copy Invite Code")
              )
            )
          ],
        ),
      ),
    );
  }
}