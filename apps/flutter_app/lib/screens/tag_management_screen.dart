import 'package:flutter/material.dart';

import '../state/vault_controller.dart';

class TagManagementScreen extends StatelessWidget {
  const TagManagementScreen({super.key, required this.controller});

  final VaultController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('标签管理'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createTag(context),
        icon: const Icon(Icons.add),
        label: const Text('新建标签'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                final tags = controller.metadata.tags;
                if (tags.isEmpty) {
                  return const Center(child: Text('暂无标签'));
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: tags.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final tag = tags[index];
                    return Card(
                      child: ListTile(
                        title: Text(tag),
                        trailing: Wrap(
                          children: [
                            IconButton(
                              tooltip: '编辑',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _renameTag(context, tag),
                            ),
                            IconButton(
                              tooltip: '删除',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _deleteTag(context, tag),
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

  Future<void> _createTag(BuildContext context) async {
    final controllerText = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建标签'),
        content: TextField(
          controller: controllerText,
          decoration: const InputDecoration(hintText: '例如：生产环境'),
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
    await controller.addTag(result);
  }

  Future<void> _renameTag(BuildContext context, String tag) async {
    final controllerText = TextEditingController(text: tag);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑标签'),
        content: TextField(
          controller: controllerText,
          decoration: const InputDecoration(),
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
    if (result == null || result.trim().isEmpty || result == tag) {
      return;
    }
    await controller.renameTag(tag, result);
  }

  Future<void> _deleteTag(BuildContext context, String tag) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除标签'),
        content: Text('确认删除“$tag”吗？该标签会从所有条目中移除。'),
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
      await controller.deleteTag(tag);
    }
  }
}
