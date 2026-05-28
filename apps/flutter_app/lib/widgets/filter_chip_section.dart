import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class FilterChipSection extends StatelessWidget {
  const FilterChipSection({
    super.key,
    required this.items,
    required this.allLabel,
    required this.selectedValue,
    required this.onSelected,
    this.singleLine = false,
    this.maxVisible = 999,
    this.bottomSheetTitle,
  });

  final List<String> items;
  final String allLabel;
  final String? selectedValue;
  final ValueChanged<String?> onSelected;
  final bool singleLine;
  final int maxVisible;
  final String? bottomSheetTitle;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    final platform = Theme.of(context).platform;
    final isIOS = platform == TargetPlatform.iOS;
    final isApple = isIOS || platform == TargetPlatform.macOS;
    if (singleLine) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final labelStyle =
              Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 12) ??
                  const TextStyle(fontSize: 12);
          final chips = _buildSingleLineWidgets(
            context,
            items,
            maxWidth: constraints.maxWidth,
            labelStyle: labelStyle,
            spacing: 15,
            maxVisible: maxVisible,
          );
          return SizedBox(
            height: 34,
            child: Row(children: _withSpacing(chips, 15)),
          );
        },
      );
    }
    if (isApple) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _buildAppleWidgets(context, items),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _buildChoiceChip(context, allLabel, selectedValue == null, () {
          onSelected(null);
        }),
        ...items.take(maxVisible).map((item) {
          return _buildChoiceChip(context, item, selectedValue == item, () {
            onSelected(item);
          });
        }),
        if (items.length > maxVisible)
          ActionChip(
            label: Text('...+${items.length - maxVisible}'),
            onPressed: () => _showAll(context, items),
            labelStyle: const TextStyle(fontSize: 12),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          ),
      ],
    );
  }

  List<Widget> _buildAppleWidgets(BuildContext context, List<String> items) {
    const maxVisible = 3;
    final visible = items.take(maxVisible).toList();
    final remaining = items.length - visible.length;
    return [
      _buildChoiceChip(context, allLabel, selectedValue == null, () {
        onSelected(null);
      }),
      ...visible.map((item) {
        return _buildChoiceChip(context, item, selectedValue == item, () {
          onSelected(item);
        });
      }),
      if (remaining > 0)
        ActionChip(
          label: Text('...+$remaining'),
          onPressed: () => _showAll(context, items),
          labelStyle: const TextStyle(fontSize: 12),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        ),
    ];
  }

  List<Widget> _buildSingleLineWidgets(
    BuildContext context,
    List<String> items, {
    required double maxWidth,
    required TextStyle labelStyle,
    required double spacing,
    int maxVisible = 999,
  }) {
    final chips = <Widget>[];
    var usedWidth = 0.0;
    const chipPadding = EdgeInsets.symmetric(horizontal: 8, vertical: 2);
    final defaultFontSize = labelStyle.fontSize ?? 14.0;
    final effectiveTextScale =
        MediaQuery.textScalerOf(context).scale(defaultFontSize) / 14.0;
    final defaultLabelPadding = EdgeInsets.lerp(
      const EdgeInsets.symmetric(horizontal: 8.0),
      const EdgeInsets.symmetric(horizontal: 4.0),
      clampDouble(effectiveTextScale - 1.0, 0.0, 1.0),
    )!;
    final chipLabelPadding =
        (ChipTheme.of(context).labelPadding ?? defaultLabelPadding)
            .resolve(Directionality.of(context));
    const checkmarkSize = 18.0;
    const checkmarkGap = 4.0;

    double chipWidth(String text, {required bool selected}) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout();
      final checkmarkWidth = selected ? (checkmarkSize + checkmarkGap) : 0.0;
      return painter.width +
          chipPadding.horizontal +
          chipLabelPadding.horizontal +
          checkmarkWidth +
          2;
    }

    Widget buildChip(String text, bool selected, VoidCallback onTap) {
      return ChoiceChip(
        label: Text(text, overflow: TextOverflow.ellipsis),
        selected: selected,
        onSelected: (_) => onTap(),
        labelStyle: labelStyle,
        padding: chipPadding,
        labelPadding: chipLabelPadding,
      );
    }

    final allWidth = chipWidth(allLabel, selected: selectedValue == null);
    usedWidth += allWidth;
    chips.add(
      buildChip(allLabel, selectedValue == null, () {
        onSelected(null);
      }),
    );

    final displayItems = items.take(maxVisible).toList();
    var visible = 0;
    for (final item in displayItems) {
      final width = chipWidth(item, selected: selectedValue == item);
      if (usedWidth + spacing + width > maxWidth) {
        break;
      }
      usedWidth += spacing + width;
      visible += 1;
      chips.add(
        buildChip(item, selectedValue == item, () {
          onSelected(item);
        }),
      );
    }

    final remaining = items.length - visible;
    if (remaining > 0) {
      final overflowText = '...+$remaining';
      final overflowWidth = chipWidth(overflowText, selected: false);
      while (
          chips.length > 1 && usedWidth + spacing + overflowWidth > maxWidth) {
        final removedItem = displayItems[visible - 1];
        usedWidth -= spacing +
            chipWidth(
              removedItem,
              selected: selectedValue == removedItem,
            );
        chips.removeLast();
        visible -= 1;
      }
      if (usedWidth + spacing + overflowWidth <= maxWidth) {
        chips.add(
          ActionChip(
            label: Text(overflowText, overflow: TextOverflow.ellipsis),
            onPressed: () => _showAll(context, items),
            labelStyle: labelStyle,
            padding: chipPadding,
            labelPadding: chipLabelPadding,
          ),
        );
      }
    }
    return chips;
  }

  List<Widget> _withSpacing(List<Widget> items, double spacing) {
    if (items.isEmpty) {
      return items;
    }
    final spaced = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      spaced.add(items[i]);
      if (i != items.length - 1) {
        spaced.add(SizedBox(width: spacing));
      }
    }
    return spaced;
  }

  ChoiceChip _buildChoiceChip(
    BuildContext context,
    String label,
    bool selected,
    VoidCallback onTap,
  ) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      labelStyle: const TextStyle(fontSize: 12),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    );
  }

  Future<void> _showAll(BuildContext context, List<String> items) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              bottomSheetTitle ?? allLabel,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: items.length + 1,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return ListTile(
                      title: Text(allLabel),
                      trailing: selectedValue == null
                          ? Icon(
                              Icons.check_rounded,
                              color: Theme.of(context).colorScheme.primary,
                            )
                          : null,
                      onTap: () {
                        onSelected(null);
                        Navigator.of(context).pop();
                      },
                    );
                  }
                  final item = items[index - 1];
                  final selected = selectedValue == item;
                  return ListTile(
                    title: Text(item),
                    trailing: selected
                        ? Icon(
                            Icons.check_rounded,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : null,
                    onTap: () {
                      onSelected(item);
                      Navigator.of(context).pop();
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
