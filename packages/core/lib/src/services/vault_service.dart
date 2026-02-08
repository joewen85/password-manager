import 'dart:convert';
import 'dart:typed_data';

import 'package:password_manager_crypto/password_manager_crypto.dart';
import 'package:uuid/uuid.dart';

import '../models/credential_payload.dart';
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
      encryptedPayload: encrypted,
      createdAt: now,
      updatedAt: now,
    );
    await _repository.save(item);
    return item;
  }

  Future<CredentialPayload?> readCredential(
    VaultItem item, {
    required String masterPassword,
  }) async {
    final derivedKey = await _keyDerivationService.deriveKey(masterPassword);
    final decryptedBytes = await _cryptoService.decrypt(
      item.encryptedPayload,
      derivedKey.bytes,
    );
    final decoded = jsonDecode(utf8.decode(decryptedBytes));
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    return CredentialPayload.fromJson(decoded);
  }
}
