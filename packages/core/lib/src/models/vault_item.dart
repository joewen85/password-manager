import 'package:password_manager_crypto/password_manager_crypto.dart';

import 'vault_entry_type.dart';

class VaultItem {
  const VaultItem({
    required this.id,
    required this.label,
    required this.type,
    required this.encryptedPayload,
    required this.kdfSalt,
    required this.kdfIterations,
    required this.createdAt,
    required this.updatedAt,
    this.version = const <String, int>{},
    this.updatedBy = 'legacy',
    this.isDeleted = false,
    this.deletedAt,
  });

  final String id;
  final String label;
  final VaultEntryType type;
  final EncryptedPayload encryptedPayload;
  final List<int> kdfSalt;
  final int kdfIterations;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, int> version;
  final String updatedBy;
  final bool isDeleted;
  final DateTime? deletedAt;
}

class VaultItemRecord {
  const VaultItemRecord({
    required this.id,
    required this.encryptedPayload,
    required this.kdfSalt,
    required this.kdfIterations,
    this.encryptedMetadata,
    this.legacyMetadata,
  });

  final String id;
  final EncryptedPayload encryptedPayload;
  final EncryptedPayload? encryptedMetadata;
  final List<int> kdfSalt;
  final int kdfIterations;
  final Map<String, Object?>? legacyMetadata;
}
