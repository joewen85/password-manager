import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:password_manager_crypto/password_manager_crypto.dart';
import 'package:uuid/uuid.dart';

import '../models/credential_payload.dart';
import '../models/service_payload.dart';
import '../models/server_asset_payload.dart';
import '../models/vault_entry_type.dart';
import '../models/vault_item.dart';

abstract class VaultRepository {
  Future<void> save(VaultItemRecord item);
  Future<void> saveAll(List<VaultItemRecord> items);
  Future<VaultItemRecord?> getById(String id);
  Future<List<VaultItemRecord>> listAll();
  Future<void> delete(String id);
}

class VaultService {
  VaultService({
    required CryptoService cryptoService,
    required KeyDerivationService keyDerivationService,
    required VaultRepository repository,
  })  : _cryptoService = cryptoService,
        _keyDerivationService = keyDerivationService,
        _repository = repository,
        _uuid = const Uuid();

  final CryptoService _cryptoService;
  final KeyDerivationService _keyDerivationService;
  final VaultRepository _repository;
  final Uuid _uuid;
  Uint8List? _sessionMetadataKey;
  bool _allowSessionKeyForEncryption = true;

  void setSessionMetadataKey(
    Uint8List? keyBytes, {
    bool allowEncryption = true,
  }) {
    if (keyBytes == null) {
      _sessionMetadataKey = null;
      _allowSessionKeyForEncryption = true;
      return;
    }
    _sessionMetadataKey = Uint8List.fromList(keyBytes);
    _allowSessionKeyForEncryption = allowEncryption;
  }

  Future<List<VaultItemRecord>> listAllRecords() => _repository.listAll();

  Future<VaultItemRecord?> getRecordById(String id) => _repository.getById(id);

  Future<List<VaultItem>> listAll({required String masterPassword}) async {
    final records = await _repository.listAll();
    return decryptRecords(records, masterPassword: masterPassword);
  }

  Future<VaultItem?> getById(
    String id, {
    required String masterPassword,
  }) async {
    final record = await _repository.getById(id);
    if (record == null) {
      return null;
    }
    return decryptRecord(record, masterPassword: masterPassword);
  }

  Future<void> delete(String id) => _repository.delete(id);

  Future<void> saveRecord(VaultItemRecord record) => _repository.save(record);

  Future<void> saveRecords(List<VaultItemRecord> records) async {
    await _repository.saveAll(records);
  }

  Future<VaultItem> addCredential(
    CredentialPayload payload, {
    required String label,
    required String masterPassword,
    required Uint8List nonce,
    Map<String, int>? version,
    String? updatedBy,
    bool isDeleted = false,
    DateTime? deletedAt,
  }) async {
    final derivedKey = await _keyDerivationService.deriveKey(masterPassword);
    final jsonPayload = jsonEncode(payload.toJson());
    final encrypted = await _cryptoService.encrypt(
      Uint8List.fromList(utf8.encode(jsonPayload)),
      derivedKey.bytes,
      nonce: nonce,
    );
    final now = DateTime.now().toUtc();
    final encryptedMetadata = await _encryptMetadata(
      _metadataToJson(
        label: label,
        type: VaultEntryType.credential,
        createdAt: now,
        updatedAt: now,
        version: version ?? const <String, int>{},
        updatedBy: updatedBy ?? 'legacy',
        isDeleted: isDeleted,
        deletedAt: deletedAt,
      ),
      _metadataKeyBytes(derivedKey.bytes),
    );
    final item = VaultItem(
      id: _uuid.v4(),
      label: label,
      type: VaultEntryType.credential,
      encryptedPayload: encrypted,
      kdfSalt: derivedKey.salt,
      kdfIterations: derivedKey.iterations,
      createdAt: now,
      updatedAt: now,
      version: version ?? const <String, int>{},
      updatedBy: updatedBy ?? 'legacy',
      isDeleted: isDeleted,
      deletedAt: deletedAt,
    );
    final record = VaultItemRecord(
      id: item.id,
      encryptedPayload: encrypted,
      encryptedMetadata: encryptedMetadata,
      kdfSalt: derivedKey.salt,
      kdfIterations: derivedKey.iterations,
    );
    await _repository.save(record);
    return item;
  }

  Future<CredentialPayload?> readCredential(
    VaultItem item, {
    required String masterPassword,
  }) async {
    final decoded = await _decryptPayload(item, masterPassword);
    if (decoded == null) {
      return null;
    }
    return CredentialPayload.fromJson(decoded);
  }

  Future<void> saveItem(
    VaultItem item, {
    required String masterPassword,
  }) async {
    final record = await encryptRecord(item, masterPassword: masterPassword);
    await _repository.save(record);
  }

  Future<ServerAssetPayload?> readServerAsset(
    VaultItem item, {
    required String masterPassword,
  }) async {
    final decoded = await _decryptPayload(item, masterPassword);
    if (decoded == null) {
      return null;
    }
    return ServerAssetPayload.fromJson(decoded);
  }

  Future<ServicePayload?> readService(
    VaultItem item, {
    required String masterPassword,
  }) async {
    final decoded = await _decryptPayload(item, masterPassword);
    if (decoded == null) {
      return null;
    }
    return ServicePayload.fromJson(decoded);
  }

  Future<VaultItem> updateCredential(
    VaultItem item,
    CredentialPayload payload, {
    required String label,
    required String masterPassword,
    required Uint8List nonce,
    Map<String, int>? version,
    String? updatedBy,
    bool? isDeleted,
    DateTime? deletedAt,
  }) async {
    return _updateItem(
      item,
      label: label,
      type: VaultEntryType.credential,
      payload: payload.toJson(),
      masterPassword: masterPassword,
      nonce: nonce,
      version: version,
      updatedBy: updatedBy,
      isDeleted: isDeleted,
      deletedAt: deletedAt,
    );
  }

  Future<VaultItem> addServerAsset(
    ServerAssetPayload payload, {
    required String label,
    required String masterPassword,
    required Uint8List nonce,
    Map<String, int>? version,
    String? updatedBy,
    bool isDeleted = false,
    DateTime? deletedAt,
  }) async {
    final derivedKey = await _keyDerivationService.deriveKey(masterPassword);
    final jsonPayload = jsonEncode(payload.toJson());
    final encrypted = await _cryptoService.encrypt(
      Uint8List.fromList(utf8.encode(jsonPayload)),
      derivedKey.bytes,
      nonce: nonce,
    );
    final now = DateTime.now().toUtc();
    final encryptedMetadata = await _encryptMetadata(
      _metadataToJson(
        label: label,
        type: VaultEntryType.server,
        createdAt: now,
        updatedAt: now,
        version: version ?? const <String, int>{},
        updatedBy: updatedBy ?? 'legacy',
        isDeleted: isDeleted,
        deletedAt: deletedAt,
      ),
      _metadataKeyBytes(derivedKey.bytes),
    );
    final item = VaultItem(
      id: _uuid.v4(),
      label: label,
      type: VaultEntryType.server,
      encryptedPayload: encrypted,
      kdfSalt: derivedKey.salt,
      kdfIterations: derivedKey.iterations,
      createdAt: now,
      updatedAt: now,
      version: version ?? const <String, int>{},
      updatedBy: updatedBy ?? 'legacy',
      isDeleted: isDeleted,
      deletedAt: deletedAt,
    );
    final record = VaultItemRecord(
      id: item.id,
      encryptedPayload: encrypted,
      encryptedMetadata: encryptedMetadata,
      kdfSalt: derivedKey.salt,
      kdfIterations: derivedKey.iterations,
    );
    await _repository.save(record);
    return item;
  }

  Future<VaultItem> addService(
    ServicePayload payload, {
    required String label,
    required String masterPassword,
    required Uint8List nonce,
    Map<String, int>? version,
    String? updatedBy,
    bool isDeleted = false,
    DateTime? deletedAt,
  }) async {
    final derivedKey = await _keyDerivationService.deriveKey(masterPassword);
    final jsonPayload = jsonEncode(payload.toJson());
    final encrypted = await _cryptoService.encrypt(
      Uint8List.fromList(utf8.encode(jsonPayload)),
      derivedKey.bytes,
      nonce: nonce,
    );
    final now = DateTime.now().toUtc();
    final encryptedMetadata = await _encryptMetadata(
      _metadataToJson(
        label: label,
        type: VaultEntryType.service,
        createdAt: now,
        updatedAt: now,
        version: version ?? const <String, int>{},
        updatedBy: updatedBy ?? 'legacy',
        isDeleted: isDeleted,
        deletedAt: deletedAt,
      ),
      _metadataKeyBytes(derivedKey.bytes),
    );
    final item = VaultItem(
      id: _uuid.v4(),
      label: label,
      type: VaultEntryType.service,
      encryptedPayload: encrypted,
      kdfSalt: derivedKey.salt,
      kdfIterations: derivedKey.iterations,
      createdAt: now,
      updatedAt: now,
      version: version ?? const <String, int>{},
      updatedBy: updatedBy ?? 'legacy',
      isDeleted: isDeleted,
      deletedAt: deletedAt,
    );
    final record = VaultItemRecord(
      id: item.id,
      encryptedPayload: encrypted,
      encryptedMetadata: encryptedMetadata,
      kdfSalt: derivedKey.salt,
      kdfIterations: derivedKey.iterations,
    );
    await _repository.save(record);
    return item;
  }

  Future<VaultItem> updateServerAsset(
    VaultItem item,
    ServerAssetPayload payload, {
    required String label,
    required String masterPassword,
    required Uint8List nonce,
    Map<String, int>? version,
    String? updatedBy,
    bool? isDeleted,
    DateTime? deletedAt,
  }) async {
    return _updateItem(
      item,
      label: label,
      type: VaultEntryType.server,
      payload: payload.toJson(),
      masterPassword: masterPassword,
      nonce: nonce,
      version: version,
      updatedBy: updatedBy,
      isDeleted: isDeleted,
      deletedAt: deletedAt,
    );
  }

  Future<VaultItem> updateService(
    VaultItem item,
    ServicePayload payload, {
    required String label,
    required String masterPassword,
    required Uint8List nonce,
    Map<String, int>? version,
    String? updatedBy,
    bool? isDeleted,
    DateTime? deletedAt,
  }) async {
    return _updateItem(
      item,
      label: label,
      type: VaultEntryType.service,
      payload: payload.toJson(),
      masterPassword: masterPassword,
      nonce: nonce,
      version: version,
      updatedBy: updatedBy,
      isDeleted: isDeleted,
      deletedAt: deletedAt,
    );
  }

  Future<Map<String, Object?>?> _decryptPayload(
    VaultItem item,
    String masterPassword,
  ) async {
    final derivedKey = await _keyDerivationService.deriveKey(
      masterPassword,
      salt: Uint8List.fromList(item.kdfSalt),
      iterations: item.kdfIterations,
    );
    final decryptedBytes = await _cryptoService.decrypt(
      item.encryptedPayload,
      derivedKey.bytes,
    );
    final decoded = jsonDecode(utf8.decode(decryptedBytes));
    if (decoded is! Map) {
      return null;
    }
    return Map<String, Object?>.from(decoded);
  }

  Future<VaultItem> decryptRecord(
    VaultItemRecord record, {
    required String masterPassword,
  }) async {
    final metadata = await _decryptMetadata(record, masterPassword);
    return _itemFromMetadata(record, metadata);
  }

  Future<List<VaultItem>> decryptRecords(
    List<VaultItemRecord> records, {
    required String masterPassword,
  }) async {
    final items = <VaultItem>[];
    for (final record in records) {
      items.add(await decryptRecord(record, masterPassword: masterPassword));
    }
    return items;
  }

  Future<VaultItemRecord> encryptRecord(
    VaultItem item, {
    required String masterPassword,
  }) async {
    Uint8List metadataKey;
    if (_sessionMetadataKey != null && _allowSessionKeyForEncryption) {
      metadataKey = _sessionMetadataKey!;
    } else {
      final derivedKey = await _keyDerivationService.deriveKey(
        masterPassword,
        salt: Uint8List.fromList(item.kdfSalt),
        iterations: item.kdfIterations,
      );
      metadataKey = derivedKey.bytes;
    }
    final encryptedMetadata = await _encryptMetadata(
      _metadataToJson(
        label: item.label,
        type: item.type,
        createdAt: item.createdAt,
        updatedAt: item.updatedAt,
        version: item.version,
        updatedBy: item.updatedBy,
        isDeleted: item.isDeleted,
        deletedAt: item.deletedAt,
      ),
      _metadataKeyBytes(metadataKey),
    );
    return VaultItemRecord(
      id: item.id,
      encryptedPayload: item.encryptedPayload,
      encryptedMetadata: encryptedMetadata,
      kdfSalt: item.kdfSalt,
      kdfIterations: item.kdfIterations,
    );
  }

  Future<int> migrateLegacyRecords(String masterPassword) async {
    final records = await _repository.listAll();
    var migrated = 0;
    for (final record in records) {
      if (record.encryptedMetadata == null) {
        final metadata = record.legacyMetadata;
        if (metadata == null) {
          continue;
        }
        final upgraded = await _encryptMetadataForRecord(
          record,
          metadata,
          masterPassword,
        );
        await _repository.save(upgraded);
        migrated += 1;
        continue;
      }
      if (_sessionMetadataKey == null) {
        continue;
      }
      final encryptedMetadata = record.encryptedMetadata!;
      try {
        await _cryptoService.decrypt(
          encryptedMetadata,
          _sessionMetadataKey!,
        );
        continue;
      } catch (_) {}
      final metadata = await _decryptMetadata(record, masterPassword);
      final upgraded = await _encryptMetadataForRecord(
        record,
        metadata,
        masterPassword,
      );
      await _repository.save(upgraded);
      migrated += 1;
    }
    return migrated;
  }

  Future<VaultItem> _updateItem(
    VaultItem item, {
    required String label,
    required VaultEntryType type,
    required Map<String, Object?> payload,
    required String masterPassword,
    required Uint8List nonce,
    Map<String, int>? version,
    String? updatedBy,
    bool? isDeleted,
    DateTime? deletedAt,
  }) async {
    final derivedKey = await _keyDerivationService.deriveKey(masterPassword);
    final jsonPayload = jsonEncode(payload);
    final encrypted = await _cryptoService.encrypt(
      Uint8List.fromList(utf8.encode(jsonPayload)),
      derivedKey.bytes,
      nonce: nonce,
    );
    final now = DateTime.now().toUtc();
    final updated = VaultItem(
      id: item.id,
      label: label,
      type: type,
      encryptedPayload: encrypted,
      kdfSalt: derivedKey.salt,
      kdfIterations: derivedKey.iterations,
      createdAt: item.createdAt,
      updatedAt: now,
      version: version ?? item.version,
      updatedBy: updatedBy ?? item.updatedBy,
      isDeleted: isDeleted ?? item.isDeleted,
      deletedAt: deletedAt ?? item.deletedAt,
    );
    final encryptedMetadata = await _encryptMetadata(
      _metadataToJson(
        label: updated.label,
        type: updated.type,
        createdAt: updated.createdAt,
        updatedAt: updated.updatedAt,
        version: updated.version,
        updatedBy: updated.updatedBy,
        isDeleted: updated.isDeleted,
        deletedAt: updated.deletedAt,
      ),
      _metadataKeyBytes(derivedKey.bytes),
    );
    final record = VaultItemRecord(
      id: updated.id,
      encryptedPayload: encrypted,
      encryptedMetadata: encryptedMetadata,
      kdfSalt: derivedKey.salt,
      kdfIterations: derivedKey.iterations,
    );
    await _repository.save(record);
    return updated;
  }

  Future<Map<String, Object?>> _decryptMetadata(
    VaultItemRecord record,
    String masterPassword,
  ) async {
    if (record.encryptedMetadata == null) {
      return Map<String, Object?>.from(record.legacyMetadata ?? {});
    }
    final encryptedMetadata = record.encryptedMetadata!;
    final sessionKey = _sessionMetadataKey;
    if (sessionKey != null) {
      try {
        final decryptedBytes = await _cryptoService.decrypt(
          encryptedMetadata,
          sessionKey,
        );
        final decoded = jsonDecode(utf8.decode(decryptedBytes));
        if (decoded is Map) {
          return Map<String, Object?>.from(decoded);
        }
      } catch (_) {}
    }
    final derivedKey = await _keyDerivationService.deriveKey(
      masterPassword,
      salt: Uint8List.fromList(record.kdfSalt),
      iterations: record.kdfIterations,
    );
    final decryptedBytes = await _cryptoService.decrypt(
      encryptedMetadata,
      derivedKey.bytes,
    );
    final decoded = jsonDecode(utf8.decode(decryptedBytes));
    if (decoded is! Map) {
      return <String, Object?>{};
    }
    return Map<String, Object?>.from(decoded);
  }

  VaultItem _itemFromMetadata(
    VaultItemRecord record,
    Map<String, Object?> metadata,
  ) {
    final typeName = metadata['type'] as String? ?? 'credential';
    final type = VaultEntryType.values.firstWhere(
      (entry) => entry.name == typeName,
      orElse: () => VaultEntryType.credential,
    );
    final rawVersion = metadata['version'];
    final version = rawVersion is Map
        ? rawVersion.map(
            (key, value) => MapEntry(
              key.toString(),
              value is int ? value : int.tryParse('$value') ?? 0,
            ),
          )
        : <String, int>{};
    return VaultItem(
      id: record.id,
      label: metadata['label'] as String? ?? '',
      type: type,
      encryptedPayload: record.encryptedPayload,
      kdfSalt: record.kdfSalt,
      kdfIterations: record.kdfIterations,
      createdAt:
          DateTime.tryParse(metadata['createdAt'] as String? ?? '')?.toUtc() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      updatedAt:
          DateTime.tryParse(metadata['updatedAt'] as String? ?? '')?.toUtc() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      version: version,
      updatedBy: metadata['updatedBy'] as String? ?? 'legacy',
      isDeleted: metadata['isDeleted'] as bool? ?? false,
      deletedAt:
          DateTime.tryParse(metadata['deletedAt'] as String? ?? '')?.toUtc(),
    );
  }

  Map<String, Object?> _metadataToJson({
    required String label,
    required VaultEntryType type,
    required DateTime createdAt,
    required DateTime updatedAt,
    required Map<String, int> version,
    required String updatedBy,
    required bool isDeleted,
    required DateTime? deletedAt,
  }) {
    return {
      'schemaVersion': 1,
      'label': label,
      'type': type.name,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'version': version,
      'updatedBy': updatedBy,
      'isDeleted': isDeleted,
      'deletedAt': deletedAt?.toIso8601String(),
    };
  }

  Future<EncryptedPayload> _encryptMetadata(
    Map<String, Object?> metadata,
    Uint8List keyBytes,
  ) async {
    final jsonPayload = jsonEncode(metadata);
    return _cryptoService.encrypt(
      Uint8List.fromList(utf8.encode(jsonPayload)),
      keyBytes,
      nonce: _generateNonce(),
    );
  }

  Future<VaultItemRecord> _encryptMetadataForRecord(
    VaultItemRecord record,
    Map<String, Object?> metadata,
    String masterPassword,
  ) async {
    final encryptedMetadata = await _encryptMetadata(
      metadata,
      await _metadataKeyForRecord(record, masterPassword),
    );
    return VaultItemRecord(
      id: record.id,
      encryptedPayload: record.encryptedPayload,
      encryptedMetadata: encryptedMetadata,
      kdfSalt: record.kdfSalt,
      kdfIterations: record.kdfIterations,
    );
  }

  Uint8List _metadataKeyBytes(Uint8List recordKey) {
    if (_sessionMetadataKey == null || !_allowSessionKeyForEncryption) {
      return recordKey;
    }
    return _sessionMetadataKey!;
  }

  Future<Uint8List> _metadataKeyForRecord(
    VaultItemRecord record,
    String masterPassword,
  ) async {
    final sessionKey = _sessionMetadataKey;
    if (sessionKey != null && _allowSessionKeyForEncryption) {
      return sessionKey;
    }
    final derivedKey = await _keyDerivationService.deriveKey(
      masterPassword,
      salt: Uint8List.fromList(record.kdfSalt),
      iterations: record.kdfIterations,
    );
    return derivedKey.bytes;
  }

  Future<int> migrateMetadataToRecordKey(String masterPassword) async {
    final records = await _repository.listAll();
    var migrated = 0;
    for (final record in records) {
      Map<String, Object?> metadata;
      try {
        metadata = await _decryptMetadata(record, masterPassword);
      } catch (_) {
        continue;
      }
      final derivedKey = await _keyDerivationService.deriveKey(
        masterPassword,
        salt: Uint8List.fromList(record.kdfSalt),
        iterations: record.kdfIterations,
      );
      final encryptedMetadata = await _encryptMetadata(
        metadata,
        derivedKey.bytes,
      );
      final updated = VaultItemRecord(
        id: record.id,
        encryptedPayload: record.encryptedPayload,
        encryptedMetadata: encryptedMetadata,
        kdfSalt: record.kdfSalt,
        kdfIterations: record.kdfIterations,
      );
      await _repository.save(updated);
      migrated += 1;
    }
    return migrated;
  }

  Uint8List _generateNonce() {
    final random = Random.secure();
    final bytes = List<int>.generate(12, (_) => random.nextInt(256));
    return Uint8List.fromList(bytes);
  }
}
