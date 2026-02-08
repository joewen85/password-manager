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
            return const Text('Unable to decrypt entry.');
          }
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _detailRow('Username', payload.username),
                _detailRow('Password', payload.password),
                _detailRow('Token', payload.token),
                _detailRow('App ID', payload.appId),
                _detailRow('Access Token', payload.accessToken),
                _detailRow('Secret Key', payload.secretKey),
              ],
            ),
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
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
