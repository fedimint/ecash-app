import 'package:ecashapp/lib.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';

class Relays extends StatefulWidget {
  const Relays({super.key});

  @override
  State<Relays> createState() => _RelaysState();
}

class _RelaysState extends State<Relays> {
  late Future<List<(String, bool)>> _relaysFuture;
  final TextEditingController _controller = TextEditingController();
  bool _isInputValid = false;
  String _inputText = '';

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

  bool _isValidRelayUri(String input) {
    if (input.isEmpty) return false;
    try {
      final uri = Uri.parse(input);
      return uri.scheme == 'wss' && uri.hasAuthority;
    } catch (_) {
      return false;
    }
  }

  void _onInputChanged(String value) {
    setState(() {
      _inputText = value.trim();
      _isInputValid = _isValidRelayUri(_inputText);
    });
  }

  Future<void> _addRelay() async {
    final relay = _controller.text.trim();
    if (!_isValidRelayUri(relay)) return;

    try {
      await insertRelay(relayUri: relay);
      _controller.clear();
      _onInputChanged('');
      _fetchRelays();
    } catch (e) {
      AppLogger.instance.error("Could not add relay: $e");
      ToastService().show(
        message: "Could not add relay",
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
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
            ToastService().show(
              message: "Could not delete relay",
              duration: const Duration(seconds: 5),
              onTap: () {},
              icon: Icon(Icons.error),
            );
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
              "ecashapp uses Nostr relays to back up which federations you have joined. You can customize them below.",
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  OutlineInputBorder _inputBorder(Color color) {
    return OutlineInputBorder(borderSide: BorderSide(color: color));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Color borderColor;
    if (_inputText.isEmpty) {
      borderColor = Colors.transparent;
    } else {
      borderColor = _isInputValid ? Colors.greenAccent : Colors.redAccent;
    }

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
                    onChanged: _onInputChanged,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'wss://example.com',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: const Color(0xFF111111),
                      border: _inputBorder(borderColor),
                      enabledBorder: _inputBorder(borderColor),
                      focusedBorder: _inputBorder(borderColor),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _isInputValid ? _addRelay : null,
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
