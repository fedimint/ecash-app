import 'package:ecashapp/lib.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';

class SeedPhraseInput extends StatefulWidget {
  final void Function(List<String> words) onConfirm;
  final List<String> validWords;

  const SeedPhraseInput({
    super.key,
    required this.onConfirm,
    required this.validWords,
  });

  @override
  State<SeedPhraseInput> createState() => _SeedPhraseInputState();
}

class _SeedPhraseInputState extends State<SeedPhraseInput>
    with SingleTickerProviderStateMixin {
  late final List<TextEditingController> controllers;
  late final List<FocusNode> focusNodes;

  bool _showAdvanced = false;

  final TextEditingController _controller = TextEditingController();
  bool _isInputValid = false;
  String _inputText = '';

  late AnimationController _successAnimationController;
  late Animation<double> _successScaleAnimation;
  bool _showSuccessAnimation = false;

  @override
  void initState() {
    super.initState();
    controllers = List.generate(12, (index) {
      final controller = TextEditingController();
      controller.addListener(() {
        setState(() {}); // Update UI on input changes
      });
      return controller;
    });

    focusNodes = List.generate(12, (_) => FocusNode());

    _successAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _successScaleAnimation = CurvedAnimation(
      parent: _successAnimationController,
      curve: Curves.easeOutBack,
    );
  }

  @override
  void dispose() {
    for (final c in controllers) {
      c.dispose();
    }
    for (final f in focusNodes) {
      f.dispose();
    }
    _successAnimationController.dispose();
    super.dispose();
  }

  bool get isValidSeed {
    return controllers.every((c) {
      final word = c.text.trim().toLowerCase();
      return word.isNotEmpty && widget.validWords.contains(word);
    });
  }

  Color getBorderColor(int index, ThemeData theme) {
    final word = controllers[index].text.trim().toLowerCase();
    if (word.isEmpty) {
      return theme.colorScheme.primary.withOpacity(0.3);
    } else if (!widget.validWords.contains(word)) {
      return Colors.red;
    } else {
      return theme.colorScheme.primary;
    }
  }

  double getBorderWidth(int index) {
    final word = controllers[index].text.trim().toLowerCase();
    if (word.isEmpty) return 1;
    if (!widget.validWords.contains(word)) return 2;
    return 2.5;
  }

  void _onInputChanged(String value) {
    setState(() {
      _inputText = value.trim();
      _isInputValid = isValidRelayUri(_inputText);
    });
  }

  OutlineInputBorder _inputBorder(Color color) {
    return OutlineInputBorder(borderSide: BorderSide(color: color));
  }

  Future<void> _onAddRelay() async {
    final relay = _controller.text.trim();
    try {
      await addRecoveryRelay(relay: relay);
      AppLogger.instance.info("Successfully added relay");

      // Trigger animation
      setState(() {
        _showSuccessAnimation = true;
        _controller.text = "";
      });
      _successAnimationController.forward(from: 0);

      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        setState(() {
          _showSuccessAnimation = false;
        });
      }
    } catch (e) {
      AppLogger.instance.error("Could not add recovery relay: $e");
    }
  }

  Widget _buildAdvancedSection() {
    final theme = Theme.of(context);
    Color borderColor;
    if (_inputText.isEmpty) {
      borderColor = Colors.transparent;
    } else {
      borderColor =
          _isInputValid ? theme.colorScheme.primary : Colors.redAccent;
    }

    final header = Row(
      children: [
        Image.asset('assets/images/nostr.png', width: 48, height: 48),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            "Did you backup your joined federations to a specific Nostr relay? Add it here",
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          header,
          Row(
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
              SizedBox(
                height: 48, // match button height
                width: 120, // match button width
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder:
                      (child, animation) =>
                          FadeTransition(opacity: animation, child: child),
                  child:
                      _showSuccessAnimation
                          ? ScaleTransition(
                            scale: _successScaleAnimation,
                            child: const Icon(
                              Icons.check_circle,
                              color: Colors.greenAccent,
                              size: 32,
                            ),
                          )
                          : ElevatedButton(
                            key: const ValueKey('addRelayButton'),
                            onPressed: _isInputValid ? _onAddRelay : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor:
                                  Theme.of(context).colorScheme.primary,
                              foregroundColor: Colors.black,
                            ),
                            child: const Text('Add Relay'),
                          ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Enter Seed Phrase')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 16),
              Text(
                'Enter your 12-word recovery phrase',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Expanded(
                child: GridView.builder(
                  itemCount: 12,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 3.5,
                  ),
                  itemBuilder: (context, index) {
                    final controller = controllers[index];
                    final focusNode = focusNodes[index];

                    return Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: getBorderColor(index, theme),
                          width: getBorderWidth(index),
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          Text(
                            '${index + 1}.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: RawAutocomplete<String>(
                              textEditingController: controller,
                              focusNode: focusNode,
                              optionsBuilder: (TextEditingValue value) {
                                if (value.text.isEmpty) {
                                  return const Iterable<String>.empty();
                                }
                                return widget.validWords.where(
                                  (word) =>
                                      word.startsWith(value.text.toLowerCase()),
                                );
                              },
                              fieldViewBuilder: (
                                context,
                                textFieldController,
                                focusNode,
                                onFieldSubmitted,
                              ) {
                                return TextFormField(
                                  controller: textFieldController,
                                  focusNode: focusNode,
                                  onFieldSubmitted: (_) => onFieldSubmitted(),
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: Colors.white,
                                  ),
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    isDense: true,
                                    hintText: 'word',
                                    hintStyle: TextStyle(color: Colors.white38),
                                  ),
                                );
                              },
                              optionsViewBuilder: (
                                context,
                                onSelected,
                                options,
                              ) {
                                return Align(
                                  alignment: Alignment.topLeft,
                                  child: Material(
                                    color: theme.colorScheme.surface,
                                    elevation: 4,
                                    child: ListView(
                                      padding: EdgeInsets.zero,
                                      shrinkWrap: true,
                                      children:
                                          options.map((option) {
                                            return ListTile(
                                              title: Text(
                                                option,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                ),
                                              ),
                                              onTap: () => onSelected(option),
                                            );
                                          }).toList(),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Confirm'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor:
                        isValidSeed
                            ? theme.colorScheme.primary
                            : theme.colorScheme.primary.withOpacity(0.3),
                    foregroundColor:
                        isValidSeed ? Colors.black : Colors.black45,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed:
                      isValidSeed
                          ? () {
                            final words =
                                controllers.map((c) => c.text.trim()).toList();
                            widget.onConfirm(words);
                          }
                          : null,
                ),
              ),

              const SizedBox(height: 16),
              GestureDetector(
                onTap: () {
                  setState(() {
                    _showAdvanced = !_showAdvanced;
                  });
                  if (!_showAdvanced) return;
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('Advanced'),
                    Icon(
                      _showAdvanced
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                    ),
                  ],
                ),
              ),
              if (_showAdvanced) _buildAdvancedSection(),
            ],
          ),
        ),
      ),
    );
  }
}
