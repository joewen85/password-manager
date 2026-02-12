import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager_app/state/sync_settings.dart';
import 'package:password_manager_app/sync/vault_sync_merger.dart';
import 'package:password_manager_core/password_manager_core.dart';
import 'package:password_manager_crypto/password_manager_crypto.dart';

VaultItem buildItem({
  required String id,
  required String label,
  required String updatedBy,
  required Map<String, int> version,
  bool isDeleted = false,
}) {
  final now = DateTime.utc(2026, 2, 12, 10, 0);
  return VaultItem(
    id: id,
    label: label,
    type: VaultEntryType.credential,
    encryptedPayload: EncryptedPayload(
      ciphertext: Uint8List.fromList([1, 2, 3, id.hashCode & 0xFF]),
      nonce: Uint8List.fromList([4, 5, 6]),
      mac: Uint8List.fromList([7, 8, 9]),
      version: 1,
    ),
    kdfSalt: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
    kdfIterations: 120000,
    createdAt: now,
    updatedAt: now.add(const Duration(minutes: 5)),
    version: version,
    updatedBy: updatedBy,
    isDeleted: isDeleted,
    deletedAt: isDeleted ? now.add(const Duration(minutes: 6)) : null,
  );
}

void main() {
  test('merge keeps additions from both sides', () {
    var counter = 0;
    final merger = VaultSyncMerger(
      idGenerator: () => 'conflict-${counter++}',
      conflictLabelBuilder: (_, __) => '(冲突)',
      conflictStrategy: ConflictStrategy.keepBoth,
    );
    final local = [
      buildItem(
        id: 'a1',
        label: 'Local',
        updatedBy: 'A',
        version: const {'A': 1},
      ),
    ];
    final remote = [
      buildItem(
        id: 'b1',
        label: 'Remote',
        updatedBy: 'B',
        version: const {'B': 1},
      ),
    ];
    final result = merger.merge(localItems: local, remoteItems: remote);
    expect(result.items.length, equals(2));
    expect(result.stats.conflicts, equals(0));
  });

  test('rename conflict produces a conflict copy', () {
    var counter = 0;
    final merger = VaultSyncMerger(
      idGenerator: () => 'conflict-${counter++}',
      conflictLabelBuilder: (_, __) => '(冲突)',
      conflictStrategy: ConflictStrategy.localWins,
    );
    final local = [
      buildItem(
        id: 'x1',
        label: 'Name-A',
        updatedBy: 'A',
        version: const {'A': 2, 'B': 1},
      ),
    ];
    final remote = [
      buildItem(
        id: 'x1',
        label: 'Name-B',
        updatedBy: 'B',
        version: const {'A': 1, 'B': 2},
      ),
    ];
    final result = merger.merge(localItems: local, remoteItems: remote);
    expect(result.stats.conflicts, equals(1));
    expect(result.items.length, equals(2));
    expect(result.items.where((item) => item.id == 'x1').length, equals(1));
    expect(result.items.any((item) => item.label.contains('Name-B')), isTrue);
  });

  test('delete vs update keeps tombstone and conflict copy', () {
    var counter = 0;
    final merger = VaultSyncMerger(
      idGenerator: () => 'conflict-${counter++}',
      conflictLabelBuilder: (_, __) => '(冲突)',
      conflictStrategy: ConflictStrategy.keepBoth,
    );
    final local = [
      buildItem(
        id: 'd1',
        label: 'Delete-Me',
        updatedBy: 'A',
        version: const {'A': 2, 'B': 1},
        isDeleted: true,
      ),
    ];
    final remote = [
      buildItem(
        id: 'd1',
        label: 'Delete-Me',
        updatedBy: 'B',
        version: const {'A': 1, 'B': 2},
      ),
    ];
    final result = merger.merge(localItems: local, remoteItems: remote);
    expect(result.stats.conflicts, equals(1));
    expect(result.items.any((item) => item.id == 'd1' && item.isDeleted),
        isTrue);
    expect(result.items.any((item) => item.id != 'd1' && !item.isDeleted),
        isTrue);
  });

  test('both delete keeps single tombstone', () {
    var counter = 0;
    final merger = VaultSyncMerger(
      idGenerator: () => 'conflict-${counter++}',
      conflictLabelBuilder: (_, __) => '(冲突)',
      conflictStrategy: ConflictStrategy.keepBoth,
    );
    final local = [
      buildItem(
        id: 'z1',
        label: 'Gone',
        updatedBy: 'A',
        version: const {'A': 2, 'B': 1},
        isDeleted: true,
      ),
    ];
    final remote = [
      buildItem(
        id: 'z1',
        label: 'Gone',
        updatedBy: 'B',
        version: const {'A': 1, 'B': 2},
        isDeleted: true,
      ),
    ];
    final result = merger.merge(localItems: local, remoteItems: remote);
    expect(result.stats.conflicts, equals(0));
    expect(result.items.length, equals(1));
    expect(result.items.single.isDeleted, isTrue);
  });
}
