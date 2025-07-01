import 'package:carbine/lib.dart';
import 'package:carbine/utils.dart';
import 'package:flutter/material.dart';

class Relays extends StatefulWidget {
  const Relays({super.key});

  @override
  State<Relays> createState() => _RelaysState();
}

class _RelaysState extends State<Relays> {
  late Future<List<(String, bool)>> _relaysFuture;
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchRelays();
  }

  void _fetchRelays() {
    setState(() {
      _relaysFuture = getRelays();
    });
  }

  Future<void> _addRelay() async {
    final relay = _controller.text.trim();
    if (relay.isEmpty) return;

    try {
      await insertRelay(relayUri: relay);
      _controller.clear();
      _fetchRelays();
    } catch (e) {
      AppLogger.instance.error("Could not add relay: $e");
    }
  }

  Widget _buildRelayTile(String relay, bool isConnected) {
    final statusColor = isConnected ? Colors.greenAccent : Colors.redAccent;
    final statusText = isConnected ? "Connected" : "Disconnected";

    return ListTile(
      leading: ColorFiltered(
        colorFilter: ColorFilter.mode(statusColor, BlendMode.srcIn),
        child: Image.asset('assets/images/nostr.png', width: 36, height: 36),
      ),
      title: Text(relay, style: const TextStyle(color: Colors.white)),
      subtitle: Row(
        children: [
          Icon(Icons.circle, size: 10, color: statusColor),
          const SizedBox(width: 6),
          Text(statusText, style: TextStyle(color: statusColor)),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete, color: Colors.redAccent),
        tooltip: 'Delete Relay',
        onPressed: () async {
          try {
            await removeRelay(relayUri: relay);
            _fetchRelays();
          } catch (e) {
            AppLogger.instance.error("Could not delete relay: $e");
          }
        },
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              "Carbine uses Nostr relays to back up which federations you have joined. You can customize them below.",
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Nostr Relays')),
      body: Column(
        children: [
          const SizedBox(height: 16),
          _buildHeader(theme),
          const SizedBox(height: 16),
          Expanded(
            child: FutureBuilder<List<(String, bool)>>(
              future: _relaysFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.greenAccent),
                  );
                } else if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      'Error: ${snapshot.error}',
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  );
                } else {
                  final relays = snapshot.data!;
                  if (relays.isEmpty) {
                    return const Center(
                      child: Text(
                        'No relays found.',
                        style: TextStyle(color: Colors.white70),
                      ),
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: relays.length,
                    separatorBuilder:
                        (_, __) => const Divider(color: Colors.white10),
                    itemBuilder: (context, index) {
                      final (relay, isConnected) = relays[index];
                      return _buildRelayTile(relay, isConnected);
                    },
                  );
                }
              },
            ),
          ),
          const Divider(color: Colors.white10),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: 'wss://example.com',
                      hintStyle: TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Color(0xFF111111),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _addRelay,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.greenAccent,
                    foregroundColor: Colors.black,
                  ),
                  child: const Text('Add Relay'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
