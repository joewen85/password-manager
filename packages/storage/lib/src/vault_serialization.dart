import 'dart:convert';

import 'package:password_manager_core/password_manager_core.dart';
import 'package:password_manager_crypto/password_manager_crypto.dart';

Map<String, Object?> vaultItemToJson(VaultItem item) => {
      'id': item.id,
      'label': item.label,
      'encryptedPayload': item.encryptedPayload.toJson(),
      'kdfSalt': base64Encode(item.kdfSalt),
      'kdfIterations': item.kdfIterations,
      'createdAt': item.createdAt.toIso8601String(),
      'updatedAt': item.updatedAt.toIso8601String(),
    };

VaultItem vaultItemFromJson(Map<String, Object?> json) {
  final payloadJson = Map<String, Object?>.from(
    json['encryptedPayload'] as Map? ?? <String, Object?>{},
  );
  return VaultItem(
    id: json['id'] as String? ?? '',
    label: json['label'] as String? ?? '',
    encryptedPayload: EncryptedPayload.fromJson(payloadJson),
    kdfSalt: base64Decode(json['kdfSalt'] as String? ?? ''),
    kdfIterations: json['kdfIterations'] as int? ?? 120000,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
}
