import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:password_manager_auth/password_manager_auth.dart';
import 'package:password_manager_backup/password_manager_backup.dart';
import 'package:password_manager_core/password_manager_core.dart';
import 'package:password_manager_crypto/password_manager_crypto.dart';
import 'package:password_manager_storage/password_manager_storage.dart';

import '../storage/sync_settings_store.dart';
import '../storage/vault_metadata_store.dart';
import '../sync/remote_sync_client.dart';
import '../sync/vault_sync_merger.dart';
import 'sync_settings.dart';
import 'vault_metadata.dart';

class VaultController extends ChangeNotifier {
  VaultController({
    required VaultService vaultService,
    required BackupService backupService,
    required CryptoService cryptoService,
    required TotpService totpService,
    required KeyDerivationService keyDerivationService,
    required MasterKeyStore masterKeyStore,
    required SyncSettingsStore syncSettingsStore,
    required SyncSettings initialSyncSettings,
    required VaultMetadataStore vaultMetadataStore,
    required VaultMetadata initialMetadata,
    required bool requireTotp,
    required String? totpSecret,
  })  : _vaultService = vaultService,
        _backupService = backupService,
        _cryptoService = cryptoService,
        _totpService = totpService,
        _keyDerivationService = keyDerivationService,
        _masterKeyStore = masterKeyStore,
        _syncSettingsStore = syncSettingsStore,
        _syncSettings = initialSyncSettings,
        _vaultMetadataStore = vaultMetadataStore,
        _metadata = initialMetadata,
        _requireTotp = requireTotp,
        _totpSecret = totpSecret;

  final VaultService _vaultService;
  final BackupService _backupService;
  final CryptoService _cryptoService;
  final TotpService _totpService;
  final KeyDerivationService _keyDerivationService;
  final MasterKeyStore _masterKeyStore;
  final SyncSettingsStore _syncSettingsStore;
  final VaultMetadataStore _vaultMetadataStore;
  final bool _requireTotp;
  final String? _totpSecret;
  SyncSettings _syncSettings;
  VaultMetadata _metadata;

  bool _isUnlocked = false;
  String? _masterPassword;
  MasterKeyRecord? _masterKeyRecord;
  List<VaultItem> _items = [];
  List<VaultEntryView> _entryViews = [];
  bool _syncInProgress = false;
  Timer? _syncTimer;

  bool get isUnlocked => _isUnlocked;
  bool get requireTotp => _requireTotp;
  bool get hasMasterKey => _masterKeyRecord != null;
  List<VaultItem> get items => List.unmodifiable(_items);
  SyncSettings get syncSettings => _syncSettings;
  bool get isSyncing => _syncInProgress;
  VaultMetadata get metadata => _metadata;
  List<VaultEntryView> get entryViews => List.unmodifiable(_entryViews);

  String get _deviceId =>
      _syncSettings.deviceId.isEmpty ? 'legacy' : _syncSettings.deviceId;

  Future<void> initialize() async {
    _masterKeyRecord = await _masterKeyStore.read();
    notifyListeners();
  }

  Future<bool> setupMasterPassword(String password, String confirm) async {
    if (password.trim().isEmpty || password != confirm) {
      return false;
    }
    final derived = await _keyDerivationService.deriveKey(password);
    final record = MasterKeyRecord(
      salt: derived.salt,
      iterations: derived.iterations,
      verifier: base64Encode(derived.bytes),
    );
    await _masterKeyStore.save(record);
    _masterKeyRecord = record;
    _masterPassword = password;
    _isUnlocked = true;
    _metadata = VaultMetadata.defaults();
    await _saveMetadata();
    await reload();
    notifyListeners();
    return true;
  }

  Future<bool> unlock(String masterPassword, {String? totpCode}) async {
    if (_masterKeyRecord == null) {
      return false;
    }
    if (_requireTotp) {
      if (_totpSecret == null || totpCode == null) {
        return false;
      }
      if (!_totpService.verifyCode(_totpSecret!, totpCode)) {
        return false;
      }
    }
    final derived = await _keyDerivationService.deriveKey(
      masterPassword,
      salt: Uint8List.fromList(_masterKeyRecord!.salt),
      iterations: _masterKeyRecord!.iterations,
    );
    final storedVerifier = base64Decode(_masterKeyRecord!.verifier);
    if (!_bytesEqual(Uint8List.fromList(derived.bytes), storedVerifier)) {
      return false;
    }
    _masterPassword = masterPassword;
    _isUnlocked = true;
    notifyListeners();
    unawaited(_postUnlockLoad(masterPassword));
    return true;
  }

  Future<void> lock() async {
    _masterPassword = null;
    _isUnlocked = false;
    _items = [];
    _syncTimer?.cancel();
    _syncTimer = null;
    notifyListeners();
  }

  Future<void> reload() async {
    await reloadWithOptions();
  }

  Future<void> reloadWithOptions({bool eagerDecrypt = true}) async {
    _ensureUnlocked();
    _items = await _vaultService.listAll();
    if (eagerDecrypt) {
      _entryViews = await _buildEntryViews(_items);
    } else {
      _entryViews = _buildSkeletonEntryViews(_items);
      unawaited(_hydrateEntryViews(_items));
    }
    notifyListeners();
  }

  Future<VaultItem> addEntry({
    required String label,
    required CredentialPayload payload,
  }) async {
    _ensureUnlocked();
    await _ensureTags(payload.tags);
    final version = _bumpVersion(const <String, int>{});
    final item = await _vaultService.addCredential(
      payload,
      label: label,
      masterPassword: _masterPassword!,
      nonce: _generateNonce(),
      version: version,
      updatedBy: _deviceId,
    );
    await reload();
    return item;
  }

  Future<VaultItem> updateEntry({
    required VaultItem item,
    required String label,
    required CredentialPayload payload,
  }) async {
    _ensureUnlocked();
    await _ensureTags(payload.tags);
    final version = _bumpVersion(item.version);
    final updated = await _vaultService.updateCredential(
      item,
      payload,
      label: label,
      masterPassword: _masterPassword!,
      nonce: _generateNonce(),
      version: version,
      updatedBy: _deviceId,
      isDeleted: false,
      deletedAt: null,
    );
    await reload();
    return updated;
  }

  Future<CredentialPayload?> readEntry(VaultItem item) async {
    _ensureUnlocked();
    return _vaultService.readCredential(
      item,
      masterPassword: _masterPassword!,
    );
  }

  Future<VaultItem> addServerAsset({
    required String label,
    required ServerAssetPayload payload,
  }) async {
    _ensureUnlocked();
    await _ensureTags(payload.tags);
    final version = _bumpVersion(const <String, int>{});
    final item = await _vaultService.addServerAsset(
      payload,
      label: label,
      masterPassword: _masterPassword!,
      nonce: _generateNonce(),
      version: version,
      updatedBy: _deviceId,
    );
    await reload();
    return item;
  }

  Future<VaultItem> updateServerAsset({
    required VaultItem item,
    required String label,
    required ServerAssetPayload payload,
  }) async {
    _ensureUnlocked();
    await _ensureTags(payload.tags);
    final version = _bumpVersion(item.version);
    final updated = await _vaultService.updateServerAsset(
      item,
      payload,
      label: label,
      masterPassword: _masterPassword!,
      nonce: _generateNonce(),
      version: version,
      updatedBy: _deviceId,
      isDeleted: false,
      deletedAt: null,
    );
    await reload();
    return updated;
  }

  Future<ServerAssetPayload?> readServerAsset(VaultItem item) async {
    _ensureUnlocked();
    return _vaultService.readServerAsset(
      item,
      masterPassword: _masterPassword!,
    );
  }

  Future<void> deleteEntry(String id) async {
    _ensureUnlocked();
    final item = await _vaultService.getById(id);
    if (item == null) {
      return;
    }
    await _softDeleteItem(item);
    await reload();
  }

  Future<void> runBackup() async {
    await _backupService.runBackup();
    notifyListeners();
  }

  Future<void> syncNow() async {
    if (!_isUnlocked || _syncInProgress) {
      return;
    }
    if (_syncSettings.providerType == SyncProviderType.none) {
      await _recordSyncStatus('skipped', '未配置同步');
      return;
    }
    _syncInProgress = true;
    notifyListeners();
    try {
      final client = _buildSyncClient(_syncSettings);
      if (client == null) {
        await _recordSyncStatus('error', '同步配置不完整');
        return;
      }
      const maxAttempts = 3;
      _SyncMergeResult? mergeResult;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        final localPayload = await _buildSyncPayload();
        final remoteResult = await client.download();
        mergeResult = await _mergeWithRemote(
          localPayload: localPayload,
          remotePayload: remoteResult.payload,
        );
        await _applySyncPayload(mergeResult.payload);
        final uploadResult = await client.upload(mergeResult.payload);
        if (uploadResult.statusCode < 200 ||
            uploadResult.statusCode >= 300) {
          await _recordSyncStatus(
            'error',
            '上传失败(${uploadResult.statusCode})',
          );
          return;
        }
        final verify = await client.download();
        final verifyRevision = _decodePayload(verify.payload ?? '').revision;
        if (verifyRevision == mergeResult.revision) {
          await _updateSyncRevision(mergeResult.revision);
          await _recordSyncStatus(
            'success',
            '同步完成：合并${mergeResult.stats.total}项，冲突${mergeResult.stats.conflicts}项，删除${mergeResult.stats.deletes}项，修订${mergeResult.revision}',
          );
          return;
        }
        if (attempt == maxAttempts) {
          await _recordSyncStatus(
            'error',
            '同步冲突：远端在上传后发生变化，请重试',
          );
          return;
        }
      }
    } catch (error) {
      final message = error.toString().contains('Failed to fetch')
          ? '同步失败：浏览器阻止请求，请检查 CORS、证书或混合内容'
          : '同步失败: $error';
      await _recordSyncStatus('error', message);
    } finally {
      _syncInProgress = false;
      notifyListeners();
    }
  }

  Future<String> exportEncryptedData() async {
    _ensureUnlocked();
    final items = await _vaultService.listAll();
    final record = await _masterKeyStore.read();
    final payload = {
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'masterKey': record?.toJson(),
      'items': items.map(vaultItemToJson).toList(),
    };
    return jsonEncode(payload);
  }

  Future<void> clearAllEntries() async {
    _ensureUnlocked();
    final items = await _vaultService.listAll();
    for (final item in items) {
      await _softDeleteItem(item);
    }
    await reload();
  }

  Future<List<VaultEntryView>> _buildEntryViews(
    List<VaultItem> items,
  ) async {
    final views = <VaultEntryView>[];
    for (final item in items) {
      if (item.isDeleted) {
        continue;
      }
      if (item.type == VaultEntryType.server) {
        final payload = await readServerAsset(item);
        views.add(VaultEntryView(
          item: item,
          credential: null,
          server: payload,
          tags: payload?.tags ?? const [],
        ));
      } else {
        final payload = await readEntry(item);
        views.add(VaultEntryView(
          item: item,
          credential: payload,
          server: null,
          tags: payload?.tags ?? const [],
        ));
      }
    }
    return views;
  }

  List<VaultEntryView> _buildSkeletonEntryViews(List<VaultItem> items) {
    return items
        .where((item) => !item.isDeleted)
        .map(
          (item) => VaultEntryView(
            item: item,
            credential: null,
            server: null,
            tags: const [],
          ),
        )
        .toList();
  }

  Future<void> _hydrateEntryViews(List<VaultItem> items) async {
    if (!_isUnlocked) {
      return;
    }
    final views = await _buildEntryViews(items);
    if (!_isUnlocked) {
      return;
    }
    _entryViews = views;
    notifyListeners();
  }

  Future<void> _postUnlockLoad(String masterPassword) async {
    await reloadWithOptions(eagerDecrypt: false);
    if (!_isUnlocked || _masterPassword != masterPassword) {
      return;
    }
    await Future.wait([
      _loadSyncSettings(),
      _loadMetadata(),
    ]);
    if (!_isUnlocked || _masterPassword != masterPassword) {
      return;
    }
    notifyListeners();
    if (_syncSettings.autoSyncOnUnlock) {
      await syncNow();
    }
  }

  Future<void> _ensureTags(List<String> tags) async {
    final additions = tags.where((tag) => tag.trim().isNotEmpty).toList();
    if (additions.isEmpty) {
      return;
    }
    final newTags = {..._metadata.tags, ...additions}.toList()..sort();
    _metadata = _metadata.copyWith(tags: newTags);
    await _saveMetadata();
  }

  Future<void> _removeTagFromEntries(String tag) async {
    final items = await _vaultService.listAll();
    for (final item in items) {
      if (item.isDeleted) {
        continue;
      }
      if (item.type == VaultEntryType.server) {
        final payload = await readServerAsset(item);
        if (payload == null || !payload.tags.contains(tag)) {
          continue;
        }
        final updatedTags =
            payload.tags.where((entry) => entry != tag).toList();
        final updatedPayload = ServerAssetPayload(
          name: payload.name,
          ipAddress: payload.ipAddress,
          port: payload.port,
          username: payload.username,
          password: payload.password,
          basicConfig: payload.basicConfig,
          operatingSystem: payload.operatingSystem,
          location: payload.location,
          notes: payload.notes,
          tags: updatedTags,
        );
        await updateServerAsset(
          item: item,
          label: item.label,
          payload: updatedPayload,
        );
      } else {
        final payload = await readEntry(item);
        if (payload == null || !payload.tags.contains(tag)) {
          continue;
        }
        final updatedTags =
            payload.tags.where((entry) => entry != tag).toList();
        final updatedPayload = CredentialPayload(
          username: payload.username,
          password: payload.password,
          token: payload.token,
          appId: payload.appId,
          accessToken: payload.accessToken,
          secretKey: payload.secretKey,
          tags: updatedTags,
        );
        await updateEntry(
          item: item,
          label: item.label,
          payload: updatedPayload,
        );
      }
    }
  }

  Future<void> _replaceTagInEntries(String oldTag, String newTag) async {
    final items = await _vaultService.listAll();
    for (final item in items) {
      if (item.isDeleted) {
        continue;
      }
      if (item.type == VaultEntryType.server) {
        final payload = await readServerAsset(item);
        if (payload == null || !payload.tags.contains(oldTag)) {
          continue;
        }
        final updatedTags = payload.tags
            .map((entry) => entry == oldTag ? newTag : entry)
            .toList();
        final updatedPayload = ServerAssetPayload(
          name: payload.name,
          ipAddress: payload.ipAddress,
          port: payload.port,
          username: payload.username,
          password: payload.password,
          basicConfig: payload.basicConfig,
          operatingSystem: payload.operatingSystem,
          location: payload.location,
          notes: payload.notes,
          tags: updatedTags,
        );
        await updateServerAsset(
          item: item,
          label: item.label,
          payload: updatedPayload,
        );
      } else {
        final payload = await readEntry(item);
        if (payload == null || !payload.tags.contains(oldTag)) {
          continue;
        }
        final updatedTags = payload.tags
            .map((entry) => entry == oldTag ? newTag : entry)
            .toList();
        final updatedPayload = CredentialPayload(
          username: payload.username,
          password: payload.password,
          token: payload.token,
          appId: payload.appId,
          accessToken: payload.accessToken,
          secretKey: payload.secretKey,
          tags: updatedTags,
        );
        await updateEntry(
          item: item,
          label: item.label,
          payload: updatedPayload,
        );
      }
    }
  }

  Future<void> updateSyncSettings(SyncSettings settings) async {
    _ensureUnlocked();
    _syncSettings = settings;
    await _saveSyncSettings();
    _configureAutoSync();
    notifyListeners();
  }

  Future<void> addTag(String tag) async {
    _ensureUnlocked();
    final trimmed = tag.trim();
    if (trimmed.isEmpty) {
      return;
    }
    if (_metadata.tags.contains(trimmed)) {
      return;
    }
    final updated = [..._metadata.tags, trimmed]..sort();
    _metadata = _metadata.copyWith(tags: updated);
    await _saveMetadata();
    notifyListeners();
  }

  Future<void> renameTag(String oldTag, String newTag) async {
    _ensureUnlocked();
    final trimmed = newTag.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final updatedTags = _metadata.tags
        .map((entry) => entry == oldTag ? trimmed : entry)
        .toSet()
        .toList()
      ..sort();
    _metadata = _metadata.copyWith(tags: updatedTags);
    await _saveMetadata();
    await _replaceTagInEntries(oldTag, trimmed);
    await reload();
  }

  Future<void> deleteTag(String tag) async {
    _ensureUnlocked();
    final updatedTags = _metadata.tags.where((entry) => entry != tag).toList()
      ..sort();
    _metadata = _metadata.copyWith(tags: updatedTags);
    await _saveMetadata();
    await _removeTagFromEntries(tag);
    await reload();
  }

  Future<void> updateSortOrder(VaultSortOrder order) async {
    _ensureUnlocked();
    _metadata = _metadata.copyWith(sortOrder: order);
    await _saveMetadata();
    notifyListeners();
  }

  void _ensureUnlocked() {
    if (!_isUnlocked || _masterPassword == null) {
      throw StateError('Vault is locked');
    }
  }

  Uint8List _generateNonce() {
    final random = Random.secure();
    final bytes = List<int>.generate(12, (_) => random.nextInt(256));
    return Uint8List.fromList(bytes);
  }

  Future<void> _loadSyncSettings() async {
    final record = await _syncSettingsStore.read();
    if (record == null) {
      if (_syncSettings.deviceId.isEmpty) {
        _syncSettings = _syncSettings.copyWith(
          deviceId: SyncSettings.generateDeviceId(),
        );
        await _saveSyncSettings();
      }
      _configureAutoSync();
      return;
    }
    try {
      final derived = await _keyDerivationService.deriveKey(
        _masterPassword!,
        salt: Uint8List.fromList(record.kdfSalt),
        iterations: record.kdfIterations,
      );
      final decrypted = await _cryptoService.decrypt(
        record.encryptedPayload,
        derived.bytes,
      );
      final decoded = jsonDecode(utf8.decode(decrypted));
      if (decoded is Map) {
        _syncSettings = SyncSettings.fromJson(
          Map<String, Object?>.from(decoded),
        );
        if (_syncSettings.deviceId.isEmpty) {
          _syncSettings = _syncSettings.copyWith(
            deviceId: SyncSettings.generateDeviceId(),
          );
          await _saveSyncSettings();
        }
      }
    } catch (_) {}
    _configureAutoSync();
  }

  Future<void> _loadMetadata() async {
    final record = await _vaultMetadataStore.read();
    if (record == null) {
      return;
    }
    try {
      final derived = await _keyDerivationService.deriveKey(
        _masterPassword!,
        salt: Uint8List.fromList(record.kdfSalt),
        iterations: record.kdfIterations,
      );
      final decrypted = await _cryptoService.decrypt(
        record.encryptedPayload,
        derived.bytes,
      );
      final decoded = jsonDecode(utf8.decode(decrypted));
      if (decoded is Map) {
        _metadata = VaultMetadata.fromJson(
          Map<String, Object?>.from(decoded),
        );
      }
    } catch (_) {}
  }

  Future<void> _saveMetadata() async {
    final jsonPayload = jsonEncode(_metadata.toJson());
    final derived = await _keyDerivationService.deriveKey(_masterPassword!);
    final encrypted = await _cryptoService.encrypt(
      Uint8List.fromList(utf8.encode(jsonPayload)),
      derived.bytes,
      nonce: _generateNonce(),
    );
    final record = VaultMetadataRecord(
      encryptedPayload: encrypted,
      kdfSalt: derived.salt,
      kdfIterations: derived.iterations,
    );
    await _vaultMetadataStore.save(record);
  }

  Future<void> _saveSyncSettings() async {
    final jsonPayload = jsonEncode(_syncSettings.toJson());
    final derived = await _keyDerivationService.deriveKey(_masterPassword!);
    final encrypted = await _cryptoService.encrypt(
      Uint8List.fromList(utf8.encode(jsonPayload)),
      derived.bytes,
      nonce: _generateNonce(),
    );
    final record = SyncSettingsRecord(
      encryptedPayload: encrypted,
      kdfSalt: derived.salt,
      kdfIterations: derived.iterations,
    );
    await _syncSettingsStore.save(record);
  }

  void _configureAutoSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
    if (!_syncSettings.autoSyncEnabled || !_isUnlocked) {
      return;
    }
    final minutes = _syncSettings.autoSyncIntervalMinutes;
    final interval = Duration(minutes: minutes <= 0 ? 30 : minutes);
    _syncTimer = Timer.periodic(interval, (_) async {
      await syncNow();
    });
  }

  RemoteSyncClient? _buildSyncClient(SyncSettings settings) {
    switch (settings.providerType) {
      case SyncProviderType.none:
        return null;
      case SyncProviderType.webdav:
      case SyncProviderType.nasWebdav:
        if (settings.webdavUrl.trim().isEmpty ||
            settings.webdavPath.trim().isEmpty) {
          return null;
        }
        return WebDavSyncClient(
          baseUrl: settings.webdavUrl.trim(),
          remotePath: settings.webdavPath.trim(),
          username: settings.webdavUsername.trim(),
          password: settings.webdavPassword.trim(),
        );
      case SyncProviderType.s3Presigned:
        if (settings.presignedUploadUrl.trim().isEmpty) {
          return null;
        }
        return PresignedUrlSyncClient(
          downloadUrl: settings.presignedDownloadUrl.trim(),
          uploadUrl: settings.presignedUploadUrl.trim(),
        );
    }
  }

  Future<String> _buildSyncPayload() async {
    final items = await _vaultService.listAll();
    final record = await _masterKeyStore.read();
    final payload = {
      'version': 2,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'deviceId': _deviceId,
      'revision': _syncSettings.lastSyncRevision,
      'masterKey': _syncSettings.syncMasterKey ? record?.toJson() : null,
      'metadata': {'tags': _metadata.tags},
      'items': items.map(vaultItemToJson).toList(),
    };
    return jsonEncode(payload);
  }

  Future<_SyncMergeResult> _mergeWithRemote({
    required String localPayload,
    required String? remotePayload,
  }) async {
    if (remotePayload == null || remotePayload.trim().isEmpty) {
      final decoded = _decodePayload(localPayload);
      final deleteCount =
          decoded.items.where((item) => item.isDeleted).length;
      return _SyncMergeResult(
        payload: localPayload,
        stats: MergeStats(
          total: decoded.items.length,
          conflicts: 0,
          deletes: deleteCount,
        ),
        revision: decoded.revision,
      );
    }
    final local = _decodePayload(localPayload);
    final remote = _decodePayload(remotePayload);
    final merger = VaultSyncMerger(
      idGenerator: _generateId,
      conflictStrategy: _syncSettings.conflictStrategy,
      conflictLabelBuilder: (item, isRemote) {
        final source = isRemote ? '远端' : '本地';
        final who = item.updatedBy.isEmpty ? 'unknown' : item.updatedBy;
        final shortId =
            who.length > 6 ? who.substring(who.length - 6) : who;
        final time = item.updatedAt.toLocal().toIso8601String();
        return '(冲突-$source-$shortId-$time)';
      },
    );
    final mergeResult = merger.merge(
      localItems: local.items,
      remoteItems: remote.items,
    );
    final mergedTags = {...local.tags, ...remote.tags}.toList()..sort();
    final mergedRevision =
        (local.revision > remote.revision ? local.revision : remote.revision) +
            1;
    final mergedPayload = {
      'version': 2,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'deviceId': _deviceId,
      'revision': mergedRevision,
      'masterKey': _syncSettings.syncMasterKey
          ? (remote.masterKey ?? local.masterKey)
          : null,
      'metadata': {'tags': mergedTags},
      'items': mergeResult.items.map(vaultItemToJson).toList(),
    };
    return _SyncMergeResult(
      payload: jsonEncode(mergedPayload),
      stats: mergeResult.stats,
      revision: mergedRevision,
    );
  }

  Future<void> _applySyncPayload(String payload) async {
    final decoded = _decodePayload(payload);
    final merged = decoded.items;
    for (final item in merged) {
      await _vaultService.saveItem(item);
    }
    await _refreshMetadataTags(items: merged, extraTags: decoded.tags);
    await reload();
  }

  Future<void> _recordSyncStatus(String status, String message) async {
    final entry = SyncLogEntry(
      timestamp: DateTime.now().toUtc(),
      message: message,
      level: status == 'error' ? 'error' : 'info',
    );
    final updatedLogs = [entry, ..._syncSettings.logs];
    final trimmedLogs = updatedLogs.length > 50
        ? updatedLogs.sublist(0, 50)
        : updatedLogs;
    _syncSettings = _syncSettings.copyWith(
      lastSyncAt: entry.timestamp,
      lastSyncStatus: status,
      lastSyncMessage: message,
      logs: trimmedLogs,
    );
    await _saveSyncSettings();
    notifyListeners();
  }

  Future<void> _updateSyncRevision(int revision) async {
    if (revision == _syncSettings.lastSyncRevision) {
      return;
    }
    _syncSettings = _syncSettings.copyWith(lastSyncRevision: revision);
    await _saveSyncSettings();
  }

  _DecodedPayload _decodePayload(String payload) {
    if (payload.trim().isEmpty) {
      return const _DecodedPayload(
        items: [],
        masterKey: null,
        tags: [],
        revision: 0,
        deviceId: '',
      );
    }
    final decoded = jsonDecode(payload);
    if (decoded is! Map) {
      return const _DecodedPayload(
        items: [],
        masterKey: null,
        tags: [],
        revision: 0,
        deviceId: '',
      );
    }
    final masterKey = decoded['masterKey'] as Map?;
    final metadata = decoded['metadata'] as Map?;
    final tags =
        (metadata?['tags'] as List?)?.whereType<String>().toList() ?? [];
    final revision = decoded['revision'] as int? ?? 0;
    final deviceId = decoded['deviceId'] as String? ?? '';
    final items = (decoded['items'] as List? ?? [])
        .whereType<Map>()
        .map((entry) => vaultItemFromJson(Map<String, Object?>.from(entry)))
        .toList();
    return _DecodedPayload(
      items: items,
      masterKey: masterKey != null
          ? Map<String, Object?>.from(masterKey)
          : null,
      tags: tags,
      revision: revision,
      deviceId: deviceId,
    );
  }

  Future<void> _refreshMetadataTags({
    required List<VaultItem> items,
    required List<String> extraTags,
  }) async {
    final tagSet = <String>{..._metadata.tags, ...extraTags};
    for (final item in items) {
      if (item.isDeleted) {
        continue;
      }
      if (item.type == VaultEntryType.server) {
        final payload = await readServerAsset(item);
        if (payload != null) {
          tagSet.addAll(payload.tags);
        }
      } else {
        final payload = await readEntry(item);
        if (payload != null) {
          tagSet.addAll(payload.tags);
        }
      }
    }
    final updated = tagSet
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    if (listEquals(updated, _metadata.tags)) {
      return;
    }
    _metadata = _metadata.copyWith(tags: updated);
    await _saveMetadata();
  }

  Future<void> _softDeleteItem(VaultItem item) async {
    if (item.isDeleted) {
      return;
    }
    final now = DateTime.now().toUtc();
    final tombstone = VaultItem(
      id: item.id,
      label: item.label,
      type: item.type,
      encryptedPayload: item.encryptedPayload,
      kdfSalt: item.kdfSalt,
      kdfIterations: item.kdfIterations,
      createdAt: item.createdAt,
      updatedAt: now,
      version: _bumpVersion(item.version),
      updatedBy: _deviceId,
      isDeleted: true,
      deletedAt: now,
    );
    await _vaultService.saveItem(tombstone);
  }

  String _generateId() {
    final random = Random.secure();
    return '${DateTime.now().microsecondsSinceEpoch}-${random.nextInt(1 << 32)}';
  }

  Map<String, int> _bumpVersion(Map<String, int> current) {
    final updated = Map<String, int>.from(current);
    final next = (updated[_deviceId] ?? 0) + 1;
    updated[_deviceId] = next;
    return updated;
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

class VaultEntryView {
  const VaultEntryView({
    required this.item,
    required this.credential,
    required this.server,
    required this.tags,
  });

  final VaultItem item;
  final CredentialPayload? credential;
  final ServerAssetPayload? server;
  final List<String> tags;
}

class _SyncMergeResult {
  const _SyncMergeResult({
    required this.payload,
    required this.stats,
    required this.revision,
  });

  final String payload;
  final MergeStats stats;
  final int revision;
}

class _DecodedPayload {
  const _DecodedPayload({
    required this.items,
    required this.masterKey,
    required this.tags,
    required this.revision,
    required this.deviceId,
  });

  final List<VaultItem> items;
  final Map<String, Object?>? masterKey;
  final List<String> tags;
  final int revision;
  final String deviceId;
}
