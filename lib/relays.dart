import 'package:carbine/lib.dart';
import 'package:carbine/utils.dart';
import 'package:flutter/material.dart';

class Relays extends StatefulWidget {
  const Relays({Key? key}) : super(key: key);

  @override
  State<Relays> createState() => _RelaysState();
}

class _RelaysState extends State<Relays> {
  late Future<List<String>> _relaysFuture;
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

  Widget _buildRelayTile(String relay) {
    return ListTile(
      title: Text(relay, style: const TextStyle(color: Colors.white)),
      trailing: const Icon(Icons.check_circle, color: Colors.greenAccent),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Relays')),
      body: Column(
        children: [
          Expanded(
            child: FutureBuilder<List<String>>(
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
                    itemCount: relays.length,
                    separatorBuilder:
                        (_, __) => const Divider(color: Colors.white10),
                    itemBuilder:
                        (context, index) => _buildRelayTile(relays[index]),
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
                  child: const Text('Add Relay'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.greenAccent,
                    foregroundColor: Colors.black,
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
