import 'package:carbine/lib.dart';
import 'package:carbine/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class FederationPreview extends StatefulWidget {
  final String federationName;
  final String inviteCode;
  final String? welcomeMessage;
  final String? imageUrl;
  final bool joinable;
  final List<Guardian> guardians;

  const FederationPreview({
    super.key,
    required this.federationName,
    required this.inviteCode,
    this.welcomeMessage,
    this.imageUrl,
    required this.joinable,
    required this.guardians,
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
    final totalGuardians = widget.guardians.length;
    final thresh = threshold(totalGuardians);
    final onlineGuardians = widget.guardians.where((g) => g.version != null).toList();
    final isFederationOnline = totalGuardians > 0 && onlineGuardians.length >= threshold(totalGuardians);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag handle
            Container(
              width: 40,
              height: 5,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),

            // Federation image
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  width: 150,
                  height: 150,
                  child: widget.imageUrl != null
                      ? Image.network(
                          widget.imageUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return Image.asset(
                              'assets/images/fedimint.png',
                              fit: BoxFit.cover,
                            );
                          },
                        )
                      : Image.asset(
                          'assets/images/fedimint.png',
                          fit: BoxFit.cover,
                        ),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Federation name
            Text(
              widget.federationName,
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),

            // Welcome message
            if (widget.welcomeMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                widget.welcomeMessage!,
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],

            const SizedBox(height: 24),

            if (isFederationOnline) ...[
              // QR code
              Center(
                child: QrImageView(
                  data: widget.inviteCode,
                  version: QrVersions.auto,
                  size: 200.0,
                  backgroundColor: Colors.white,
                ),
              ),

              const SizedBox(height: 16),

              // Invite code
              SelectableText(
                widget.inviteCode,
                style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 8),

              // Join / Copy button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _onButtonPressed,
                  child: isJoining
                      ? const CircularProgressIndicator(color: Colors.white)
                      : Text(widget.joinable ? "Join Federation" : "Copy Invite Code"),
                ),
              ),

              // Guardian list
              if (widget.guardians.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(
                  'Guardians ($thresh/$totalGuardians federation)',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: widget.guardians.length,
                  itemBuilder: (context, index) {
                    final guardian = widget.guardians[index];
                    final isOnline = guardian.version != null;

                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Icons.circle,
                        color: isOnline ? Colors.green : Colors.red,
                        size: 12,
                      ),
                      title: Text(guardian.name),
                      subtitle: isOnline
                          ? Text('Version: ${guardian.version}')
                          : const Text('Offline'),
                    );
                  },
                ),
              ],
            ] else ...[
              const SizedBox(height: 16),
              const Text(
                "This federation is offline, please reach out to the guardian operators.",
                style: TextStyle(fontSize: 16, color: Colors.red),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}