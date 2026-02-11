import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:password_manager_core/password_manager_core.dart';

import '../models/new_entry_data.dart';
import '../state/vault_controller.dart';
import '../utils/export_file.dart';
import '../widgets/entry_details_dialog.dart';
import 'new_entry_sheet.dart';
import 'sync_settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final VaultController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _editEntry(VaultItem item) async {
    final payload = await widget.controller.readEntry(item);
    if (payload == null) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法解密条目')),
      );
      return;
    }
    if (!mounted) {
      return;
    }
    final data = await showModalBottomSheet<NewEntryData>(
      context: context,
      isScrollControlled: true,
      builder: (context) => NewEntrySheet(
        initialData: NewEntryData(label: item.label, payload: payload),
        title: '编辑条目',
        submitLabel: '保存修改',
      ),
    );
    if (data != null) {
      await widget.controller.updateEntry(
        item: item,
        label: data.label,
        payload: data.payload,
      );
    }
  }

  Future<void> _deleteEntry(VaultItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除条目'),
        content: Text('确定删除“${item.label}”吗？'),
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
      await widget.controller.deleteEntry(item.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已删除')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('密码库'),
        actions: [
          IconButton(
            onPressed: widget.controller.syncNow,
            icon: const Icon(Icons.sync),
            tooltip: '同步',
          ),
          IconButton(
            onPressed: widget.controller.runBackup,
            icon: const Icon(Icons.backup_outlined),
            tooltip: '备份',
          ),
          PopupMenuButton<_VaultMenuAction>(
            tooltip: '更多',
            onSelected: (action) async {
              switch (action) {
                case _VaultMenuAction.syncSettings:
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SyncSettingsScreen(
                        controller: widget.controller,
                      ),
                    ),
                  );
                  break;
                case _VaultMenuAction.export:
                  final data = await widget.controller.exportEncryptedData();
                  final filename =
                      'vault-export-${DateTime.now().toIso8601String()}.json';
                  if (kIsWeb) {
                    await downloadTextFile(
                      filename: filename,
                      contents: data,
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('导出完成')),
                    );
                  } else {
                    await showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('导出数据'),
                        content: SizedBox(
                          width: 480,
                          child: SingleChildScrollView(
                            child: SelectableText(data),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: data),
                              );
                              Navigator.of(context).pop();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已复制')),
                              );
                            },
                            child: const Text('复制'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    );
                  }
                  break;
                case _VaultMenuAction.clear:
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('清空数据'),
                      content: const Text('此操作会删除所有条目，是否继续？'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('确认清空'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await widget.controller.clearAllEntries();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已清空')),
                    );
                  }
                  break;
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _VaultMenuAction.syncSettings,
                child: Text('同步设置'),
              ),
              PopupMenuItem(
                value: _VaultMenuAction.export,
                child: Text('导出数据'),
              ),
              PopupMenuItem(
                value: _VaultMenuAction.clear,
                child: Text('清空数据'),
              ),
            ],
          ),
          IconButton(
            onPressed: widget.controller.lock,
            icon: const Icon(Icons.lock_outline),
            tooltip: '锁定',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final data = await showModalBottomSheet<NewEntryData>(
            context: context,
            isScrollControlled: true,
            builder: (context) => const NewEntrySheet(),
          );
          if (data != null) {
            await widget.controller.addEntry(
              label: data.label,
              payload: data.payload,
            );
          }
        },
        icon: const Icon(Icons.add),
        label: const Text('新建条目'),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF6F6F2), Color(0xFFE8F1F2)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '安全地保存账号信息',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  'AES-256 加密，支持 2FA 与同步模块。',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: '按条目名称搜索',
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: AnimatedBuilder(
                    animation: widget.controller,
                    builder: (context, _) {
                      final items = widget.controller.items;
                      final query = _searchController.text.trim().toLowerCase();
                      final filtered = query.isEmpty
                          ? items
                          : items
                              .where(
                                (item) =>
                                    item.label.toLowerCase().contains(query),
                              )
                              .toList();
                      if (filtered.isEmpty) {
                        return Center(
                          child: Text(
                            query.isEmpty
                                ? '暂无条目，点击“新建条目”添加。'
                                : '未找到匹配条目',
                          ),
                        );
                      }
                      return ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final item = filtered[index];
                          return EntryCard(
                            item: item,
                            onView: () {
                              showDialog<void>(
                                context: context,
                                builder: (context) => EntryDetailsDialog(
                                  controller: widget.controller,
                                  item: item,
                                ),
                              );
                            },
                            onEdit: () => _editEntry(item),
                            onDelete: () => _deleteEntry(item),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _VaultMenuAction { syncSettings, export, clear }

class EntryCard extends StatelessWidget {
  const EntryCard({
    super.key,
    required this.item,
    required this.onView,
    required this.onEdit,
    required this.onDelete,
  });

  final VaultItem item;
  final VoidCallback onView;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        title: Text(item.label),
        subtitle: Text('更新于 ${item.updatedAt.toLocal()}'),
        onTap: onView,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: '编辑',
              onPressed: onEdit,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
