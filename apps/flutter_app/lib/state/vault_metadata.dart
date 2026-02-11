import 'dart:convert';

import 'package:password_manager_crypto/password_manager_crypto.dart';

class VaultMetadata {
  const VaultMetadata({
    required this.tags,
    required this.sortOrder,
  });

  final List<String> tags;
  final VaultSortOrder sortOrder;

  factory VaultMetadata.defaults() {
    return const VaultMetadata(
      tags: <String>[],
      sortOrder: VaultSortOrder.updatedDesc,
    );
  }

  VaultMetadata copyWith({
    List<String>? tags,
    VaultSortOrder? sortOrder,
  }) {
    return VaultMetadata(
      tags: tags ?? this.tags,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }

  Map<String, Object?> toJson() => {
        'tags': tags,
        'sortOrder': sortOrder.name,
      };

  static VaultMetadata fromJson(Map<String, Object?> json) {
    final rawTags = (json['tags'] as List?)?.whereType<String>().toList() ?? [];
    final sortName = json['sortOrder'] as String? ?? 'updatedDesc';
    final sortOrder = VaultSortOrder.values.firstWhere(
      (entry) => entry.name == sortName,
      orElse: () => VaultSortOrder.updatedDesc,
    );
    return VaultMetadata(tags: rawTags, sortOrder: sortOrder);
  }
}

enum VaultSortOrder { updatedDesc, labelAsc }

class VaultMetadataRecord {
  const VaultMetadataRecord({
    required this.encryptedPayload,
    required this.kdfSalt,
    required this.kdfIterations,
  });

  final EncryptedPayload encryptedPayload;
  final List<int> kdfSalt;
  final int kdfIterations;

  Map<String, Object?> toJson() => {
        'encryptedPayload': encryptedPayload.toJson(),
        'kdfSalt': base64Encode(kdfSalt),
        'kdfIterations': kdfIterations,
      };

  static VaultMetadataRecord fromJson(Map<String, Object?> json) {
    return VaultMetadataRecord(
      encryptedPayload: EncryptedPayload.fromJson(
        Map<String, Object?>.from(json['encryptedPayload'] as Map? ?? {}),
      ),
      kdfSalt: base64Decode(json['kdfSalt'] as String? ?? ''),
      kdfIterations: json['kdfIterations'] as int? ?? 120000,
    );
  }
}
