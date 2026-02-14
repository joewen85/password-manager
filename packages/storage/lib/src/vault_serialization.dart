import 'dart:convert';

import 'package:password_manager_core/password_manager_core.dart';
import 'package:password_manager_crypto/password_manager_crypto.dart';

Map<String, Object?> vaultRecordToJson(VaultItemRecord record) => {
      'id': record.id,
      'encryptedPayload': record.encryptedPayload.toJson(),
      'encryptedMetadata': record.encryptedMetadata?.toJson(),
      'kdfSalt': base64Encode(record.kdfSalt),
      'kdfIterations': record.kdfIterations,
    };

VaultItemRecord vaultRecordFromJson(Map<String, Object?> json) {
  final payloadJson = Map<String, Object?>.from(
    json['encryptedPayload'] as Map? ?? <String, Object?>{},
  );
  final encryptedMetadataRaw = json['encryptedMetadata'];
  final encryptedMetadata = encryptedMetadataRaw is Map
      ? EncryptedPayload.fromJson(
          Map<String, Object?>.from(encryptedMetadataRaw),
        )
      : null;
  final legacyMetadata =
      encryptedMetadata == null ? _legacyMetadataFromJson(json) : null;
  return VaultItemRecord(
    id: json['id'] as String? ?? '',
    encryptedPayload: EncryptedPayload.fromJson(payloadJson),
    encryptedMetadata: encryptedMetadata,
    kdfSalt: base64Decode(json['kdfSalt'] as String? ?? ''),
    kdfIterations: json['kdfIterations'] as int? ?? 120000,
    legacyMetadata: legacyMetadata,
  );
}

Map<String, Object?> _legacyMetadataFromJson(Map<String, Object?> json) {
  return {
    'label': json['label'] as String? ?? '',
    'type': json['type'] as String? ?? 'credential',
    'createdAt': json['createdAt'] as String? ?? '',
    'updatedAt': json['updatedAt'] as String? ?? '',
    'version': _parseVersion(json['version']),
    'updatedBy': json['updatedBy'] as String? ?? 'legacy',
    'isDeleted': json['isDeleted'] as bool? ?? false,
    'deletedAt': json['deletedAt'] as String?,
  };
}

Map<String, int> _parseVersion(Object? rawVersion) {
  final rawMap = rawVersion is Map ? rawVersion : null;
  if (rawMap == null) {
    return <String, int>{};
  }
  return rawMap.map(
    (key, value) => MapEntry(
      key.toString(),
      value is int ? value : int.tryParse('$value') ?? 0,
    ),
  );
}
