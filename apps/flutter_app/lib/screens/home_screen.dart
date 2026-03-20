import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:password_manager_core/password_manager_core.dart';

import '../models/new_entry_data.dart';
import '../state/vault_metadata.dart';
import '../state/vault_controller.dart';
import '../utils/adaptive_layout.dart';
import '../utils/export_file.dart';
import '../theme/motion_tokens.dart';
import '../widgets/app_background.dart';
import '../widgets/entry_details_dialog.dart';
import '../widgets/fade_slide.dart';
import '../widgets/filter_chip_section.dart';
import '../widgets/glass_surface.dart';
import 'category_management_screen.dart';
import 'new_entry_sheet.dart';
import 'new_service_sheet.dart';
import 'sync_settings_screen.dart';
import 'tag_management_screen.dart';
import 'new_server_sheet.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final VaultController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  static const double _searchFieldHeight = 52.0;
  static const double _searchHelpSpacing = 8.0;
  static const double _searchHelpBottomGap = 10.0;
  static const int _reduceEffectsThreshold = 20;

  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final LayerLink _searchFieldLink = LayerLink();
  final GlobalKey _searchFieldKey = GlobalKey();
  final GlobalKey _searchHelpKey = GlobalKey();
  late final Listenable _entryListListenable;
  late final AnimationController _syncRotationController;
  String? _selectedCategory;
  String? _selectedTag;
  bool _showConflictsOnly = false;
  final ValueNotifier<VaultItem?> _selectedItemNotifier =
      ValueNotifier<VaultItem?>(null);
  bool _showSearchHelp = false;
  bool _isSyncing = false;
  bool _searchHelpMetricsScheduled = false;
  bool _reduceEffectsForScroll = false;
  String _searchQuery = '';
  List<_SearchTerm> _searchTerms = const [];
  int _cachedViewsVersion = -1;
  String _cachedFilterKey = '';
  List<VaultEntryView> _cachedSortedViews = const [];
  double _searchHelpHeight = 0;
  double _searchHelpDyAdjustment = 0;
  Offset _searchFieldOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    _searchFocusNode.addListener(_handleSearchFocusChanged);
    _searchController.addListener(_handleSearchTextChanged);
    _entryListListenable =
        Listenable.merge([widget.controller, _searchController]);
    _isSyncing = widget.controller.isSyncing;
    _syncRotationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    if (_isSyncing) {
      _syncRotationController.repeat();
    }
    widget.controller.addListener(_handleSyncStateChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleSyncStateChanged);
    _searchFocusNode.removeListener(_handleSearchFocusChanged);
    _searchController.removeListener(_handleSearchTextChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _syncRotationController.dispose();
    _selectedItemNotifier.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_showSearchHelp) {
      _scheduleSearchHelpMetricsUpdate();
    }
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
          availableCategories: widget.controller.metadata.categories,
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
    if (item.type == VaultEntryType.service) {
      final payload = await widget.controller.readService(item);
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
      final data = await showModalBottomSheet<NewServiceSheetResult>(
        context: context,
        isScrollControlled: true,
        builder: (context) => NewServiceSheet(
          availableAccounts: _availableAccountItems(),
          availableServers: _availableServerItems(),
          availableCategories: widget.controller.metadata.categories,
          initialData: NewServiceSheetResult(
            label: item.label,
            payload: payload,
          ),
          title: '编辑服务',
          submitLabel: '保存修改',
        ),
      );
      if (data != null) {
        await widget.controller.updateService(
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
        availableCategories: widget.controller.metadata.categories,
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
      if (_selectedItemNotifier.value?.id == item.id) {
        _clearSelection();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已删除')),
        );
      }
    }
  }

  Future<void> _showEntryDetailsDialog(VaultItem item) async {
    await showDialog<void>(
      context: context,
      builder: (context) => EntryDetailsDialog(
        controller: widget.controller,
        item: item,
      ),
    );
  }

  Future<void> _copyEntry(VaultEntryView view) async {
    final item = view.item;
    VaultItem? created;
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
      created = await widget.controller.addServerAsset(
        label: _buildCopyLabel(item.label),
        payload: payload,
      );
    } else if (item.type == VaultEntryType.service) {
      final payload = await widget.controller.readService(item);
      if (payload == null) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法解密条目')),
        );
        return;
      }
      created = await widget.controller.addService(
        label: _buildCopyLabel(item.label),
        payload: payload,
      );
    } else {
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
      created = await widget.controller.addEntry(
        label: _buildCopyLabel(item.label),
        payload: payload,
      );
    }
    if (mounted) {
      await _editEntry(created);
    }
  }

  String _buildCopyLabel(String label) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) {
      return '未命名副本';
    }
    return '$trimmed 副本';
  }

  List<VaultItem> _availableAccountItems() {
    final items = widget.controller.items
        .where(
          (item) => !item.isDeleted && item.type == VaultEntryType.credential,
        )
        .toList();
    items.sort((a, b) => a.label.compareTo(b.label));
    return items;
  }

  List<VaultItem> _availableServerItems() {
    final items = widget.controller.items
        .where(
          (item) => !item.isDeleted && item.type == VaultEntryType.server,
        )
        .toList();
    items.sort((a, b) => a.label.compareTo(b.label));
    return items;
  }

  void _selectItem(VaultItem item) {
    _selectedItemNotifier.value = item;
  }

  void _clearSelection() {
    if (_selectedItemNotifier.value == null) {
      return;
    }
    _selectedItemNotifier.value = null;
  }

  void _handleSearchFocusChanged() {
    final shouldShow =
        _searchFocusNode.hasFocus && _searchController.text.trim().isEmpty;
    if (shouldShow == _showSearchHelp) {
      return;
    }
    setState(() => _showSearchHelp = shouldShow);
    if (shouldShow) {
      _scheduleSearchHelpMetricsUpdate();
    }
  }

  void _handleSearchTextChanged() {
    final trimmed = _searchController.text.trim();
    if (trimmed != _searchQuery) {
      _searchQuery = trimmed;
      _searchTerms = _parseSearchTerms(trimmed);
    }
    final shouldShow = _searchFocusNode.hasFocus && trimmed.isEmpty;
    if (shouldShow != _showSearchHelp) {
      setState(() => _showSearchHelp = shouldShow);
      if (shouldShow) {
        _scheduleSearchHelpMetricsUpdate();
      }
    }
  }

  void _handleTagSelection(String? tag) {
    final previousTag = _selectedTag;
    _searchFocusNode.unfocus();
    setState(() => _selectedTag = tag);
    _updateSearchForTagChange(
      previousTag: previousTag,
      nextTag: tag,
    );
  }

  void _updateSearchForTagChange({
    required String? previousTag,
    required String? nextTag,
  }) {
    var updated = _stripTagToken(_searchController.text, previousTag);
    if (nextTag != null && nextTag.trim().isNotEmpty) {
      final token = '#${nextTag.trim()}';
      if (!_containsTagToken(updated, nextTag)) {
        updated = updated.trim().isEmpty ? token : '${updated.trim()} $token';
      }
    }
    updated = updated.trim();
    if (updated == _searchController.text) {
      return;
    }
    _searchController.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: updated.length),
    );
  }

  bool _containsTagToken(String input, String tag) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    final lowerTag = tag.toLowerCase();
    final tokens = trimmed.split(RegExp(r'[\s,]+'));
    for (final token in tokens) {
      final lower = token.toLowerCase();
      if (lower == '#$lowerTag' || lower == 'tag:$lowerTag') {
        return true;
      }
    }
    return false;
  }

  String _stripTagToken(String input, String? tag) {
    final trimmed = input.trim();
    if (trimmed.isEmpty || tag == null || tag.trim().isEmpty) {
      return trimmed;
    }
    final lowerTag = tag.toLowerCase();
    final tokens = trimmed.split(RegExp(r'[\s,]+'));
    final remaining = tokens.where((token) {
      final lower = token.toLowerCase();
      return lower != '#$lowerTag' && lower != 'tag:$lowerTag';
    }).toList();
    return remaining.join(' ');
  }

  void _setReduceEffectsForScroll(bool value) {
    if (_reduceEffectsForScroll == value || !mounted) {
      return;
    }
    setState(() => _reduceEffectsForScroll = value);
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification ||
        notification is ScrollUpdateNotification) {
      _setReduceEffectsForScroll(true);
    } else if (notification is ScrollEndNotification) {
      _setReduceEffectsForScroll(false);
    } else if (notification is UserScrollNotification &&
        notification.direction == ScrollDirection.idle) {
      _setReduceEffectsForScroll(false);
    }
    return false;
  }

  void _scheduleSearchHelpMetricsUpdate() {
    if (_searchHelpMetricsScheduled) {
      return;
    }
    _searchHelpMetricsScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchHelpMetricsScheduled = false;
      if (!mounted || !_showSearchHelp) {
        return;
      }
      _updateSearchHelpMetrics(
        searchFieldHeight: _searchFieldHeight,
        searchHelpSpacing: _searchHelpSpacing,
        searchHelpBottomGap: _searchHelpBottomGap,
      );
    });
  }

  void _handleSyncStateChanged() {
    final syncing = widget.controller.isSyncing;
    if (syncing == _isSyncing) {
      return;
    }
    _isSyncing = syncing;
    if (syncing) {
      _syncRotationController.repeat();
    } else {
      _syncRotationController.stop();
      _syncRotationController.value = 0;
    }
    if (mounted) {
      setState(() {});
    }
  }

  Widget _buildSyncAction(BuildContext context) {
    final isAndroid = _isAndroid;
    final switchDuration =
        isAndroid ? MotionTokens.short4 : const Duration(milliseconds: 180);
    final switchInCurve =
        isAndroid ? MotionTokens.emphasizedDecelerate : Curves.easeOut;
    final switchOutCurve =
        isAndroid ? MotionTokens.emphasizedAccelerate : Curves.easeOut;
    final labelStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w600,
        );
    return AnimatedSwitcher(
      duration: switchDuration,
      switchInCurve: switchInCurve,
      switchOutCurve: switchOutCurve,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: _isSyncing
          ? Row(
              key: const ValueKey('syncing'),
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('同步中', style: labelStyle),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: null,
                  icon: RotationTransition(
                    turns: _syncRotationController,
                    child: const Icon(Icons.sync),
                  ),
                  tooltip: '同步中',
                ),
              ],
            )
          : Row(
              key: const ValueKey('sync-idle'),
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: () =>
                      widget.controller.syncNow(notifyProgress: true),
                  icon: const Icon(Icons.sync),
                  tooltip: '同步',
                ),
              ],
            ),
    );
  }

  void _updateSearchHelpMetrics({
    required double searchFieldHeight,
    required double searchHelpSpacing,
    required double searchHelpBottomGap,
  }) {
    final fieldContext = _searchFieldKey.currentContext;
    if (fieldContext == null) {
      return;
    }
    final fieldBox = fieldContext.findRenderObject();
    if (fieldBox is! RenderBox || !fieldBox.hasSize) {
      return;
    }
    var helpHeight = _searchHelpHeight;
    final helpContext = _searchHelpKey.currentContext;
    if (helpContext != null) {
      final helpBox = helpContext.findRenderObject();
      if (helpBox is RenderBox && helpBox.hasSize) {
        helpHeight = helpBox.size.height;
      }
    }
    final fieldOffset = fieldBox.localToGlobal(Offset.zero);
    final mediaQuery = MediaQuery.of(context);
    final screenHeight = mediaQuery.size.height;
    final safeBottom = mediaQuery.padding.bottom;
    final desiredTop = fieldOffset.dy + searchFieldHeight + searchHelpSpacing;
    final maxTop = screenHeight - safeBottom - searchHelpBottomGap - helpHeight;
    final adjustment = desiredTop > maxTop ? maxTop - desiredTop : 0.0;
    if ((helpHeight - _searchHelpHeight).abs() > 0.5 ||
        (adjustment - _searchHelpDyAdjustment).abs() > 0.5 ||
        (fieldOffset - _searchFieldOffset).distance > 0.5) {
      setState(() {
        _searchHelpHeight = helpHeight;
        _searchHelpDyAdjustment = adjustment;
        _searchFieldOffset = fieldOffset;
      });
    }
  }

  List<_SearchTerm> _parseSearchTerms(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const <_SearchTerm>[];
    }
    final parts = trimmed.split(RegExp(r'[\s,]+'));
    final terms = <_SearchTerm>[];
    for (final part in parts) {
      if (part.isEmpty) {
        continue;
      }
      if (part.startsWith('#') && part.length > 1) {
        terms.add(
          _SearchTerm(_SearchField.tag, part.substring(1).toLowerCase()),
        );
        continue;
      }
      final splitIndex = part.indexOf(':');
      if (splitIndex > 0 && splitIndex < part.length - 1) {
        final prefix = part.substring(0, splitIndex).toLowerCase();
        final value = part.substring(splitIndex + 1).trim();
        if (value.isEmpty) {
          continue;
        }
        final lowerValue = value.toLowerCase();
        switch (prefix) {
          case 'title':
          case 'name':
          case 'label':
            terms.add(_SearchTerm(_SearchField.title, lowerValue));
            continue;
          case 'service':
          case 'svc':
            terms.add(_SearchTerm(_SearchField.serviceName, lowerValue));
            continue;
          case 'app':
          case 'appid':
            terms.add(_SearchTerm(_SearchField.appId, lowerValue));
            continue;
          case 'server':
          case 'srv':
            terms.add(_SearchTerm(_SearchField.serverName, lowerValue));
            continue;
          case 'ip':
            terms.add(_SearchTerm(_SearchField.serverIp, lowerValue));
            continue;
          case 'tag':
          case 'tags':
            terms.add(_SearchTerm(_SearchField.tag, lowerValue));
            continue;
        }
      }
      terms.add(_SearchTerm(_SearchField.any, part.toLowerCase()));
    }
    return terms;
  }

  bool _usesGlobalTagSearch(List<_SearchTerm> terms) {
    return terms.isNotEmpty &&
        terms.every((term) => term.field == _SearchField.tag);
  }

  bool _matchesSearch(VaultEntryView view, List<_SearchTerm> terms) {
    if (terms.isEmpty) {
      return true;
    }
    final index = view.searchIndex;

    bool contains(String? valueLower, String term) =>
        valueLower?.contains(term) ?? false;

    bool matchesTagTerm(String term) {
      for (final tag in index.tagsLower) {
        if (tag.contains(term)) {
          return true;
        }
      }
      return false;
    }

    for (final term in terms) {
      switch (term.field) {
        case _SearchField.title:
          if (!contains(index.labelLower, term.value)) {
            return false;
          }
          break;
        case _SearchField.serviceName:
          if (view.item.type != VaultEntryType.service ||
              !contains(index.labelLower, term.value)) {
            return false;
          }
          break;
        case _SearchField.appId:
          if (!contains(index.appIdLower, term.value)) {
            return false;
          }
          break;
        case _SearchField.serverName:
          final nameMatch = contains(index.serverNameLower, term.value);
          final labelMatch = view.item.type == VaultEntryType.server &&
              contains(index.labelLower, term.value);
          if (!nameMatch && !labelMatch) {
            return false;
          }
          break;
        case _SearchField.serverIp:
          if (!contains(index.serverIpLower, term.value)) {
            return false;
          }
          break;
        case _SearchField.tag:
          if (!matchesTagTerm(term.value)) {
            return false;
          }
          break;
        case _SearchField.any:
          if (!index.anyLower.contains(term.value)) {
            return false;
          }
          break;
      }
    }
    return true;
  }

  Widget _buildSearchHelp(BuildContext context) {
    final platform = Theme.of(context).platform;
    final isAndroid = platform == TargetPlatform.android;
    final textStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontSize: 14,
          height: 1.5,
        );
    final labelStyle = textStyle?.copyWith(fontWeight: FontWeight.w600);
    final titleStyle = textStyle?.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.w700,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth * (2 / 3);
        final width = maxWidth < 260
            ? maxWidth
            : maxWidth > 560
                ? 560.0
                : maxWidth;
        return Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: KeyedSubtree(
              key: _searchHelpKey,
              child: GlassSurface(
                borderRadius: 14,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                blur: 16,
                opacityLight: isAndroid ? 0.9 : 0.97,
                opacityDark: isAndroid ? 0.9 : 0.9,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Search 用法', style: titleStyle),
                    const SizedBox(height: 6),
                    Text(
                      '普通关键词仍在当前分类中匹配；纯标签搜索(tag:/#)会跨分类全局匹配，多个词按 AND 过滤。',
                      style: textStyle,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '分类筛选与标签筛选可叠加；分类筛选只影响当前结果集，不改变搜索语法。',
                      style: textStyle,
                    ),
                    const SizedBox(height: 6),
                    Text('指定字段前缀：', style: labelStyle),
                    const SizedBox(height: 4),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final isNarrow = constraints.maxWidth < 360;
                        final leftColumn = [
                          'title:xxx / label:xxx 标题',
                          'service:xxx 服务名称',
                          'appid:xxx 应用ID',
                        ];
                        final rightColumn = [
                          'server:xxx 服务器名称',
                          'ip:xxx 服务器IP',
                          'tag:xxx 或 #xxx 标签',
                        ];
                        if (isNarrow) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final line in leftColumn)
                                Text(line, style: textStyle),
                              for (final line in rightColumn)
                                Text(line, style: textStyle),
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (final line in leftColumn)
                                    Text(line, style: textStyle),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (final line in rightColumn)
                                    Text(line, style: textStyle),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '多标签示例：tag:prod tag:cn 或 #prod #cn',
                      style: textStyle,
                    ),
                    Text(
                      '多条件示例：title:aws tag:prod ip:10.0',
                      style: textStyle,
                    ),
                    Text(
                      '筛选示例：先点分类“云平台”，再搜 title:aws',
                      style: textStyle,
                    ),
                    Text(
                      '全局示例：先点任意分类，输入 #prod 仍会跨分类搜索标签',
                      style: textStyle,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openCreateSheet() async {
    final createType = await showModalBottomSheet<_CreateEntryType>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '选择条目类型',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.key_rounded),
                title: const Text('新建账号'),
                onTap: () => Navigator.of(context).pop(_CreateEntryType.credential),
              ),
              ListTile(
                leading: const Icon(Icons.dns_rounded),
                title: const Text('新建服务器'),
                onTap: () => Navigator.of(context).pop(_CreateEntryType.server),
              ),
              ListTile(
                leading: const Icon(Icons.miscellaneous_services_rounded),
                title: const Text('新建服务'),
                onTap: () => Navigator.of(context).pop(_CreateEntryType.service),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || createType == null) {
      return;
    }
    if (createType == _CreateEntryType.credential) {
      final data = await showModalBottomSheet<NewEntryData>(
        context: context,
        isScrollControlled: true,
        builder: (context) => NewEntrySheet(
          availableCategories: widget.controller.metadata.categories,
        ),
      );
      if (data != null) {
        await widget.controller.addEntry(
          label: data.label,
          payload: data.payload,
        );
      }
      return;
    }
    if (createType == _CreateEntryType.service) {
      final data = await showModalBottomSheet<NewServiceSheetResult>(
        context: context,
        isScrollControlled: true,
        builder: (context) => NewServiceSheet(
          availableAccounts: _availableAccountItems(),
          availableServers: _availableServerItems(),
          availableCategories: widget.controller.metadata.categories,
        ),
      );
      if (data != null) {
        await widget.controller.addService(
          label: data.label,
          payload: data.payload,
        );
      }
      return;
    }
    final data = await showModalBottomSheet<NewServerSheetResult>(
      context: context,
      isScrollControlled: true,
      builder: (context) => NewServerSheet(
        availableCategories: widget.controller.metadata.categories,
      ),
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
    final gradient = LinearGradient(
      colors: [
        colorScheme.primary,
        colorScheme.secondary,
      ],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
    return IconButton(
      tooltip: '新建条目',
      onPressed: _openCreateSheet,
      icon: ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (bounds) {
          return gradient.createShader(
            Rect.fromLTWH(0, 0, bounds.width, bounds.height),
          );
        },
        child: const Icon(Icons.add_rounded, color: Colors.white),
      ),
    );
  }

  Widget _tagFilterRow({
    required bool singleLine,
    int maxVisible = 999,
  }) {
    return FilterChipSection(
      items: widget.controller.metadata.tags,
      allLabel: '全部',
      selectedValue: _selectedTag,
      singleLine: singleLine,
      maxVisible: maxVisible,
      bottomSheetTitle: '全部标签',
      onSelected: _handleTagSelection,
    );
  }

  Widget _categoryFilterRow() {
    final platform = Theme.of(context).platform;
    final isIOS = platform == TargetPlatform.iOS;
    return FilterChipSection(
      items: widget.controller.metadata.categories,
      allLabel: '全部分类',
      selectedValue: _selectedCategory,
      singleLine: _isAndroid || isIOS,
      maxVisible: _isAndroid ? 3 : 999,
      bottomSheetTitle: '全部分类',
      onSelected: (value) => setState(() => _selectedCategory = value),
    );
  }

  List<String> _activeFilterLabels({required List<_SearchTerm> terms}) {
    final labels = <String>[];
    if (_selectedCategory != null && _selectedCategory!.isNotEmpty) {
      labels.add('分类: ${_selectedCategory!}');
    }
    if (_selectedTag != null && _selectedTag!.isNotEmpty) {
      labels.add('标签: ${_selectedTag!}');
    }
    if (_showConflictsOnly) {
      labels.add('仅冲突');
    }
    if (_searchQuery.isNotEmpty) {
      labels.add(
        _usesGlobalTagSearch(terms)
            ? '搜索: 全局标签'
            : '搜索: 当前分类',
      );
    }
    return labels;
  }

  Widget _buildActiveFilterSummary(
    BuildContext context, {
    required List<_SearchTerm> terms,
    required int resultCount,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final labels = _activeFilterLabels(terms: terms);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final label in labels)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '结果: $resultCount',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoPill(IconData icon, String label) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: (isDark ? Colors.black : Colors.white).withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: (isDark ? Colors.white : Colors.white).withValues(alpha: 0.3),
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
      width: double.infinity,
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
            color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.12),
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
    if (views.length < 2) {
      return views;
    }
    switch (widget.controller.metadata.sortOrder) {
      case VaultSortOrder.updatedDesc:
        views.sort((a, b) => b.item.updatedAt.compareTo(a.item.updatedAt));
        break;
      case VaultSortOrder.labelAsc:
        views.sort((a, b) => a.item.label.compareTo(b.item.label));
        break;
    }
    return views;
  }

  Widget _buildAdaptiveBody(BuildContext context) {
    const basePadding = EdgeInsets.fromLTRB(20, 12, 20, 20);
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableSize = Size(
          constraints.maxWidth,
          constraints.maxHeight,
        );
        final sizeClass = windowSizeClassFor(constraints.maxWidth);
        final paneSplit = foldablePaneSplitFor(
          context: context,
          availableSize: availableSize,
        );
        final platform = Theme.of(context).platform;
        final isAndroid = platform == TargetPlatform.android;
        final singleLineTags = isAndroid || platform == TargetPlatform.iOS;
        final maxVisibleTags = isAndroid ? 3 : 999;
        final useDetailsPane =
            paneSplit != null || sizeClass == WindowSizeClass.expanded;
        final listPane = _buildVaultListPane(
          context,
          useDetailsPane: useDetailsPane,
          singleLineTags: singleLineTags,
          maxVisibleTags: maxVisibleTags,
        );
        final detailsPane = ValueListenableBuilder<VaultItem?>(
          valueListenable: _selectedItemNotifier,
          builder: (context, selectedItem, _) {
            return EntryDetailsPanel(
              controller: widget.controller,
              item: selectedItem,
              onClear: selectedItem == null ? null : _clearSelection,
            );
          },
        );

        if (!useDetailsPane) {
          return Padding(
            padding: basePadding,
            child: RepaintBoundary(child: listPane),
          );
        }

        if (paneSplit != null) {
          if (paneSplit.axis == Axis.vertical) {
            return Row(
              children: [
                SizedBox(
                  width: paneSplit.startExtent,
                  height: constraints.maxHeight,
                  child: Padding(
                    padding: basePadding.copyWith(right: 12),
                    child: RepaintBoundary(child: listPane),
                  ),
                ),
                SizedBox(width: paneSplit.gapExtent),
                SizedBox(
                  width: paneSplit.endExtent,
                  height: constraints.maxHeight,
                  child: Padding(
                    padding: basePadding.copyWith(left: 12),
                    child: RepaintBoundary(child: detailsPane),
                  ),
                ),
              ],
            );
          }
          return Column(
            children: [
              SizedBox(
                height: paneSplit.startExtent,
                width: constraints.maxWidth,
                child: Padding(
                  padding: basePadding.copyWith(bottom: 12),
                  child: RepaintBoundary(child: listPane),
                ),
              ),
              SizedBox(height: paneSplit.gapExtent),
              SizedBox(
                height: paneSplit.endExtent,
                width: constraints.maxWidth,
                child: Padding(
                  padding: basePadding.copyWith(top: 12),
                  child: RepaintBoundary(child: detailsPane),
                ),
              ),
            ],
          );
        }

        return Padding(
          padding: basePadding,
          child: Row(
            children: [
              Expanded(child: RepaintBoundary(child: listPane)),
              const SizedBox(width: 20),
              Expanded(child: RepaintBoundary(child: detailsPane)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildVaultListPane(
    BuildContext context, {
    required bool useDetailsPane,
    required bool singleLineTags,
    required int maxVisibleTags,
  }) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FadeSlide(
              delay: const Duration(milliseconds: 60),
              curve: _isAndroid
                  ? MotionTokens.standardDecelerate
                  : Curves.easeOutCubic,
              child: _heroCard(context),
            ),
            const SizedBox(height: 16),
            FadeSlide(
              delay: const Duration(milliseconds: 140),
              curve: _isAndroid
                  ? MotionTokens.standardDecelerate
                  : Curves.easeOutCubic,
              child: _buildFilterPanel(
                context,
                singleLineTags: singleLineTags,
                maxVisibleTags: maxVisibleTags,
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: FadeSlide(
                delay: const Duration(milliseconds: 220),
                curve: _isAndroid
                    ? MotionTokens.standardDecelerate
                    : Curves.easeOutCubic,
                child: _buildEntryList(context, useDetailsPane: useDetailsPane),
              ),
            ),
          ],
        ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_showSearchHelp,
            child: CompositedTransformFollower(
              link: _searchFieldLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.bottomLeft,
              followerAnchor: Alignment.topLeft,
              offset: Offset(0, _searchHelpSpacing + _searchHelpDyAdjustment),
              child: AnimatedSwitcher(
                duration: _isAndroid
                    ? MotionTokens.medium1
                    : const Duration(milliseconds: 180),
                switchInCurve: _isAndroid
                    ? MotionTokens.emphasizedDecelerate
                    : Curves.easeOut,
                switchOutCurve: _isAndroid
                    ? MotionTokens.emphasizedAccelerate
                    : Curves.easeOut,
                transitionBuilder: (child, animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, -0.04),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  );
                },
                child: _showSearchHelp
                    ? KeyedSubtree(
                        key: const ValueKey('search-help'),
                        child: _buildSearchHelp(context),
                      )
                    : const SizedBox.shrink(
                        key: ValueKey('search-help-hidden'),
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEntryList(
    BuildContext context, {
    required bool useDetailsPane,
  }) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _entryListListenable,
        _selectedItemNotifier,
      ]),
      builder: (context, _) {
        final selectedItem = _selectedItemNotifier.value;
        final views = widget.controller.entryViews;
        final viewsVersion = widget.controller.entryViewsVersion;
        final query = _searchQuery;
        final terms = _searchTerms;
        final hasSearch = query.isNotEmpty;
        final hasTagFilter = _selectedTag != null && _selectedTag!.isNotEmpty;
        final hasCategoryFilter =
            _selectedCategory != null && _selectedCategory!.isNotEmpty;
        final sorted = _buildSortedViews(
          views: views,
          viewsVersion: viewsVersion,
          hasTagFilter: hasTagFilter,
          hasCategoryFilter: hasCategoryFilter,
          terms: terms,
        );
        if (sorted.isEmpty) {
          return Center(
            child: Text(
              query.isEmpty ? '暂无条目，点击“新建”添加。' : '未找到匹配条目',
            ),
          );
        }
        final reduceEffects =
            _reduceEffectsForScroll || sorted.length >= _reduceEffectsThreshold;
        final titleTerms = _termsForText(
          terms,
          includeFields: const {
            _SearchField.any,
            _SearchField.title,
            _SearchField.serviceName,
            _SearchField.serverName,
            _SearchField.appId,
            _SearchField.serverIp,
          },
        );
        final categoryTerms = <String>[
          ..._termsForText(
            terms,
            includeFields: const {_SearchField.any, _SearchField.title},
          ),
          if ((_selectedCategory ?? '').isNotEmpty) _selectedCategory!,
        ];
        final tagTerms = _termsForText(
          terms,
          includeFields: const {_SearchField.any, _SearchField.tag},
        );
        final listView = NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: ListView.separated(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).padding.bottom + 12,
            ),
            itemCount: sorted.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final view = sorted[index];
              final item = view.item;
              return EntryCard(
                item: item,
                service: view.service,
                category: view.category,
                tags: view.tags,
                searchTerms: terms,
                titleTerms: titleTerms,
                categoryTerms: categoryTerms,
                tagTerms: tagTerms,
                selectedCategory: _selectedCategory,
                selectedTag: _selectedTag,
                isConflict: view.isConflict,
                isSelected: useDetailsPane && selectedItem?.id == item.id,
                reduceEffects: reduceEffects,
                onView: () {
                  if (useDetailsPane) {
                    _selectItem(item);
                  } else {
                    _showEntryDetailsDialog(item);
                  }
                },
                onEdit: () => _editEntry(item),
                onDelete: () => _deleteEntry(item),
                onCopy: () => _copyEntry(view),
              );
            },
          ),
        );
        if (!hasSearch &&
            !hasTagFilter &&
            !hasCategoryFilter &&
            !_showConflictsOnly) {
          return listView;
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildActiveFilterSummary(
              context,
              terms: terms,
              resultCount: sorted.length,
            ),
            Expanded(child: listView),
          ],
        );
      },
    );
  }

  Widget _buildFilterPanel(
    BuildContext context, {
    required bool singleLineTags,
    required int maxVisibleTags,
  }) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.controller, _searchController]),
      builder: (context, _) {
        final hasSearch = _searchQuery.isNotEmpty;
        return _sectionCard(
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
                        style: Theme.of(context).textTheme.bodySmall,
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
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _categoryFilterRow(),
                const SizedBox(height: 8),
                CompositedTransformTarget(
                  key: _searchFieldKey,
                  link: _searchFieldLink,
                  child: SizedBox(
                    height: _searchFieldHeight,
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _searchController,
                      builder: (context, value, _) {
                        final hasText = value.text.trim().isNotEmpty;
                        return TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(fontSize: 12),
                          onTapOutside: (_) {
                            _searchFocusNode.unfocus();
                          },
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search, size: 18),
                            hintText: '字段搜索按当前分类，tag/# 标签搜索全局',
                            suffixIcon: hasText
                                ? IconButton(
                                    tooltip: '清空搜索',
                                    onPressed: () {
                                      _searchController.clear();
                                      _searchFocusNode.requestFocus();
                                    },
                                    icon: const Icon(
                                      Icons.clear_rounded,
                                      size: 18,
                                    ),
                                  )
                                : null,
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                if (hasSearch)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '当前为搜索模式；指定字段按当前分类，纯标签搜索跨分类',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontSize: 11,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                    ),
                  ),
                const SizedBox(height: 8),
                _tagFilterRow(
                  singleLine: singleLineTags,
                  maxVisible: maxVisibleTags,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<VaultEntryView> _buildSortedViews({
    required List<VaultEntryView> views,
    required int viewsVersion,
    required bool hasTagFilter,
    required bool hasCategoryFilter,
    required List<_SearchTerm> terms,
  }) {
    final sortOrder = widget.controller.metadata.sortOrder;
      final key = [
      viewsVersion,
      _showConflictsOnly,
      _selectedCategory ?? '',
      _selectedTag ?? '',
      _searchQuery,
      sortOrder.name,
    ].join('|');
    if (key == _cachedFilterKey && viewsVersion == _cachedViewsVersion) {
      return _cachedSortedViews;
    }
    final filtered = views.where((view) {
      if (_showConflictsOnly && !view.isConflict) {
        return false;
      }
      if (hasCategoryFilter && view.category != _selectedCategory) {
        return false;
      }
      if (hasTagFilter && !view.tags.contains(_selectedTag)) {
        return false;
      }
      if (terms.isNotEmpty && !_matchesSearch(view, terms)) {
        return false;
      }
      return true;
    }).toList();
    final sorted = _sortViews(filtered);
    _cachedFilterKey = key;
    _cachedViewsVersion = viewsVersion;
    _cachedSortedViews = sorted;
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final isIOS = platform == TargetPlatform.iOS;
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final appBarIconColor =
        isIOS && !isDark ? colorScheme.onSurface.withValues(alpha: 0.85) : null;
    return Scaffold(
      appBar: AppBar(
        centerTitle: !isIOS,
        titleSpacing: isIOS ? 20.0 : null,
        iconTheme: appBarIconColor == null
            ? null
            : IconThemeData(color: appBarIconColor),
        actionsIconTheme: appBarIconColor == null
            ? null
            : IconThemeData(color: appBarIconColor),
        title: isIOS
            ? const SizedBox(
                width: double.infinity,
                child: Text('密码库'),
              )
            : const Text('密码库'),
        actions: [
          _buildCreateButton(context),
          _buildSyncAction(context),
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
                case _VaultMenuAction.categories:
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => CategoryManagementScreen(
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
                    _clearSelection();
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
                child: Text('标签管理'),
              ),
              PopupMenuItem(
                value: _VaultMenuAction.categories,
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
      body: AppBackground(
        child: SafeArea(
          child: _buildAdaptiveBody(context),
        ),
      ),
    );
  }
}

enum _SearchField { any, title, serviceName, appId, serverName, serverIp, tag }

class _SearchTerm {
  const _SearchTerm(this.field, this.value);

  final _SearchField field;
  final String value;
}

List<String> _termsForText(
  List<_SearchTerm> terms, {
  required Set<_SearchField> includeFields,
}) {
  final unique = <String>{};
  for (final term in terms) {
    if (!includeFields.contains(term.field)) {
      continue;
    }
    final value = term.value.trim();
    if (value.isNotEmpty) {
      unique.add(value);
    }
  }
  final result = unique.toList();
  result.sort((a, b) => b.length.compareTo(a.length));
  return result;
}

bool _matchesTagHighlight(String tag, List<_SearchTerm> terms) {
  final lowerTag = tag.toLowerCase();
  for (final term in terms) {
    if (term.field == _SearchField.tag || term.field == _SearchField.any) {
      if (lowerTag.contains(term.value)) {
        return true;
      }
    }
  }
  return false;
}

class _HighlightedText extends StatelessWidget {
  const _HighlightedText(
    this.text, {
    required this.terms,
    this.style,
    this.highlightStyle,
    this.maxLines,
    this.enableHighlight = true,
  });

  final String text;
  final List<String> terms;
  final TextStyle? style;
  final TextStyle? highlightStyle;
  final int? maxLines;
  final bool enableHighlight;

  @override
  Widget build(BuildContext context) {
    if (!enableHighlight || text.isEmpty || terms.isEmpty) {
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
      );
    }
    final spans = <TextSpan>[];
    final lower = text.toLowerCase();
    var index = 0;
    while (index < text.length) {
      int? matchStart;
      String? matchedTerm;
      for (final term in terms) {
        final start = lower.indexOf(term.toLowerCase(), index);
        if (start == -1) {
          continue;
        }
        if (matchStart == null || start < matchStart) {
          matchStart = start;
          matchedTerm = term;
        }
      }
      if (matchStart == null || matchedTerm == null) {
        spans.add(TextSpan(text: text.substring(index), style: style));
        break;
      }
      if (matchStart > index) {
        spans.add(
          TextSpan(text: text.substring(index, matchStart), style: style),
        );
      }
      final end = matchStart + matchedTerm.length;
      spans.add(
        TextSpan(
          text: text.substring(matchStart, end),
          style: highlightStyle ?? style,
        ),
      );
      index = end;
    }
    return RichText(
      maxLines: maxLines,
      overflow: maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
      text: TextSpan(
        style: DefaultTextStyle.of(context).style.merge(style),
        children: spans,
      ),
    );
  }
}

enum _VaultMenuAction { syncSettings, tags, categories, export, clear }

class EntryCard extends StatelessWidget {
  const EntryCard({
    super.key,
    required this.item,
    this.service,
    required this.category,
    required this.tags,
    required this.searchTerms,
    required this.titleTerms,
    required this.categoryTerms,
    required this.tagTerms,
    required this.selectedCategory,
    required this.selectedTag,
    required this.isConflict,
    this.isSelected = false,
    this.reduceEffects = false,
    required this.onView,
    required this.onEdit,
    required this.onDelete,
    required this.onCopy,
  });

  final VaultItem item;
  final ServicePayload? service;
  final String category;
  final List<String> tags;
  final List<_SearchTerm> searchTerms;
  final List<String> titleTerms;
  final List<String> categoryTerms;
  final List<String> tagTerms;
  final String? selectedCategory;
  final String? selectedTag;
  final bool isConflict;
  final bool isSelected;
  final bool reduceEffects;
  final VoidCallback onView;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final Future<void> Function() onCopy;

  @override
  Widget build(BuildContext context) {
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final useAnimations = !disableAnimations && !reduceEffects;
    final colorScheme = Theme.of(context).colorScheme;
    final icon = item.type == VaultEntryType.server
        ? Icons.dns_rounded
        : item.type == VaultEntryType.service
            ? Icons.miscellaneous_services_rounded
            : Icons.key_rounded;
    final accent = item.type == VaultEntryType.server
        ? colorScheme.tertiary
        : item.type == VaultEntryType.service
            ? colorScheme.primary
            : colorScheme.secondary;
    final serviceInfo = _buildServiceInfo(service);
    final visibleTags = tags.take(3).toList();
    final remaining = tags.length - visibleTags.length;
    final useSimpleCard = isAndroid || reduceEffects;
    final cardChild = GlassSurface(
      borderRadius: 20,
      padding: const EdgeInsets.all(16),
      reduceEffects: reduceEffects,
      showShadow: !useSimpleCard,
      child: Material(
        type: MaterialType.transparency,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onLongPressStart: (details) =>
              _showCopyMenu(context, details.globalPosition),
          onSecondaryTapDown: (details) =>
              _showCopyMenu(context, details.globalPosition),
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
                    color: accent.withValues(alpha: 0.15),
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
                      _HighlightedText(
                        item.label,
                        terms: titleTerms,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                        highlightStyle: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: colorScheme.primary,
                            ),
                        enableHighlight: !useSimpleCard,
                      ),
                      if (serviceInfo != null) ...[
                        const SizedBox(height: 4),
                        _HighlightedText(
                          serviceInfo,
                          terms: titleTerms,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                          highlightStyle: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: colorScheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                          maxLines: 1,
                          enableHighlight: !useSimpleCard,
                        ),
                      ],
                      if (category.trim().isNotEmpty) ...[
                        const SizedBox(height: 6),
                        _HighlightedText(
                          '分类: $category',
                          terms: categoryTerms,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                          highlightStyle: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: colorScheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                          enableHighlight: !useSimpleCard,
                        ),
                      ],
                      const SizedBox(height: 6),
                      Text(
                        '更新于 ${item.updatedAt.toLocal()}',
                        style:
                            Theme.of(context).textTheme.bodySmall?.copyWith(
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
                              (tag) => _buildTagChip(
                                context,
                                tag,
                                colorScheme: colorScheme,
                                useSimpleCard: useSimpleCard,
                              ),
                            ),
                            if (remaining > 0)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: colorScheme.surfaceContainerHighest,
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
      ),
    );
    final card = useSimpleCard
        ? Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: isSelected
                  ? Border.all(color: colorScheme.primary, width: 1.3)
                  : null,
            ),
            padding: isSelected ? const EdgeInsets.all(1) : EdgeInsets.zero,
            child: cardChild,
          )
        : AnimatedContainer(
      duration: useAnimations
          ? (isAndroid
              ? MotionTokens.short4
              : const Duration(milliseconds: 180))
          : Duration.zero,
      curve: isAndroid ? MotionTokens.standard : Curves.linear,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: isSelected
            ? Border.all(color: colorScheme.primary, width: 1.3)
            : null,
      ),
      padding: isSelected ? const EdgeInsets.all(1) : EdgeInsets.zero,
      child: cardChild,
    );
    return RepaintBoundary(child: card);
  }

  Widget _buildTagChip(
    BuildContext context,
    String tag, {
    required ColorScheme colorScheme,
    required bool useSimpleCard,
  }) {
    final isSelectedTag = (selectedTag ?? '').isNotEmpty && selectedTag == tag;
    final matchedBySearch = _matchesTagHighlight(tag, searchTerms);
    final emphasized = isSelectedTag || matchedBySearch;
    final backgroundColor = emphasized
        ? colorScheme.primaryContainer
        : colorScheme.primaryContainer.withValues(alpha: 0.55);
    final foregroundColor = emphasized
        ? colorScheme.onPrimaryContainer
        : colorScheme.onPrimaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
        border: emphasized
            ? Border.all(color: colorScheme.primary.withValues(alpha: 0.35))
            : null,
      ),
      child: _HighlightedText(
        tag,
        terms: tagTerms,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foregroundColor,
            ),
        highlightStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foregroundColor,
              fontWeight: FontWeight.w800,
            ),
        enableHighlight: !useSimpleCard,
      ),
    );
  }

  Future<void> _showCopyMenu(BuildContext context, Offset position) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<_EntryMenuAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(position, position),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(
          value: _EntryMenuAction.copy,
          child: Text('复制条目'),
        ),
      ],
    );
    if (selected == _EntryMenuAction.copy) {
      await onCopy();
    }
  }

  String? _buildServiceInfo(ServicePayload? payload) {
    if (payload == null) {
      return null;
    }
    final parts = <String>[];
    final address = payload.connectionAddress.trim();
    final port = payload.connectionPort.trim();
    if (address.isNotEmpty) {
      parts.add(port.isEmpty ? address : '$address:$port');
    }
    if (payload.serverIds.isNotEmpty) {
      parts.add('服务器 ${payload.serverIds.length}');
    }
    if (payload.accounts.isNotEmpty) {
      parts.add('账号 ${payload.accounts.length}');
    }
    if (parts.isEmpty) {
      return null;
    }
    return parts.join(' · ');
  }
}

enum _CreateEntryType { credential, server, service }

enum _EntryMenuAction { copy }
