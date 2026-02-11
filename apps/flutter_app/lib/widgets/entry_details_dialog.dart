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
      content: FutureBuilder<CredentialPayload?>(
        future: controller.readEntry(item),
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
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _detailRow('用户名', payload.username),
                _detailRow('密码', payload.password),
                _detailRow('令牌', payload.token),
                _detailRow('应用ID', payload.appId),
                _detailRow('访问令牌', payload.accessToken),
                _detailRow('密钥', payload.secretKey),
              ],
            ),
          );
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
          Text(value.isEmpty ? '-' : value),
        ],
      ),
    );
  }
}
