import 'package:carbine/discover.dart';
import 'package:carbine/lib.dart';
import 'package:carbine/mnemonic.dart';
import 'package:carbine/multimint.dart';
import 'package:carbine/nwc.dart';
import 'package:carbine/relays.dart';
import 'package:carbine/theme.dart';
import 'package:flutter/material.dart';

class SettingsScreen extends StatefulWidget {
  final void Function(FederationSelector fed, bool recovering) onJoin;
  final VoidCallback onGettingStarted;
  const SettingsScreen({
    super.key,
    required this.onJoin,
    required this.onGettingStarted,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? hasAck;

  @override
  void initState() {
    super.initState();
    _checkSeedAck();
  }

  Future<void> _checkSeedAck() async {
    final result = await hasSeedPhraseAck();
    setState(() {
      hasAck = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SettingsOption(
            icon: Icons.group_add,
            title: "Getting Started",
            subtitle: "Learn how to get started with Fedimint",
            onTap: widget.onGettingStarted,
          ),
          _SettingsOption(
            icon: Icons.explore,
            title: "Discover",
            subtitle: "Find new Federations using Nostr",
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => Discover(onJoin: widget.onJoin),
                ),
              );
            },
          ),
          /*
          _SettingsOption(
            icon: Icons.flash_on,
            title: 'Lightning Address',
            subtitle: 'Claim and configure your Lightning Address',
            onTap: () async {
              final feds = await federations();
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (context) => LightningAddressScreen(
                        federations: feds,
                        onLnAddressRegistered: widget.onJoin,
                      ),
                ),
              );
            },
          ),
          */
          _SettingsOption(
            icon: Icons.link,
            title: 'Nostr Wallet Connect',
            subtitle: 'Connect to NWC-compatible apps',
            onTap: () async {
              final feds = await federations();
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => NostrWalletConnect(federations: feds),
                ),
              );
            },
          ),
          _SettingsOption(
            icon: Icons.link,
            title: 'Nostr Relays',
            subtitle: 'Configure your Nostr Relays',
            onTap: () async {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => Relays()),
              );
            },
          ),
          _SettingsOption(
            icon: Icons.vpn_key,
            title: 'Mnemonic',
            subtitle: 'View your seed phrase',
            warning: hasAck == false,
            onTap: () async {
              final words = await getMnemonic();
              await showCarbineModalBottomSheet(
                context: context,
                child: Mnemonic(words: words, hasAck: hasAck!),
              );
              _checkSeedAck();
            },
          ),
        ],
      ),
    );
  }
}

class _SettingsOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool warning;

  const _SettingsOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.warning = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, size: 28, color: theme.colorScheme.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (warning)
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 28,
                      color: Colors.orange,
                    ),
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
