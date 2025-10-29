import 'package:ecashapp/db.dart';
import 'package:ecashapp/discover.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/ln_address.dart';
import 'package:ecashapp/mnemonic.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/nwc.dart';
import 'package:ecashapp/relays.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

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
  String? _version;

  @override
  void initState() {
    super.initState();
    _checkSeedAck();
    _loadVersion();
  }

  Future<void> _checkSeedAck() async {
    final result = await hasSeedPhraseAck();
    setState(() {
      hasAck = result;
    });
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    setState(() {
      _version = "v${info.version}+${info.buildNumber}";
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SettingsOption(
            icon: Icon(
              Icons.group_add,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: "Discover",
            subtitle: "Find new or join existing federations",
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (context) => Discover(
                        onJoin: widget.onJoin,
                        showAppBar: true,
                      ),
                ),
              );
            },
          ),
          _SettingsOption(
            icon: Icon(
              Icons.flash_on,
              color: Theme.of(context).colorScheme.primary,
            ),
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
          _SettingsOption(
            icon: Icon(
              Icons.link,
              color: Theme.of(context).colorScheme.primary,
            ),
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
            icon: Image.asset(
              'assets/images/nostr.png',
              color: Theme.of(context).colorScheme.primary,
            ),
            title: 'Nostr Relays',
            subtitle: 'Add or remove Nostr relays',
            onTap: () async {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => Relays()),
              );
            },
          ),
          _SettingsOption(
            icon: Icon(
              Icons.display_settings,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: 'Display',
            subtitle: 'Configure display settings',
            onTap: () {
              _showDisplaySettingDialog(context);
            },
          ),
          _SettingsOption(
            icon: Icon(
              Icons.vpn_key,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: 'Mnemonic',
            subtitle: 'View your seed phrase',
            warning: hasAck == false,
            onTap: () async {
              await showAppModalBottomSheet(
                context: context,
                childBuilder: () async {
                  final words = await getMnemonic();
                  return Mnemonic(words: words, hasAck: hasAck!);
                },
              );
              _checkSeedAck();
            },
          ),
          const SizedBox(height: 24),
          if (_version != null)
            Center(
              child: Text(
                "Version: ${_version!}",
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SettingsOption extends StatelessWidget {
  final Widget icon;
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
              SizedBox(width: 36, height: 36, child: icon),
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

void _showDisplaySettingDialog(BuildContext context) {
  DisplaySetting selected = getCachedDisplaySetting() ?? DisplaySetting.bip177;

  showDialog(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('Select Display Setting'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<DisplaySetting>(
                  title: const Text('BIP177 (₿1,234)'),
                  value: DisplaySetting.bip177,
                  groupValue: selected,
                  onChanged: (value) => setState(() => selected = value!),
                ),
                RadioListTile<DisplaySetting>(
                  title: const Text('Sats are the Standard (1,234 sats)'),
                  value: DisplaySetting.sats,
                  groupValue: selected,
                  onChanged: (value) => setState(() => selected = value!),
                ),
                RadioListTile<DisplaySetting>(
                  title: const Text('Sat Symbol (1,234丰)'),
                  value: DisplaySetting.symbol,
                  groupValue: selected,
                  onChanged: (value) => setState(() => selected = value!),
                ),
                RadioListTile<DisplaySetting>(
                  title: const Text('No label (1,234)'),
                  value: DisplaySetting.nothing,
                  groupValue: selected,
                  onChanged: (value) => setState(() => selected = value!),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () async {
                  await saveDisplaySetting(selected);
                  Navigator.of(context).pop();
                  ToastService().show(
                    message: "Display setting set!",
                    duration: const Duration(seconds: 3),
                    onTap: () {},
                    icon: Icon(Icons.info),
                  );
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      );
    },
  );
}
