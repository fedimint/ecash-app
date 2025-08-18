import 'package:ecashapp/fed_preview.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/nostr.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shimmer/shimmer.dart';

class Discover extends StatefulWidget {
  final void Function(FederationSelector fed, bool recovering) onJoin;
  const Discover({super.key, required this.onJoin});

  @override
  State<Discover> createState() => _Discover();
}

class _Discover extends State<Discover> with SingleTickerProviderStateMixin {
  late Future<List<PublicFederation>> _futureFeds;
  PublicFederation? _gettingMetadata;

  final TextEditingController _inviteCodeController = TextEditingController();
  bool _isInviteCodeValid = false;
  bool _isLoadingInvitePreview = false;

  @override
  void initState() {
    super.initState();
    _futureFeds = listFederationsFromNostr(forceUpdate: false);
    _inviteCodeController.addListener(_validateInviteCode);
  }

  @override
  void dispose() {
    _inviteCodeController.removeListener(_validateInviteCode);
    _inviteCodeController.dispose();
    super.dispose();
  }

  void _validateInviteCode() {
    final text = _inviteCodeController.text.trim();
    final isValid = text.isNotEmpty && text.startsWith('fed');
    if (isValid != _isInviteCodeValid) {
      setState(() => _isInviteCodeValid = isValid);
    }
  }

  Future<void> _onPreviewPressed(String inviteCode) async {
    try {
      final meta = await getFederationMeta(inviteCode: inviteCode);
      setState(() {
        _gettingMetadata = null;
        _isLoadingInvitePreview = false;
      });

      final fed = await showAppModalBottomSheet(
        context: context,
        child: FederationPreview(
          fed: meta.selector,
          inviteCode: inviteCode,
          welcomeMessage: meta.welcome,
          imageUrl: meta.picture,
          joinable: true,
          guardians: meta.guardians,
        ),
      );

      if (fed != null) {
        final name = fed.$1.federationName;
        await Future.delayed(const Duration(milliseconds: 400));
        widget.onJoin(fed.$1, fed.$2);
        ToastService().show(
          message: "Joined $name",
          duration: const Duration(seconds: 5),
          onTap: () {},
          icon: const Icon(Icons.info),
        );
      }
    } catch (e) {
      AppLogger.instance.warn("Error when retrieving federation meta: $e");
      ToastService().show(
        message: "Sorry! Could not get federation metadata",
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: const Icon(Icons.error),
      );
      setState(() => _gettingMetadata = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: FutureBuilder<List<PublicFederation>>(
          future: _futureFeds,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return _buildShimmerLoading();
            } else if (snapshot.hasError) {
              return Center(
                child: Text(
                  "Error: ${snapshot.error}",
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              );
            } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
              return const Center(
                child: Text("No public federations available to join"),
              );
            }

            final federations = snapshot.data!;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildHeader(theme),
                const SizedBox(height: 24),
                _buildInviteCodeSection(theme),
                const SizedBox(height: 24),
                ...federations.map(
                  (federation) => _buildFederationCard(federation, theme),
                ),
                const SizedBox(height: 32),
                _buildObserverLink(theme),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildShimmerLoading() {
    return Shimmer.fromColors(
      baseColor: Colors.grey[850]!,
      highlightColor: Colors.grey[700]!,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: 5,
        itemBuilder:
            (context, index) => Container(
              margin: const EdgeInsets.only(bottom: 16),
              height: 80,
              decoration: BoxDecoration(
                color: Colors.grey[800],
                borderRadius: BorderRadius.circular(16),
              ),
            ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Image.asset('assets/images/e-cash-app.png', width: 120, height: 120),
        const SizedBox(height: 16),
        Text(
          "The E-Cash App",
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge?.copyWith(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.bold,
            fontStyle: FontStyle.italic,
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildInviteCodeSection(ThemeData theme) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color:
              _isInviteCodeValid
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey[700]!,
          width: 2,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inviteCodeController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Enter invite code',
                labelStyle: TextStyle(color: Colors.grey[400]),
                border: InputBorder.none,
              ),
              enabled: !_isLoadingInvitePreview,
            ),
          ),
          if (_isInviteCodeValid)
            Icon(
              Icons.check_circle,
              color: Theme.of(context).colorScheme.primary,
            ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed:
                (_isInviteCodeValid &&
                        !_isLoadingInvitePreview &&
                        _gettingMetadata == null)
                    ? () async {
                      setState(() => _isLoadingInvitePreview = true);
                      final inviteCode = _inviteCodeController.text.trim();
                      await _onPreviewPressed(inviteCode);
                      setState(() => _isLoadingInvitePreview = false);
                    }
                    : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
            child:
                _isLoadingInvitePreview
                    ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                    : const Text('Preview'),
          ),
        ],
      ),
    );
  }

  Widget _buildObserverLink(ThemeData theme) {
    return Center(
      child: GestureDetector(
        onTap: () => launchUrl(Uri.parse("https://observer.fedimint.org/")),
        child: Text(
          "Explore more at observer.fedimint.org",
          style: theme.textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.primary,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
  }

  Widget _buildFederationCard(PublicFederation federation, ThemeData theme) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.primary,
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Card(
        color: Colors.grey[900],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap:
              (_gettingMetadata == null && !_isLoadingInvitePreview)
                  ? () async {
                    setState(() => _gettingMetadata = federation);
                    await _onPreviewPressed(federation.inviteCodes.first);
                  }
                  : null,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child:
                      federation.picture != null &&
                              federation.picture!.isNotEmpty
                          ? Image.network(
                            federation.picture!,
                            width: 50,
                            height: 50,
                            fit: BoxFit.cover,
                            errorBuilder:
                                (_, __, ___) => Image.asset(
                                  'assets/images/fedimint-icon-color.png',
                                  width: 50,
                                  height: 50,
                                ),
                          )
                          : Image.asset(
                            'assets/images/fedimint-icon-color.png',
                            width: 50,
                            height: 50,
                          ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        federation.federationName,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "Network: ${federation.network == 'bitcoin' ? 'mainnet' : federation.network}",
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.grey[400],
                        ),
                      ),
                      if (federation.about != null &&
                          federation.about!.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          federation.about!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.grey[400],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _gettingMetadata == federation
                    ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                      ),
                      onPressed:
                          (_gettingMetadata == null && !_isLoadingInvitePreview)
                              ? () async {
                                setState(() => _gettingMetadata = federation);
                                await _onPreviewPressed(
                                  federation.inviteCodes.first,
                                );
                              }
                              : null,
                      icon: const Icon(Icons.info_outline, size: 18),
                      label: const Text("Preview"),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
