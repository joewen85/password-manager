import 'package:flutter/material.dart';
import 'package:password_manager_core/password_manager_core.dart';

import '../state/vault_controller.dart';

class EntryDetailsDialog extends StatelessWidget {
  const EntryDetailsDialog({
    super.key,
    required this.controller,
    required this.item,
  });

  final VaultController controller;
  final VaultItem item;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final currentItem = _resolveCurrentItem(controller, item);
        return AlertDialog(
          title: Text(currentItem?.label ?? item.label),
          content: SizedBox(
            width: 420,
            child: currentItem == null
                ? const Center(child: Text('条目已不存在。'))
                : EntryDetailsContent(
                    controller: controller, item: currentItem),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }
}

class EntryDetailsPanel extends StatelessWidget {
  const EntryDetailsPanel({
    super.key,
    required this.controller,
    required this.item,
    this.onClear,
  });

  final VaultController controller;
  final VaultItem? item;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final colorScheme = Theme.of(context).colorScheme;
        final textTheme = Theme.of(context).textTheme;
        final currentItem =
            item == null ? null : _resolveCurrentItem(controller, item!);
        if (currentItem == null) {
          return Container(
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: colorScheme.outlineVariant),
            ),
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    item == null
                        ? Icons.manage_search_rounded
                        : Icons.info_outline_rounded,
                    size: 42,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    item == null ? '选择条目查看详情' : '条目已不存在',
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    item == null ? '在列表中点击条目即可预览内容' : '当前选中的条目已被删除或不可用。',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }
        return Container(
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: colorScheme.outlineVariant),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      currentItem.label,
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (onClear != null)
                    IconButton(
                      tooltip: '关闭详情',
                      onPressed: onClear,
                      icon: const Icon(Icons.close_rounded),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: EntryDetailsContent(
                  controller: controller,
                  item: currentItem,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class EntryDetailsContent extends StatefulWidget {
  const EntryDetailsContent({
    super.key,
    required this.controller,
    required this.item,
  });

  final VaultController controller;
  final VaultItem item;

  @override
  State<EntryDetailsContent> createState() => _EntryDetailsContentState();
}

class _EntryDetailsContentState extends State<EntryDetailsContent> {
  late Future<Object?> _payloadFuture;

  @override
  void initState() {
    super.initState();
    _payloadFuture = _loadPayload();
  }

  @override
  void didUpdateWidget(covariant EntryDetailsContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.item.updatedAt != widget.item.updatedAt) {
      _payloadFuture = _loadPayload();
    }
  }

  Future<Object?> _loadPayload() {
    if (widget.item.type == VaultEntryType.server) {
      return widget.controller.readServerAsset(widget.item);
    }
    if (widget.item.type == VaultEntryType.service) {
      return widget.controller.readService(widget.item);
    }
    return widget.controller.readEntry(widget.item);
  }

  Widget _buildScrollableDetails(List<Widget> children) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SelectionArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(right: 12),
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Object?>(
      future: _payloadFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 120,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final payload = snapshot.data;
        if (payload == null) {
          return const Text('无法解密条目。');
        }
        if (payload is ServerAssetPayload) {
          final accountLabel = _resolveLinkedAccountLabel(
            widget.controller,
            payload.accountId,
          );
          return _buildScrollableDetails([
            _detailRow('服务器名称', payload.name),
            _detailRow('分类', payload.category),
            _detailRow('IP地址', payload.ipAddress),
            _detailRow('端口', payload.port),
            _detailRow('关联账号', accountLabel),
            _detailRow('登录用户名', payload.username),
            _detailRow('登录密码', payload.password),
            _detailRow('基础配置', payload.basicConfig),
            _detailRow('操作系统', payload.operatingSystem),
            _detailRow('位置', payload.location),
            _detailRow('备注项', payload.notes, multiline: true),
            _detailRow('标签', payload.tags.join(', ')),
          ]);
        }
        if (payload is ServicePayload) {
          final accountLabel = _resolveLinkedAccountLabel(
            widget.controller,
            payload.accountId,
          );
          final serverLabels =
              _resolveLinkedServerLabels(widget.controller, payload.serverIds);
          final accountDetails = _formatServiceAccounts(payload.accounts);
          return _buildScrollableDetails([
            _detailRow('服务名称', payload.name),
            _detailRow('分类', payload.category),
            _detailRow('连接地址', payload.connectionAddress),
            _detailRow('端口', payload.connectionPort),
            _detailRow('关联账号', accountLabel),
            _detailRow('关联服务器', serverLabels),
            _detailRow('服务账号列表', accountDetails),
            _detailRow('备注', payload.notes, multiline: true),
            _detailRow('标签', payload.tags.join(', ')),
          ]);
        }
        if (payload is CredentialPayload) {
          return _buildScrollableDetails([
            _detailRow('分类', payload.category),
            _detailRow('用户名', payload.username),
            _detailRow('密码', payload.password),
            _detailRow('令牌', payload.token),
            _detailRow('应用ID', payload.appId),
            _detailRow('访问密钥', payload.accessKey),
            _detailRow('密钥', payload.secretKey),
            _detailRow('备注项', payload.notes, multiline: true),
            _detailRow('标签', payload.tags.join(', ')),
          ]);
        }
        return const Text('无法识别的条目类型。');
      },
    );
  }
}

Widget _detailRow(String label, String value, {bool multiline = false}) {
  final displayValue = value.isEmpty ? '-' : value;
  if (!multiline) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SelectableText.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: displayValue),
          ],
        ),
      ),
    );
  }
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        SelectableText(displayValue),
      ],
    ),
  );
}

String _resolveLinkedAccountLabel(
  VaultController controller,
  String? accountId,
) {
  if (accountId == null || accountId.trim().isEmpty) {
    return '';
  }
  for (final item in controller.items) {
    if (item.id == accountId && !item.isDeleted) {
      return item.label.isEmpty ? accountId : item.label;
    }
  }
  return '已删除账号';
}

String _resolveLinkedServerLabels(
  VaultController controller,
  List<String> serverIds,
) {
  if (serverIds.isEmpty) {
    return '';
  }
  final labelMap = <String, String>{
    for (final item in controller.items)
      if (!item.isDeleted && item.type == VaultEntryType.server)
        item.id: item.label.isEmpty ? item.id : item.label,
  };
  final labels = serverIds.map((id) => labelMap[id] ?? '已删除服务器').toList();
  return labels.join(', ');
}

String _formatServiceAccounts(List<ServiceAccount> accounts) {
  if (accounts.isEmpty) {
    return '';
  }
  return accounts.asMap().entries.map((entry) {
    final index = entry.key;
    final account = entry.value;
    final parts = <String>[
      '账号${index + 1}: ${account.username.trim().isEmpty ? '-' : account.username.trim()}'
    ];
    final password = account.password.trim();
    final note = account.note.trim();
    if (password.isNotEmpty) {
      parts.add('密码: $password');
    }
    if (note.isNotEmpty) {
      parts.add('备注: $note');
    }
    return parts.join(', ');
  }).join('；');
}

VaultItem? _resolveCurrentItem(VaultController controller, VaultItem item) {
  for (final candidate in controller.items) {
    if (candidate.id == item.id) {
      return candidate.isDeleted ? null : candidate;
    }
  }
  return item.isDeleted ? null : item;
}
