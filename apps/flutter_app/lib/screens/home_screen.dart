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
import '../widgets/glass_surface.dart';
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
  _VaultListMode _mode = _VaultListMode.credentials;
  String? _selectedTag;
  bool _showConflictsOnly = false;
  VaultItem? _selectedItem;
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
      if (_selectedItem?.id == item.id) {
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
      if (created != null) {
        await _editEntry(created);
      }
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
          (item) =>
              !item.isDeleted && item.type == VaultEntryType.credential,
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
    setState(() => _selectedItem = item);
  }

  void _clearSelection() {
    if (_selectedItem == null) {
      return;
    }
    setState(() => _selectedItem = null);
  }

  void _handleSearchFocusChanged() {
    final shouldShow = _searchFocusNode.hasFocus &&
        _searchController.text.trim().isEmpty;
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
    final maxTop =
        screenHeight - safeBottom - searchHelpBottomGap - helpHeight;
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
          final labelMatch =
              view.item.type == VaultEntryType.server &&
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
                  opacityLight: isAndroid ? 0.9 : 0.94,
                  opacityDark: isAndroid ? 0.9 : 0.86,
                  child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Search 用法', style: titleStyle),
                    const SizedBox(height: 6),
                    Text(
                      '普通关键词会在标题/服务名称/应用ID/服务器名称/IP/标签里匹配，多个词按 AND 过滤。',
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
    if (_mode == _VaultListMode.services) {
      final data = await showModalBottomSheet<NewServiceSheetResult>(
        context: context,
        isScrollControlled: true,
        builder: (context) => NewServiceSheet(
          availableAccounts: _availableAccountItems(),
          availableServers: _availableServerItems(),
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
    final gradient = LinearGradient(
      colors: [
        colorScheme.primary,
        colorScheme.secondary,
      ],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
    final label = _mode == _VaultListMode.credentials
        ? '新建账号'
        : _mode == _VaultListMode.services
            ? '新建服务'
            : '新建服务器';
    return IconButton(
      tooltip: label,
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
    final tags = widget.controller.metadata.tags;
    if (tags.isEmpty) {
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
          final chips = _buildSingleLineTagWidgets(
            tags,
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
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ChoiceChip(
          label: const Text('全部'),
          selected: _selectedTag == null,
          onSelected: (_) => _handleTagSelection(null),
          labelStyle: const TextStyle(fontSize: 12),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        ),
        ...isApple
            ? _buildSingleLineTags(tags)
            : tags.map(
                (tag) => ChoiceChip(
                  label: Text(tag),
                  selected: _selectedTag == tag,
                  onSelected: (_) => _handleTagSelection(tag),
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
          onSelected: (_) => _handleTagSelection(tag),
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

  List<Widget> _buildSingleLineTagWidgets(
    List<String> tags, {
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
    final chipLabelPadding = (ChipTheme.of(context).labelPadding ??
            defaultLabelPadding)
        .resolve(Directionality.of(context));
    const checkmarkSize = 18.0;
    const checkmarkGap = 4.0;
    double chipWidth(String text, {required bool selected}) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout();
      final checkmarkWidth =
          selected ? (checkmarkSize + checkmarkGap) : 0.0;
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

    final allWidth = chipWidth('全部', selected: _selectedTag == null);
    usedWidth += allWidth;
    chips.add(
      buildChip('全部', _selectedTag == null, () {
        _handleTagSelection(null);
      }),
    );

    final displayTags = tags.take(maxVisible).toList();
    var visible = 0;
    for (final tag in displayTags) {
      final width = chipWidth(tag, selected: _selectedTag == tag);
      if (usedWidth + spacing + width > maxWidth) {
        break;
      }
      usedWidth += spacing + width;
      visible += 1;
      chips.add(
        buildChip(tag, _selectedTag == tag, () {
          _handleTagSelection(tag);
        }),
      );
    }

    final remaining = tags.length - visible;
    if (remaining > 0) {
      final overflowText = '...+$remaining';
      final overflowWidth = chipWidth(overflowText, selected: false);
      while (chips.length > 1 &&
          usedWidth + spacing + overflowWidth > maxWidth) {
        final removedTag = displayTags[visible - 1];
        usedWidth -= spacing + chipWidth(
          removedTag,
          selected: _selectedTag == removedTag,
        );
        chips.removeLast();
        visible -= 1;
      }
      if (usedWidth + spacing + overflowWidth <= maxWidth) {
        chips.add(
          ActionChip(
            label: Text(overflowText, overflow: TextOverflow.ellipsis),
            onPressed: () => _showAllTags(tags),
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
                      _handleTagSelection(tag);
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
        final listPane =
            _buildVaultListPane(
          context,
          useDetailsPane: useDetailsPane,
          singleLineTags: singleLineTags,
          maxVisibleTags: maxVisibleTags,
        );
        final detailsPane = EntryDetailsPanel(
          controller: widget.controller,
          item: _selectedItem,
          onClear: _selectedItem == null ? null : _clearSelection,
        );

        if (!useDetailsPane) {
          return Padding(
            padding: basePadding,
            child: listPane,
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
                    child: listPane,
                  ),
                ),
                SizedBox(width: paneSplit.gapExtent),
                SizedBox(
                  width: paneSplit.endExtent,
                  height: constraints.maxHeight,
                  child: Padding(
                    padding: basePadding.copyWith(left: 12),
                    child: detailsPane,
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
                  child: listPane,
                ),
              ),
              SizedBox(height: paneSplit.gapExtent),
              SizedBox(
                height: paneSplit.endExtent,
                width: constraints.maxWidth,
                child: Padding(
                  padding: basePadding.copyWith(top: 12),
                  child: detailsPane,
                ),
              ),
            ],
          );
        }

        return Padding(
          padding: basePadding,
          child: Row(
            children: [
              Expanded(child: listPane),
              const SizedBox(width: 20),
              Expanded(child: detailsPane),
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
    final hasSearch = _searchQuery.isNotEmpty;
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
                              ButtonSegment(
                                value: _VaultListMode.services,
                                label: Text('服务'),
                              ),
                            ],
                            selected: {_mode},
                            onSelectionChanged: hasSearch
                                ? null
                                : (value) {
                                    setState(() {
                                      _mode = value.first;
                                      _selectedItem = null;
                                    });
                                  },
                          ),
                          const SizedBox(width: 8),
                          if (widget.controller.hasConflicts)
                            FilterChip(
                              label: const Text('仅冲突'),
                              selected: _showConflictsOnly,
                              onSelected: (value) {
                                setState(
                                  () => _showConflictsOnly = value,
                                );
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
                      CompositedTransformTarget(
                        key: _searchFieldKey,
                        link: _searchFieldLink,
                        child: SizedBox(
                          height: _searchFieldHeight,
                          child: TextField(
                            controller: _searchController,
                            focusNode: _searchFocusNode,
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      fontSize: 12,
                                    ),
                            onTapOutside: (_) {
                              _searchFocusNode.unfocus();
                            },
                            decoration: const InputDecoration(
                              prefixIcon: Icon(Icons.search, size: 18),
                              hintText: '支持标题/服务名称、应用ID、服务器名称/IP、标签搜索',
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (hasSearch)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '当前为全局搜索',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
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
      animation: _entryListListenable,
      builder: (context, _) {
        final views = widget.controller.entryViews;
        final viewsVersion = widget.controller.entryViewsVersion;
        final query = _searchQuery;
        final terms = _searchTerms;
        final hasSearch = query.isNotEmpty;
        final hasTagFilter =
            !hasSearch && _selectedTag != null && _selectedTag!.isNotEmpty;
        final sorted = _buildSortedViews(
          views: views,
          viewsVersion: viewsVersion,
          hasSearch: hasSearch,
          hasTagFilter: hasTagFilter,
          terms: terms,
        );
        if (sorted.isEmpty) {
          return Center(
            child: Text(
              query.isEmpty ? '暂无条目，点击“新建”添加。' : '未找到匹配条目',
            ),
          );
        }
        final reduceEffects = _reduceEffectsForScroll ||
            sorted.length >= _reduceEffectsThreshold;
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
                tags: view.tags,
                isConflict: view.isConflict,
                isSelected: useDetailsPane && _selectedItem?.id == item.id,
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
        if (!hasSearch && !hasTagFilter && !_showConflictsOnly) {
          return listView;
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '找到 ${sorted.length} 条',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
            Expanded(child: listView),
          ],
        );
      },
    );
  }

  List<VaultEntryView> _buildSortedViews({
    required List<VaultEntryView> views,
    required int viewsVersion,
    required bool hasSearch,
    required bool hasTagFilter,
    required List<_SearchTerm> terms,
  }) {
    final sortOrder = widget.controller.metadata.sortOrder;
    final key = [
      viewsVersion,
      _mode.name,
      _showConflictsOnly,
      _selectedTag ?? '',
      _searchQuery,
      sortOrder.name,
    ].join('|');
    if (key == _cachedFilterKey && viewsVersion == _cachedViewsVersion) {
      return _cachedSortedViews;
    }
    final filtered = views.where((view) {
      if (!hasSearch) {
        final matchesType = _mode == _VaultListMode.credentials
            ? view.item.type == VaultEntryType.credential
            : _mode == _VaultListMode.services
                ? view.item.type == VaultEntryType.service
                : view.item.type == VaultEntryType.server;
        if (!matchesType) {
          return false;
        }
      }
      if (_showConflictsOnly && !view.isConflict) {
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
        isIOS && !isDark ? colorScheme.onSurface.withOpacity(0.85) : null;
    return Scaffold(
      appBar: AppBar(
        centerTitle: !isIOS,
        titleSpacing: isIOS ? 20.0 : null,
        iconTheme:
            appBarIconColor == null ? null : IconThemeData(color: appBarIconColor),
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

enum _VaultMenuAction { syncSettings, tags, export, clear }

class EntryCard extends StatelessWidget {
  const EntryCard({
    super.key,
    required this.item,
    this.service,
    required this.tags,
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
  final List<String> tags;
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
    return AnimatedContainer(
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
      child: GlassSurface(
        borderRadius: 20,
        padding: const EdgeInsets.all(16),
        reduceEffects: reduceEffects,
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
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                        if (serviceInfo != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            serviceInfo,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
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
                                          color:
                                              colorScheme.onPrimaryContainer,
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
                                          color:
                                              colorScheme.onSurfaceVariant,
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

enum _VaultListMode { credentials, services, servers }

enum _EntryMenuAction { copy }
