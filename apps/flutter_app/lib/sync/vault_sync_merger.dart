import 'package:password_manager_core/password_manager_core.dart';

import '../state/sync_settings.dart';

enum VersionComparison {
  equal,
  localDominates,
  remoteDominates,
  concurrent,
}

typedef IdGenerator = String Function();

typedef ConflictLabelBuilder = String Function(VaultItem item, bool isRemote);

class MergeStats {
  const MergeStats({
    required this.total,
    required this.conflicts,
    required this.deletes,
  });

  final int total;
  final int conflicts;
  final int deletes;
}

class MergeResult {
  const MergeResult({
    required this.items,
    required this.stats,
  });

  final List<VaultItem> items;
  final MergeStats stats;
}

class VaultSyncMerger {
  VaultSyncMerger({
    required this.idGenerator,
    required this.conflictLabelBuilder,
    required this.conflictStrategy,
  });

  final IdGenerator idGenerator;
  final ConflictLabelBuilder conflictLabelBuilder;
  final ConflictStrategy conflictStrategy;

  MergeResult merge({
    required List<VaultItem> localItems,
    required List<VaultItem> remoteItems,
  }) {
    final merged = <VaultItem>[];
    var conflicts = 0;
    var deletes = 0;

    void addItem(VaultItem item) {
      merged.add(item);
      if (item.isDeleted) {
        deletes += 1;
      }
    }

    final versionCache = <String, Map<String, int>>{};
    Map<String, int> effectiveVersion(VaultItem item) {
      if (item.version.isNotEmpty) {
        return item.version;
      }
      return versionCache.putIfAbsent(item.id, () {
        final updater = item.updatedBy.isEmpty ? 'legacy' : item.updatedBy;
        return {updater: 1};
      });
    }

    final localMap = {
      for (final item in localItems) item.id: item,
    };
    final remoteMap = {
      for (final item in remoteItems) item.id: item,
    };

    for (final entry in localMap.entries) {
      final local = entry.value;
      final remote = remoteMap.remove(entry.key);
      if (remote == null) {
        addItem(local);
        continue;
      }

      final comparison =
          compareVersion(effectiveVersion(local), effectiveVersion(remote));
      if (comparison == VersionComparison.equal) {
        final picked = _pickLatest(local, remote);
        addItem(picked);
        continue;
      }

      if (comparison == VersionComparison.localDominates) {
        addItem(local);
        continue;
      }

      if (comparison == VersionComparison.remoteDominates) {
        addItem(remote);
        continue;
      }

      // concurrent updates
      if (local.isDeleted != remote.isDeleted) {
        conflicts += 1;
        final deleted = local.isDeleted ? local : remote;
        final active = local.isDeleted ? remote : local;
        addItem(deleted);
        merged.add(_conflictClone(active, isRemote: active == remote));
        continue;
      }
      if (_isSamePayload(local, remote)) {
        final picked = _pickLatest(local, remote);
        addItem(picked);
        continue;
      }

      conflicts += 1;
      final primary = _choosePrimary(local, remote);
      final secondary = primary == local ? remote : local;
      merged.add(primary);
      merged.add(_conflictClone(secondary, isRemote: secondary == remote));
    }

    for (final remote in remoteMap.values) {
      addItem(remote);
    }

    return MergeResult(
      items: merged,
      stats: MergeStats(
        total: merged.length,
        conflicts: conflicts,
        deletes: deletes,
      ),
    );
  }

  static VersionComparison compareVersion(
    Map<String, int> local,
    Map<String, int> remote,
  ) {
    var localGreater = false;
    var remoteGreater = false;
    final allKeys = {...local.keys, ...remote.keys};
    for (final key in allKeys) {
      final localValue = local[key] ?? 0;
      final remoteValue = remote[key] ?? 0;
      if (localValue > remoteValue) {
        localGreater = true;
      } else if (remoteValue > localValue) {
        remoteGreater = true;
      }
      if (localGreater && remoteGreater) {
        return VersionComparison.concurrent;
      }
    }
    if (!localGreater && !remoteGreater) {
      return VersionComparison.equal;
    }
    if (localGreater && !remoteGreater) {
      return VersionComparison.localDominates;
    }
    if (!localGreater && remoteGreater) {
      return VersionComparison.remoteDominates;
    }
    return VersionComparison.concurrent;
  }

  VaultItem _pickLatest(VaultItem local, VaultItem remote) {
    if (local.updatedAt.isAtSameMomentAs(remote.updatedAt)) {
      return local;
    }
    return local.updatedAt.isAfter(remote.updatedAt) ? local : remote;
  }

  bool _isSamePayload(VaultItem local, VaultItem remote) {
    if (local.label != remote.label) {
      return false;
    }
    if (local.type != remote.type) {
      return false;
    }
    if (local.isDeleted != remote.isDeleted) {
      return false;
    }
    if (local.kdfIterations != remote.kdfIterations) {
      return false;
    }
    if (local.metadataCategory != remote.metadataCategory) {
      return false;
    }
    if (!_sameStringList(local.metadataTags, remote.metadataTags)) {
      return false;
    }
    if (local.encryptedPayload.version != remote.encryptedPayload.version) {
      return false;
    }
    return _bytesEqual(local.encryptedPayload.ciphertext,
            remote.encryptedPayload.ciphertext) &&
        _bytesEqual(
            local.encryptedPayload.nonce, remote.encryptedPayload.nonce) &&
        _bytesEqual(local.encryptedPayload.mac, remote.encryptedPayload.mac);
  }

  bool _sameStringList(List<String> a, List<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  VaultItem _choosePrimary(VaultItem local, VaultItem remote) {
    switch (conflictStrategy) {
      case ConflictStrategy.localWins:
        return local;
      case ConflictStrategy.remoteWins:
        return remote;
      case ConflictStrategy.keepBoth:
        return _pickLatest(local, remote);
    }
  }

  VaultItem _conflictClone(VaultItem source, {required bool isRemote}) {
    final labelSuffix = conflictLabelBuilder(source, isRemote);
    final now = DateTime.now().toUtc();
    final updatedBy = source.updatedBy.isEmpty ? 'legacy' : source.updatedBy;
    final baseVersion =
        source.version.isNotEmpty ? source.version[updatedBy] ?? 1 : 1;
    return VaultItem(
      id: idGenerator(),
      label: '${source.label} $labelSuffix',
      type: source.type,
      encryptedPayload: source.encryptedPayload,
      kdfSalt: source.kdfSalt,
      kdfIterations: source.kdfIterations,
      createdAt: now,
      updatedAt: source.updatedAt,
      version: {updatedBy: baseVersion},
      updatedBy: updatedBy,
      isDeleted: source.isDeleted,
      deletedAt: source.deletedAt,
      metadataCategory: source.metadataCategory,
      metadataTags: source.metadataTags,
    );
  }
}
