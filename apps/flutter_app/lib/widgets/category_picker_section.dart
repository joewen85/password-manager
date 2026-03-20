import 'package:flutter/material.dart';

class CategoryPickerSection extends StatelessWidget {
  const CategoryPickerSection({
    super.key,
    required this.availableCategories,
    required this.selectedCategory,
    required this.onChanged,
  });

  final List<String> availableCategories;
  final String selectedCategory;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final categories = <String>{
      ...availableCategories,
      if (selectedCategory.trim().isNotEmpty) selectedCategory.trim(),
    }.toList()
      ..sort();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: DropdownButtonFormField<String>(
            initialValue: selectedCategory.isEmpty ? '' : selectedCategory,
            decoration: const InputDecoration(
              labelText: '分类',
              hintText: '选择自定义分类',
            ),
            items: [
              const DropdownMenuItem<String>(
                value: '',
                child: Text('未分类'),
              ),
              ...categories.map(
                (category) => DropdownMenuItem<String>(
                  value: category,
                  child: Text(category),
                ),
              ),
            ],
            onChanged: (value) => onChanged(value ?? ''),
          ),
        ),
        if (categories.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('未分类'),
                  selected: selectedCategory.isEmpty,
                  onSelected: (_) => onChanged(''),
                  labelStyle: const TextStyle(fontSize: 12),
                ),
                ...categories.map(
                  (category) => ChoiceChip(
                    label: Text(category),
                    selected: selectedCategory == category,
                    onSelected: (_) => onChanged(category),
                    labelStyle: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
