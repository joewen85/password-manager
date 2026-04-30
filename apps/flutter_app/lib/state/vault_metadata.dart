import 'dart:convert';

import 'package:password_manager_crypto/password_manager_crypto.dart';

class VaultMetadata {
  const VaultMetadata({
    required this.tags,
    required this.categories,
    required this.sortOrder,
    required this.tagsUpdatedAt,
    required this.categoriesUpdatedAt,
    required this.recordKeyMetadataMigrated,
  });

  final List<String> tags;
  final List<String> categories;
  final VaultSortOrder sortOrder;
  final int tagsUpdatedAt;
  final int categoriesUpdatedAt;
  final bool recordKeyMetadataMigrated;

  factory VaultMetadata.defaults() {
    return const VaultMetadata(
      tags: <String>[],
      categories: <String>[],
      sortOrder: VaultSortOrder.updatedDesc,
      tagsUpdatedAt: 0,
      categoriesUpdatedAt: 0,
      recordKeyMetadataMigrated: false,
    );
  }

  VaultMetadata copyWith({
    List<String>? tags,
    List<String>? categories,
    VaultSortOrder? sortOrder,
    int? tagsUpdatedAt,
    int? categoriesUpdatedAt,
    bool? recordKeyMetadataMigrated,
  }) {
    return VaultMetadata(
      tags: tags ?? this.tags,
      categories: categories ?? this.categories,
      sortOrder: sortOrder ?? this.sortOrder,
      tagsUpdatedAt: tagsUpdatedAt ?? this.tagsUpdatedAt,
      categoriesUpdatedAt: categoriesUpdatedAt ?? this.categoriesUpdatedAt,
      recordKeyMetadataMigrated:
          recordKeyMetadataMigrated ?? this.recordKeyMetadataMigrated,
    );
  }

  Map<String, Object?> toJson() => {
        'tags': tags,
        'categories': categories,
        'sortOrder': sortOrder.name,
        'tagsUpdatedAt': tagsUpdatedAt,
        'categoriesUpdatedAt': categoriesUpdatedAt,
        'recordKeyMetadataMigrated': recordKeyMetadataMigrated,
      };

  static VaultMetadata fromJson(Map<String, Object?> json) {
    final rawTags = (json['tags'] as List?)?.whereType<String>().toList() ?? [];
    final rawCategories =
        (json['categories'] as List?)?.whereType<String>().toList() ?? [];
    final sortName = json['sortOrder'] as String? ?? 'updatedDesc';
    final rawUpdatedAt = json['tagsUpdatedAt'];
    final tagsUpdatedAt = rawUpdatedAt is num
        ? rawUpdatedAt.toInt()
        : int.tryParse(rawUpdatedAt?.toString() ?? '') ?? 0;
    final rawCategoriesUpdatedAt = json['categoriesUpdatedAt'];
    final categoriesUpdatedAt = rawCategoriesUpdatedAt is num
        ? rawCategoriesUpdatedAt.toInt()
        : int.tryParse(rawCategoriesUpdatedAt?.toString() ?? '') ?? 0;
    final recordKeyMetadataMigrated =
        json['recordKeyMetadataMigrated'] as bool? ?? false;
    final sortOrder = VaultSortOrder.values.firstWhere(
      (entry) => entry.name == sortName,
      orElse: () => VaultSortOrder.updatedDesc,
    );
    return VaultMetadata(
      tags: rawTags,
      categories: rawCategories,
      sortOrder: sortOrder,
      tagsUpdatedAt: tagsUpdatedAt,
      categoriesUpdatedAt: categoriesUpdatedAt,
      recordKeyMetadataMigrated: recordKeyMetadataMigrated,
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
