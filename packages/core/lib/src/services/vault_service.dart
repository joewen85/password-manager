import 'dart:convert';
import 'dart:typed_data';

import 'package:password_manager_crypto/password_manager_crypto.dart';
import 'package:uuid/uuid.dart';

import '../models/credential_payload.dart';
import '../models/server_asset_payload.dart';
import '../models/vault_entry_type.dart';
import '../models/vault_item.dart';

abstract class VaultRepository {
  Future<void> save(VaultItem item);
  Future<VaultItem?> getById(String id);
  Future<List<VaultItem>> listAll();
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
    await _repository.save(item);
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

  Future<List<VaultItem>> listAll() => _repository.listAll();

  Future<VaultItem?> getById(String id) => _repository.getById(id);

  Future<void> delete(String id) => _repository.delete(id);

  Future<void> saveItem(VaultItem item) => _repository.save(item);

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
    await _repository.save(item);
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
    await _repository.save(updated);
    return updated;
  }
}
