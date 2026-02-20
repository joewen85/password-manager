import 'dart:typed_data';

import 'package:password_manager_core/password_manager_core.dart';
import 'package:password_manager_crypto/password_manager_crypto.dart';
import 'package:test/test.dart';

class InMemoryVaultRepository implements VaultRepository {
  final Map<String, VaultItemRecord> _store = {};

  @override
  Future<void> delete(String id) async {
    _store.remove(id);
  }

  @override
  Future<VaultItemRecord?> getById(String id) async => _store[id];

  @override
  Future<List<VaultItemRecord>> listAll() async => _store.values.toList();

  @override
  Future<void> save(VaultItemRecord item) async {
    _store[item.id] = item;
  }

  @override
  Future<void> saveAll(List<VaultItemRecord> items) async {
    for (final item in items) {
      _store[item.id] = item;
    }
  }
}

void main() {
  test('adds and reads credential with encryption', () async {
    final repository = InMemoryVaultRepository();
    final service = VaultService(
      cryptoService: AesGcmCryptoService(),
      keyDerivationService: KeyDerivationService(iterations: 1000),
      repository: repository,
    );

    final payload = CredentialPayload(
      username: 'user',
      password: 'pass',
      token: 'token',
      appId: 'app',
      accessToken: 'access',
      secretKey: 'secret',
      notes: 'notes',
      tags: const [],
    );

    final item = await service.addCredential(
      payload,
      label: 'Test',
      masterPassword: 'master',
      nonce: Uint8List.fromList(List<int>.generate(12, (i) => i)),
    );

    final stored = await repository.getById(item.id);
    expect(stored, isNotNull);

    final decryptedItem = await service.decryptRecord(
      stored!,
      masterPassword: 'master',
    );
    final decrypted = await service.readCredential(
      decryptedItem,
      masterPassword: 'master',
    );

    expect(decrypted, isNotNull);
    expect(decrypted!.username, equals('user'));
    expect(decrypted.password, equals('pass'));
  });

  test('read with wrong password fails', () async {
    final repository = InMemoryVaultRepository();
    final service = VaultService(
      cryptoService: AesGcmCryptoService(),
      keyDerivationService: KeyDerivationService(iterations: 1000),
      repository: repository,
    );

    final payload = CredentialPayload(
      username: 'user',
      password: 'pass',
      token: 'token',
      appId: 'app',
      accessToken: 'access',
      secretKey: 'secret',
      notes: 'notes',
      tags: const [],
    );

    final item = await service.addCredential(
      payload,
      label: 'Test',
      masterPassword: 'master',
      nonce: Uint8List.fromList(List<int>.generate(12, (i) => i + 1)),
    );

    expect(
      () => service.readCredential(item, masterPassword: 'wrong'),
      throwsA(isA<Exception>()),
    );
  });
}
