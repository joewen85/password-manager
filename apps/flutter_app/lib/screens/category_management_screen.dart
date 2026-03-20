import 'package:flutter/material.dart';

import '../state/vault_controller.dart';

class CategoryManagementScreen extends StatelessWidget {
  const CategoryManagementScreen({
    super.key,
    required this.controller,
  });

  final VaultController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('分类管理'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createCategory(context),
        icon: const Icon(Icons.add),
        label: const Text('新建分类'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                final categories = controller.metadata.categories;
                if (categories.isEmpty) {
                  return const Center(child: Text('暂无分类'));
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: categories.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final category = categories[index];
                    return Card(
                      child: ListTile(
                        title: Text(category),
                        trailing: Wrap(
                          children: [
                            IconButton(
                              tooltip: '编辑',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () =>
                                  _renameCategory(context, category),
                            ),
                            IconButton(
                              tooltip: '删除',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () =>
                                  _deleteCategory(context, category),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _createCategory(BuildContext context) async {
    final controllerText = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建分类'),
        content: TextField(
          controller: controllerText,
          decoration: const InputDecoration(hintText: '例如：云平台'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controllerText.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null) {
      return;
    }
    await controller.addCategory(result);
  }

  Future<void> _renameCategory(BuildContext context, String category) async {
    final controllerText = TextEditingController(text: category);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑分类'),
        content: TextField(
          controller: controllerText,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controllerText.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null || result.trim().isEmpty || result == category) {
      return;
    }
    await controller.renameCategory(category, result);
  }

  Future<void> _deleteCategory(BuildContext context, String category) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除分类'),
        content: Text('确认删除“$category”吗？已绑定条目会变为未分类。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.deleteCategory(category);
    }
  }
}
