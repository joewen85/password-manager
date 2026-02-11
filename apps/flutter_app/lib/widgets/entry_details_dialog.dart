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
      content: FutureBuilder<Object?>(
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
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
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
}
