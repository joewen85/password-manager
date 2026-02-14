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
    return AlertDialog(
      title: Text(item.label),
      content: SizedBox(
        width: 420,
        child: EntryDetailsContent(controller: controller, item: item),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
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
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    if (item == null) {
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
                Icons.manage_search_rounded,
                size: 42,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                '选择条目查看详情',
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '在列表中点击条目即可预览内容',
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
                  item!.label,
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
              item: item!,
            ),
          ),
        ],
      ),
    );
  }
}

class EntryDetailsContent extends StatelessWidget {
  const EntryDetailsContent({
    super.key,
    required this.controller,
    required this.item,
  });

  final VaultController controller;
  final VaultItem item;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Object?>(
      future: item.type == VaultEntryType.server
          ? controller.readServerAsset(item)
          : controller.readEntry(item),
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
          return SelectionArea(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _detailRow('服务器名称', payload.name),
                  _detailRow('IP地址', payload.ipAddress),
                  _detailRow('端口', payload.port),
                  _detailRow('登录用户名', payload.username),
                  _detailRow('登录密码', payload.password),
                  _detailRow('基础配置', payload.basicConfig),
                  _detailRow('操作系统', payload.operatingSystem),
                  _detailRow('位置', payload.location),
                  _detailRow('备注项', payload.notes),
                  _detailRow('分类标签', payload.tags.join(', ')),
                ],
              ),
            ),
          );
        }
        if (payload is CredentialPayload) {
          return SelectionArea(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _detailRow('用户名', payload.username),
                  _detailRow('密码', payload.password),
                  _detailRow('令牌', payload.token),
                  _detailRow('应用ID', payload.appId),
                  _detailRow('访问令牌', payload.accessToken),
                  _detailRow('密钥', payload.secretKey),
                  _detailRow('分类标签', payload.tags.join(', ')),
                ],
              ),
            ),
          );
        }
        return const Text('无法识别的条目类型。');
      },
    );
  }

}

Widget _detailRow(String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        SelectableText(value.isEmpty ? '-' : value),
      ],
    ),
  );
}
