import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:password_manager_core/password_manager_core.dart';

import '../models/new_entry_data.dart';
import '../state/vault_metadata.dart';
import '../state/vault_controller.dart';
import '../utils/export_file.dart';
import '../widgets/app_background.dart';
import '../widgets/entry_details_dialog.dart';
import '../widgets/fade_slide.dart';
import '../widgets/glass_surface.dart';
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
  _VaultListMode _mode = _VaultListMode.credentials;
  String? _selectedTag;
  bool _showConflictsOnly = false;

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

  Future<void> _openCreateSheet() async {
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
      return;
    }
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

  Widget _buildCreateButton(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final platform = Theme.of(context).platform;
    final isIOS = platform == TargetPlatform.iOS;
    final isMac = platform == TargetPlatform.macOS;
    final label = _mode == _VaultListMode.credentials ? '新建账号' : '新建服务器';
    final padding = isMac
        ? const EdgeInsets.symmetric(horizontal: 13, vertical: 7)
        : const EdgeInsets.symmetric(horizontal: 13, vertical: 7);
    final radius = isMac ? 10.0 : 14.0;
    final isGlass = isIOS || isMac;
    final content = Padding(
      padding: padding,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.add_rounded,
            color: isGlass ? colorScheme.onSurface : colorScheme.onPrimary,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: isGlass ? colorScheme.onSurface : colorScheme.onPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: isIOS ? 12 : 12,
                ),
          ),
        ],
      ),
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _openCreateSheet,
        borderRadius: BorderRadius.circular(radius),
        child: isGlass
            ? GlassSurface(
                borderRadius: radius,
                padding: EdgeInsets.zero,
                tint: colorScheme.primary.withOpacity(0.22),
                child: content,
              )
            : Ink(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      colorScheme.primary,
                      colorScheme.secondary,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(radius),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(
                        Theme.of(context).brightness == Brightness.dark
                            ? 0.4
                            : 0.15,
                      ),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: content,
              ),
      ),
    );
  }

  Widget _tagFilterRow() {
    final tags = widget.controller.metadata.tags;
    if (tags.isEmpty) {
      return const SizedBox.shrink();
    }
    final platform = Theme.of(context).platform;
    final isApple = platform == TargetPlatform.iOS ||
        platform == TargetPlatform.macOS;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ChoiceChip(
          label: const Text('全部'),
          selected: _selectedTag == null,
          onSelected: (_) => setState(() => _selectedTag = null),
          labelStyle: const TextStyle(fontSize: 12),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        ),
        ...isApple
            ? _buildSingleLineTags(tags)
            : tags.map(
                (tag) => ChoiceChip(
                  label: Text(tag),
                  selected: _selectedTag == tag,
                  onSelected: (_) => setState(() => _selectedTag = tag),
                  labelStyle: const TextStyle(fontSize: 12),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                ),
              ),
      ],
    );
  }

  List<Widget> _buildSingleLineTags(List<String> tags) {
    const maxVisible = 3;
    final visible = tags.take(maxVisible).toList();
    final remaining = tags.length - visible.length;
    return [
      ...visible.map(
        (tag) => ChoiceChip(
          label: Text(tag),
          selected: _selectedTag == tag,
          onSelected: (_) => setState(() => _selectedTag = tag),
          labelStyle: const TextStyle(fontSize: 12),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        ),
      ),
      if (remaining > 0)
        ActionChip(
          label: Text('...+$remaining'),
          onPressed: () => _showAllTags(tags),
          labelStyle: const TextStyle(fontSize: 12),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        ),
    ];
  }

  Future<void> _showAllTags(List<String> tags) async {
    if (!mounted) {
      return;
    }
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
            const Text(
              '全部分类标签',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: tags.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final tag = tags[index];
                  final selected = _selectedTag == tag;
                  return ListTile(
                    title: Text(tag),
                    trailing: selected
                        ? Icon(
                            Icons.check_rounded,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : null,
                    onTap: () {
                      setState(() => _selectedTag = tag);
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

  Widget _infoPill(IconData icon, String label) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: (isDark ? Colors.black : Colors.white).withOpacity(0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: (isDark ? Colors.white : Colors.white).withOpacity(0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({required Widget child}) {
    return GlassSurface(
      borderRadius: 20,
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }

  Widget _heroCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? const [Color(0xFF11343C), Color(0xFF0B2C31)]
              : const [Color(0xFF0F4C5C), Color(0xFF1B7F6E)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.4 : 0.12),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final baseStyle =
                  Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      );
              final isNarrow = constraints.maxWidth < 340;
              final scaledStyle = isNarrow && baseStyle?.fontSize != null
                  ? baseStyle!.copyWith(fontSize: baseStyle.fontSize! * 0.9)
                  : baseStyle;
              return Text(
                '安全地保存账号信息',
                style: scaledStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _infoPill(Icons.shield_outlined, 'AES-256'),
              _infoPill(Icons.phonelink_lock_outlined, '多端同步'),
              _infoPill(Icons.verified_user_outlined, '2FA 保护'),
            ],
          ),
        ],
      ),
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
      bottomNavigationBar: SafeArea(
        minimum: EdgeInsets.fromLTRB(
          16,
          Theme.of(context).platform == TargetPlatform.iOS ? 4 : 5,
          16,
          Theme.of(context).platform == TargetPlatform.iOS ? 5 : 7,
        ),
        child: Row(
          children: [
            const Spacer(),
            _buildCreateButton(context),
          ],
        ),
      ),
      body: AppBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FadeSlide(
                  delay: const Duration(milliseconds: 60),
                  child: _heroCard(context),
                ),
                const SizedBox(height: 16),
                FadeSlide(
                  delay: const Duration(milliseconds: 140),
                  child: _sectionCard(
                    child: Theme(
                      data: Theme.of(context).copyWith(
                        inputDecorationTheme:
                            Theme.of(context).inputDecorationTheme.copyWith(
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                ),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              SegmentedButton<_VaultListMode>(
                                style: ButtonStyle(
                                  padding: const WidgetStatePropertyAll(
                                    EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                  ),
                                  textStyle: const WidgetStatePropertyAll(
                                    TextStyle(fontSize: 12),
                                  ),
                                ),
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
                              const SizedBox(width: 8),
                              if (widget.controller.hasConflicts)
                                FilterChip(
                                  label: const Text('仅冲突'),
                                  selected: _showConflictsOnly,
                                  onSelected: (value) {
                                    setState(() => _showConflictsOnly = value);
                                  },
                                  labelStyle: const TextStyle(fontSize: 12),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                ),
                              const Spacer(),
                              DropdownButtonHideUnderline(
                                child: DropdownButton<VaultSortOrder>(
                                  value: widget.controller.metadata.sortOrder,
                                  borderRadius: BorderRadius.circular(12),
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall,
                                  onChanged: (value) async {
                                    if (value == null) {
                                      return;
                                    }
                                    await widget.controller.updateSortOrder(
                                      value,
                                    );
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
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _searchController,
                            onChanged: (_) => setState(() {}),
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      fontSize: 12,
                                    ),
                            decoration: const InputDecoration(
                              prefixIcon: Icon(Icons.search, size: 18),
                              hintText: '按名称或标签搜索',
                            ),
                          ),
                          const SizedBox(height: 10),
                          _tagFilterRow(),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: FadeSlide(
                    delay: const Duration(milliseconds: 220),
                    child: AnimatedBuilder(
                      animation: widget.controller,
                      builder: (context, _) {
                        final views = widget.controller.entryViews;
                        final query = _searchController.text.trim().toLowerCase();
                          final filtered = views.where((view) {
                            final matchesType =
                                _mode == _VaultListMode.credentials
                                    ? view.item.type ==
                                        VaultEntryType.credential
                                    : view.item.type == VaultEntryType.server;
                            if (!matchesType) {
                              return false;
                            }
                            if (_showConflictsOnly && !view.isConflict) {
                              return false;
                            }
                            final matchesQuery = query.isEmpty
                                ? true
                                : view.item.label
                                      .toLowerCase()
                                      .contains(query) ||
                                  view.tags.any(
                                    (tag) =>
                                        tag.toLowerCase().contains(query),
                                  );
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
                        return ListView.separated(
                          padding: EdgeInsets.only(
                            bottom: MediaQuery.of(context).padding.bottom + 12,
                          ),
                          itemCount: sorted.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final view = sorted[index];
                            final item = view.item;
                            return EntryCard(
                              item: item,
                              tags: view.tags,
                              isConflict: view.isConflict,
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
    required this.tags,
    required this.isConflict,
    required this.onView,
    required this.onEdit,
    required this.onDelete,
  });

  final VaultItem item;
  final List<String> tags;
  final bool isConflict;
  final VoidCallback onView;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final icon = item.type == VaultEntryType.server
        ? Icons.dns_rounded
        : Icons.key_rounded;
    final accent = item.type == VaultEntryType.server
        ? colorScheme.tertiary
        : colorScheme.secondary;
    final visibleTags = tags.take(3).toList();
    final remaining = tags.length - visibleTags.length;
    return GlassSurface(
      borderRadius: 20,
      padding: const EdgeInsets.all(16),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onView,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isConflict)
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '冲突副本',
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                color: colorScheme.onErrorContainer,
                              ),
                        ),
                      ),
                    Text(
                      item.label,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '更新于 ${item.updatedAt.toLocal()}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                    if (tags.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          ...visibleTags.map(
                            (tag) => Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.primaryContainer
                                    .withOpacity(0.55),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                tag,
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: colorScheme.onPrimaryContainer,
                                    ),
                              ),
                            ),
                          ),
                          if (remaining > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceVariant,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '+$remaining',
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              Column(
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
            ],
          ),
        ),
      ),
    );
  }
}

enum _VaultListMode { credentials, servers }
