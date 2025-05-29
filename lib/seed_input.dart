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

class _SeedPhraseInputState extends State<SeedPhraseInput> {
  late final List<TextEditingController> controllers;
  late final List<FocusNode> focusNodes;

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
  }

  @override
  void dispose() {
    for (final c in controllers) {
      c.dispose();
    }
    for (final f in focusNodes) {
      f.dispose();
    }
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
                    crossAxisCount: 3,
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
                                if (value.text.isEmpty)
                                  return const Iterable<String>.empty();
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
            ],
          ),
        ),
      ),
    );
  }
}
