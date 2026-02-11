import 'dart:io';
import 'dart:typed_data';

import 'package:password_manager_core/password_manager_core.dart';
import 'package:password_manager_crypto/password_manager_crypto.dart';
import 'package:password_manager_storage/password_manager_storage.dart';
import 'package:test/test.dart';

void main() {
  test('saves and loads vault items from file', () async {
    final directory = await Directory.systemTemp.createTemp('vault_test_');
    final filePath = '${directory.path}/vault.json';
    final repository = LocalFileVaultRepository(filePath: filePath);

    final item = VaultItem(
      id: 'item-1',
      label: 'Sample',
      type: VaultEntryType.credential,
      encryptedPayload: EncryptedPayload(
        ciphertext: Uint8List.fromList([1, 2, 3]),
        nonce: Uint8List.fromList([4, 5, 6]),
        mac: Uint8List.fromList([7, 8, 9]),
        version: 1,
      ),
      kdfSalt: Uint8List.fromList(List<int>.generate(16, (i) => i)),
      kdfIterations: 1000,
      createdAt: DateTime.utc(2024, 1, 1),
      updatedAt: DateTime.utc(2024, 1, 2),
    );

    await repository.save(item);

    final fetched = await repository.getById('item-1');
    expect(fetched, isNotNull);
    expect(fetched!.label, equals('Sample'));

    final all = await repository.listAll();
    expect(all.length, equals(1));

    await repository.delete('item-1');
    final afterDelete = await repository.listAll();
    expect(afterDelete, isEmpty);
  });
}
