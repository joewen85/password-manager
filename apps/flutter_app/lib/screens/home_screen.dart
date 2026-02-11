import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:password_manager_core/password_manager_core.dart';

import '../models/new_entry_data.dart';
import '../state/vault_metadata.dart';
import '../state/vault_controller.dart';
import '../utils/export_file.dart';
import '../widgets/entry_details_dialog.dart';
import 'new_entry_sheet.dart';
import 'sync_settings_screen.dart';
import 'tag_management_screen.dart';
import 'new_server_sheet.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final VaultController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _searchController = TextEditingController();
  final _fabKey = GlobalKey();
  _VaultListMode _mode = _VaultListMode.credentials;
  String? _selectedTag;
  Size _fabSize = Size.zero;

  void _syncFabSize() {
    final context = _fabKey.currentContext;
    if (context == null) {
      return;
    }
    final renderBox = context.findRenderObject() as RenderBox?;
    final size = renderBox?.size ?? Size.zero;
    if (!mounted) {
      return;
    }
    if (size.height > 0 &&
        ((size.height - _fabSize.height).abs() > 0.5 ||
            (size.width - _fabSize.width).abs() > 0.5)) {
      setState(() => _fabSize = size);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _editEntry(VaultItem item) async {
    if (item.type == VaultEntryType.server) {
      final payload = await widget.controller.readServerAsset(item);
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
      final data = await showModalBottomSheet<NewServerSheetResult>(
        context: context,
        isScrollControlled: true,
        builder: (context) => NewServerSheet(
          initialData: NewServerSheetResult(
            label: item.label,
            payload: payload,
          ),
          title: '编辑服务器',
          submitLabel: '保存修改',
        ),
      );
      if (data != null) {
        await widget.controller.updateServerAsset(
          item: item,
          label: data.label,
          payload: data.payload,
        );
      }
      return;
    }
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

  Widget _tagFilterRow() {
    final tags = widget.controller.metadata.tags;
    if (tags.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ChoiceChip(
          label: const Text('全部'),
          selected: _selectedTag == null,
          onSelected: (_) => setState(() => _selectedTag = null),
        ),
        ...tags.map(
          (tag) => ChoiceChip(
            label: Text(tag),
            selected: _selectedTag == tag,
            onSelected: (_) => setState(() => _selectedTag = tag),
          ),
        ),
      ],
    );
  }

  List<VaultEntryView> _sortViews(List<VaultEntryView> views) {
    final sorted = [...views];
    switch (widget.controller.metadata.sortOrder) {
      case VaultSortOrder.updatedDesc:
        sorted.sort((a, b) => b.item.updatedAt.compareTo(a.item.updatedAt));
        break;
      case VaultSortOrder.labelAsc:
        sorted.sort((a, b) => a.item.label.compareTo(b.item.label));
        break;
    }
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncFabSize());
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
                case _VaultMenuAction.tags:
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => TagManagementScreen(
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
                value: _VaultMenuAction.tags,
                child: Text('分类管理'),
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
        key: _fabKey,
        onPressed: () async {
          if (_mode == _VaultListMode.credentials) {
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
          } else {
            final data = await showModalBottomSheet<NewServerSheetResult>(
              context: context,
              isScrollControlled: true,
              builder: (context) => const NewServerSheet(),
            );
            if (data != null) {
              await widget.controller.addServerAsset(
                label: data.label,
                payload: data.payload,
              );
            }
          }
        },
        icon: const Icon(Icons.add),
        label: Text(_mode == _VaultListMode.credentials ? '新建账号' : '新建服务器'),
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
                Row(
                  children: [
                    SegmentedButton<_VaultListMode>(
                      segments: const [
                        ButtonSegment(
                          value: _VaultListMode.credentials,
                          label: Text('账号'),
                        ),
                        ButtonSegment(
                          value: _VaultListMode.servers,
                          label: Text('服务器'),
                        ),
                      ],
                      selected: {_mode},
                      onSelectionChanged: (value) {
                        setState(() => _mode = value.first);
                      },
                    ),
                    const Spacer(),
                    DropdownButton<VaultSortOrder>(
                      value: widget.controller.metadata.sortOrder,
                      onChanged: (value) async {
                        if (value == null) {
                          return;
                        }
                        await widget.controller.updateSortOrder(value);
                      },
                      items: const [
                        DropdownMenuItem(
                          value: VaultSortOrder.updatedDesc,
                          child: Text('按更新时间'),
                        ),
                        DropdownMenuItem(
                          value: VaultSortOrder.labelAsc,
                          child: Text('按名称'),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
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
                const SizedBox(height: 12),
                _tagFilterRow(),
                const SizedBox(height: 16),
                Expanded(
                  child: AnimatedBuilder(
                    animation: widget.controller,
                    builder: (context, _) {
                      final views = widget.controller.entryViews;
                      final query = _searchController.text.trim().toLowerCase();
                      final filtered = views.where((view) {
                        final matchesType = _mode == _VaultListMode.credentials
                            ? view.item.type == VaultEntryType.credential
                            : view.item.type == VaultEntryType.server;
                        if (!matchesType) {
                          return false;
                        }
                        final matchesQuery = query.isEmpty
                            ? true
                            : view.item.label.toLowerCase().contains(query) ||
                                view.tags
                                    .any((tag) => tag.toLowerCase().contains(query));
                        if (!matchesQuery) {
                          return false;
                        }
                        if (_selectedTag == null || _selectedTag!.isEmpty) {
                          return true;
                        }
                        return view.tags.contains(_selectedTag);
                      }).toList();
                      final sorted = _sortViews(filtered);
                      if (sorted.isEmpty) {
                        return Center(
                          child: Text(
                            query.isEmpty
                                ? '暂无条目，点击“新建”添加。'
                                : '未找到匹配条目',
                          ),
                        );
                      }
                      final mediaPadding = MediaQuery.of(context).padding;
                      final fabHeight =
                          _fabSize.height > 0 ? _fabSize.height : 56.0;
                      final fabWidth =
                          _fabSize.width > 0 ? _fabSize.width : 120.0;
                      final bottomPadding = mediaPadding.bottom +
                          fabHeight +
                          kFloatingActionButtonMargin +
                          8;
                      final rightPadding = mediaPadding.right +
                          fabWidth +
                          kFloatingActionButtonMargin +
                          8;
                      return ListView.separated(
                        padding: EdgeInsets.only(
                          bottom: bottomPadding,
                          right: rightPadding,
                        ),
                        itemCount: sorted.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final view = sorted[index];
                          final item = view.item;
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

enum _VaultMenuAction { syncSettings, tags, export, clear }

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

enum _VaultListMode { credentials, servers }
