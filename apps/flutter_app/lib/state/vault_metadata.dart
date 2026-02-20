import 'dart:convert';

import 'package:password_manager_crypto/password_manager_crypto.dart';

class VaultMetadata {
  const VaultMetadata({
    required this.tags,
    required this.sortOrder,
    required this.tagsUpdatedAt,
  });

  final List<String> tags;
  final VaultSortOrder sortOrder;
  final int tagsUpdatedAt;

  factory VaultMetadata.defaults() {
    return const VaultMetadata(
      tags: <String>[],
      sortOrder: VaultSortOrder.updatedDesc,
      tagsUpdatedAt: 0,
    );
  }

  VaultMetadata copyWith({
    List<String>? tags,
    VaultSortOrder? sortOrder,
    int? tagsUpdatedAt,
  }) {
    return VaultMetadata(
      tags: tags ?? this.tags,
      sortOrder: sortOrder ?? this.sortOrder,
      tagsUpdatedAt: tagsUpdatedAt ?? this.tagsUpdatedAt,
    );
  }

  Map<String, Object?> toJson() => {
        'tags': tags,
        'sortOrder': sortOrder.name,
        'tagsUpdatedAt': tagsUpdatedAt,
      };

  static VaultMetadata fromJson(Map<String, Object?> json) {
    final rawTags = (json['tags'] as List?)?.whereType<String>().toList() ?? [];
    final sortName = json['sortOrder'] as String? ?? 'updatedDesc';
    final rawUpdatedAt = json['tagsUpdatedAt'];
    final tagsUpdatedAt = rawUpdatedAt is num
        ? rawUpdatedAt.toInt()
        : int.tryParse(rawUpdatedAt?.toString() ?? '') ?? 0;
    final sortOrder = VaultSortOrder.values.firstWhere(
      (entry) => entry.name == sortName,
      orElse: () => VaultSortOrder.updatedDesc,
    );
    return VaultMetadata(
      tags: rawTags,
      sortOrder: sortOrder,
      tagsUpdatedAt: tagsUpdatedAt,
    );
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
