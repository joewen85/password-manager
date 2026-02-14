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

    final record = VaultItemRecord(
      id: 'item-1',
      encryptedPayload: EncryptedPayload(
        ciphertext: Uint8List.fromList([1, 2, 3]),
        nonce: Uint8List.fromList([4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]),
        mac: Uint8List.fromList([7, 8, 9]),
        version: 1,
      ),
      encryptedMetadata: EncryptedPayload(
        ciphertext: Uint8List.fromList([9, 8, 7]),
        nonce: Uint8List.fromList([1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]),
        mac: Uint8List.fromList([6, 6, 6]),
        version: 1,
      ),
      kdfSalt: Uint8List.fromList(List<int>.generate(16, (i) => i)),
      kdfIterations: 1000,
    );

    await repository.save(record);

    final fetched = await repository.getById('item-1');
    expect(fetched, isNotNull);
    expect(fetched!.kdfIterations, equals(1000));

    final all = await repository.listAll();
    expect(all.length, equals(1));

    await repository.delete('item-1');
    final afterDelete = await repository.listAll();
    expect(afterDelete, isEmpty);
  });
}
