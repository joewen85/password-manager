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
  Uint8List? _metadataKey;
  final Map<String, Uint8List> _derivedKeyCache = {};
  List<VaultItem> _items = [];
  List<VaultEntryView> _entryViews = [];
  bool _syncInProgress = false;
  Timer? _syncTimer;
  Timer? _syncDebounceTimer;
  int _notificationDepth = 0;
  bool _pendingNotify = false;

  bool get isUnlocked => _isUnlocked;
  bool get requireTotp => _requireTotp;
  bool get hasMasterKey => _masterKeyRecord != null;
  List<VaultItem> get items => List.unmodifiable(_items);
  SyncSettings get syncSettings => _syncSettings;
  bool get isSyncing => _syncInProgress;

  void _notifyListeners() {
    if (_notificationDepth > 0) {
      _pendingNotify = true;
      return;
    }
    notifyListeners();
  }

  void _notifyOnce() {
    if (_notificationDepth > 0) {
      _pendingNotify = true;
      return;
    }
    if (_pendingNotify) {
      _pendingNotify = false;
      notifyListeners();
      return;
    }
    notifyListeners();
  }

  void _flushPendingNotifications() {
    if (_notificationDepth == 0 && _pendingNotify) {
      _pendingNotify = false;
      notifyListeners();
    }
  }

  Future<T> _runWithNotificationsSuppressed<T>(
    Future<T> Function() action, {
    bool autoFlush = true,
  }) async {
    _notificationDepth++;
    try {
      return await action();
    } finally {
      _notificationDepth--;
      if (_notificationDepth == 0 && autoFlush) {
        _flushPendingNotifications();
      }
    }
  }
  VaultMetadata get metadata => _metadata;
  List<VaultEntryView> get entryViews => List.unmodifiable(_entryViews);
  bool get hasConflicts => _items.any((item) => _isConflictItem(item));

  String get _deviceId =>
      _syncSettings.deviceId.isEmpty ? 'legacy' : _syncSettings.deviceId;

  @override
  void dispose() {
    _syncTimer?.cancel();
    _syncDebounceTimer?.cancel();
    _vaultService.setSessionMetadataKey(null);
    super.dispose();
  }

  Future<void> initialize() async {
    _masterKeyRecord = await _masterKeyStore.read();
    _notifyListeners();
  }

  Future<bool> setupMasterPassword(String password, String confirm) async {
    if (password.trim().isEmpty || password != confirm) {
      return false;
    }
    final derived = await _keyDerivationService.deriveKey(password);
    _cacheDerivedKey(derived.salt, derived.iterations, derived.bytes);
    final metadataSalt = _generateSalt();
    final metadataDerived = await _keyDerivationService.deriveKey(
      password,
      salt: metadataSalt,
      iterations: derived.iterations,
    );
    _cacheDerivedKey(
      metadataDerived.salt,
      metadataDerived.iterations,
      metadataDerived.bytes,
    );
    final record = MasterKeyRecord(
      salt: derived.salt,
      iterations: derived.iterations,
      verifier: base64Encode(derived.bytes),
      metadataSalt: metadataSalt,
      metadataIterations: derived.iterations,
    );
    await _masterKeyStore.save(record);
    _masterKeyRecord = record;
    _masterPassword = password;
    _metadataKey = Uint8List.fromList(metadataDerived.bytes);
    _vaultService.setSessionMetadataKey(
      _metadataKey,
      allowEncryption: _syncSettings.syncMasterKey,
    );
    _isUnlocked = true;
    _metadata = VaultMetadata.defaults();
    await _saveMetadata();
    await reload();
    _notifyListeners();
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
    _cacheDerivedKey(
      derived.salt,
      derived.iterations,
      derived.bytes,
    );
    final storedVerifier = base64Decode(_masterKeyRecord!.verifier);
    if (!_bytesEqual(Uint8List.fromList(derived.bytes), storedVerifier)) {
      return false;
    }
    _masterPassword = masterPassword;
    await _loadSyncSettings();
    final metadataKey = await _ensureMetadataKey(masterPassword);
    _metadataKey = metadataKey;
    _vaultService.setSessionMetadataKey(
      _metadataKey,
      allowEncryption: _syncSettings.syncMasterKey,
    );
    _isUnlocked = true;
    _notifyListeners();
    unawaited(_postUnlockLoad(masterPassword));
    return true;
  }

  Future<void> lock() async {
    _masterPassword = null;
    _metadataKey = null;
    _derivedKeyCache.clear();
    _vaultService.setSessionMetadataKey(null);
    _isUnlocked = false;
    _items = [];
    _syncTimer?.cancel();
    _syncTimer = null;
    _syncDebounceTimer?.cancel();
    _syncDebounceTimer = null;
    _notifyListeners();
  }

  Future<void> reload() async {
    await reloadWithOptions();
  }

  Future<void> reloadWithOptions({bool eagerDecrypt = true}) async {
    _ensureUnlocked();
    _items = await _vaultService.listAll(masterPassword: _masterPassword!);
    if (eagerDecrypt) {
      _entryViews = await _buildEntryViews(_items);
    } else {
      _entryViews = _buildSkeletonEntryViews(_items);
      unawaited(_hydrateEntryViews(_items));
    }
    _notifyListeners();
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
    _applyLocalItemUpdate(item, tags: payload.tags);
    _scheduleSyncSoon();
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
    _applyLocalItemUpdate(updated, tags: payload.tags);
    _scheduleSyncSoon();
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
    _applyLocalItemUpdate(item, tags: payload.tags);
    _scheduleSyncSoon();
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
    _applyLocalItemUpdate(updated, tags: payload.tags);
    _scheduleSyncSoon();
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
    final item = await _vaultService.getById(
      id,
      masterPassword: _masterPassword!,
    );
    if (item == null) {
      return;
    }
    final tombstone = await _softDeleteItem(item);
    if (tombstone != null) {
      _applyLocalItemUpdate(tombstone, tags: const <String>[]);
    }
    _scheduleSyncSoon();
  }

  Future<void> runBackup() async {
    await _backupService.runBackup();
    _notifyListeners();
  }

  Future<void> syncNow({bool notifyProgress = false}) async {
    if (!_isUnlocked || _syncInProgress) {
      return;
    }
    if (_syncSettings.providerType == SyncProviderType.none) {
      await _recordSyncStatus('skipped', '未配置同步');
      return;
    }
    if (notifyProgress) {
      _syncInProgress = true;
      _notifyListeners();
      await _runWithNotificationsSuppressed(
        () async => _performSync(),
        autoFlush: false,
      );
      _syncInProgress = false;
      _notifyOnce();
      return;
    }
    await _runWithNotificationsSuppressed(() async {
      _syncInProgress = true;
      _notifyListeners();
      await _performSync();
      _syncInProgress = false;
      _notifyListeners();
    });
  }

  Future<void> _performSync() async {
    try {
      final client = _buildSyncClient(_syncSettings);
      if (client == null) {
        await _recordSyncStatus('error', '同步配置不完整');
        return;
      }
      const maxAttempts = 3;
      _SyncMergeResult? mergeResult;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        final timings = <String, Duration>{};
        final overall = Stopwatch()..start();
        final localPayload = await _buildSyncPayload();
        timings['local'] = overall.elapsed;
        final downloadWatch = Stopwatch()..start();
        final remoteResult = await client.download();
        timings['download'] = downloadWatch.elapsed;
        final mergeWatch = Stopwatch()..start();
        mergeResult = await _mergeWithRemote(
          localPayload: localPayload,
          remotePayload: remoteResult.payload,
        );
        timings['merge'] = mergeWatch.elapsed;
        if (mergeResult.shouldApply) {
          final applyWatch = Stopwatch()..start();
          await _applySyncPayload(mergeResult.payload);
          timings['apply'] = applyWatch.elapsed;
        }
        if (!mergeResult.shouldUpload) {
          await _appendSyncLog(_formatSyncTimings(
            timings,
            total: overall.elapsed,
            attempt: attempt,
            mergeDetails: mergeResult?.timings,
          ));
          final resolvedRevision =
              mergeResult.revision > _syncSettings.lastSyncRevision
                  ? mergeResult.revision
                  : _syncSettings.lastSyncRevision;
          await _updateSyncRevision(resolvedRevision);
          final message = mergeResult.shouldApply
              ? '同步完成：已更新本地数据，修订$resolvedRevision'
              : '同步完成：无变更，修订$resolvedRevision';
          await _recordSyncStatus('success', message);
          return;
        }
        final uploadWatch = Stopwatch()..start();
        final uploadResult = await client.upload(mergeResult.payload);
        timings['upload'] = uploadWatch.elapsed;
        if (uploadResult.statusCode < 200 ||
            uploadResult.statusCode >= 300) {
          await _appendSyncLog(_formatSyncTimings(
            timings,
            total: overall.elapsed,
            attempt: attempt,
            mergeDetails: mergeResult?.timings,
          ));
          await _recordSyncStatus(
            'error',
            '上传失败(${uploadResult.statusCode})',
          );
          return;
        }
        final verifyWatch = Stopwatch()..start();
        final verify = await client.download();
        timings['verify'] = verifyWatch.elapsed;
        final verifyRevision = _decodePayload(verify.payload ?? '').revision;
        if (verifyRevision == mergeResult.revision) {
          await _appendSyncLog(_formatSyncTimings(
            timings,
            total: overall.elapsed,
            attempt: attempt,
            mergeDetails: mergeResult?.timings,
          ));
          await _updateSyncRevision(mergeResult.revision);
          await _recordSyncStatus(
            'success',
            '同步完成：合并${mergeResult.stats.total}项，冲突${mergeResult.stats.conflicts}项，删除${mergeResult.stats.deletes}项，修订${mergeResult.revision}',
          );
          return;
        }
        if (attempt == maxAttempts) {
          await _appendSyncLog(_formatSyncTimings(
            timings,
            total: overall.elapsed,
            attempt: attempt,
            mergeDetails: mergeResult?.timings,
          ));
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
    }
  }

  Future<String> exportEncryptedData() async {
    _ensureUnlocked();
    await _vaultService.migrateLegacyRecords(_masterPassword!);
    final records = await _vaultService.listAllRecords();
    final record = await _masterKeyStore.read();
    final metadataRecord = await _encryptMetadataRecord(_metadata);
    final payload = {
      'version': 2,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'masterKey': record?.toJson(),
      'metadataRecord': metadataRecord.toJson(),
      'items': records.map(vaultRecordToJson).toList(),
    };
    return jsonEncode(payload);
  }

  Future<void> clearAllEntries() async {
    _ensureUnlocked();
    final items = await _vaultService.listAll(masterPassword: _masterPassword!);
    for (final item in items) {
      await _softDeleteItem(item);
    }
    await reloadWithOptions(eagerDecrypt: false);
    _scheduleSyncSoon();
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
        views.add(_buildEntryView(
          item: item,
          credential: null,
          server: payload,
          tags: payload?.tags ?? const [],
          isConflict: _isConflictItem(item),
        ));
      } else {
        final payload = await readEntry(item);
        views.add(_buildEntryView(
          item: item,
          credential: payload,
          server: null,
          tags: payload?.tags ?? const [],
          isConflict: _isConflictItem(item),
        ));
      }
    }
    return views;
  }

  VaultEntryView _buildEntryView({
    required VaultItem item,
    required CredentialPayload? credential,
    required ServerAssetPayload? server,
    required List<String> tags,
    required bool isConflict,
  }) {
    return VaultEntryView(
      item: item,
      credential: credential,
      server: server,
      tags: tags,
      isConflict: isConflict,
      searchIndex: _buildSearchIndex(
        item: item,
        credential: credential,
        server: server,
        tags: tags,
      ),
    );
  }

  VaultEntrySearchIndex _buildSearchIndex({
    required VaultItem item,
    required CredentialPayload? credential,
    required ServerAssetPayload? server,
    required List<String> tags,
  }) {
    String? lowerOrNull(String? value) {
      if (value == null) {
        return null;
      }
      final trimmed = value.trim();
      if (trimmed.isEmpty) {
        return null;
      }
      return trimmed.toLowerCase();
    }

    final labelLower = item.label.toLowerCase();
    final appIdLower = lowerOrNull(credential?.appId);
    final serverNameLower = lowerOrNull(server?.name);
    final serverIpLower = lowerOrNull(server?.ipAddress);
    final tagsLower = tags.isEmpty
        ? const <String>[]
        : tags.map((tag) => tag.toLowerCase()).toList(growable: false);
    final anyLower = _buildAnyLower(
      labelLower: labelLower,
      appIdLower: appIdLower,
      serverNameLower: serverNameLower,
      serverIpLower: serverIpLower,
      tagsLower: tagsLower,
    );
    return VaultEntrySearchIndex(
      labelLower: labelLower,
      appIdLower: appIdLower,
      serverNameLower: serverNameLower,
      serverIpLower: serverIpLower,
      tagsLower: tagsLower,
      anyLower: anyLower,
    );
  }

  String _buildAnyLower({
    required String labelLower,
    required String? appIdLower,
    required String? serverNameLower,
    required String? serverIpLower,
    required List<String> tagsLower,
  }) {
    final buffer = StringBuffer(labelLower);
    if (appIdLower != null && appIdLower.isNotEmpty) {
      buffer.write('\n');
      buffer.write(appIdLower);
    }
    if (serverNameLower != null && serverNameLower.isNotEmpty) {
      buffer.write('\n');
      buffer.write(serverNameLower);
    }
    if (serverIpLower != null && serverIpLower.isNotEmpty) {
      buffer.write('\n');
      buffer.write(serverIpLower);
    }
    for (final tag in tagsLower) {
      if (tag.isEmpty) {
        continue;
      }
      buffer.write('\n');
      buffer.write(tag);
    }
    return buffer.toString();
  }

  List<VaultEntryView> _buildSkeletonEntryViews(List<VaultItem> items) {
      return items
          .where((item) => !item.isDeleted)
          .map(
            (item) => _buildEntryView(
              item: item,
              credential: null,
              server: null,
              tags: const [],
              isConflict: _isConflictItem(item),
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
    _notifyListeners();
  }

  Future<void> _postUnlockLoad(String masterPassword) async {
    await _vaultService.migrateLegacyRecords(masterPassword);
    if (!_syncSettings.syncMasterKey) {
      await _vaultService.migrateMetadataToRecordKey(masterPassword);
    }
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
    _notifyListeners();
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
    if (listEquals(newTags, _metadata.tags)) {
      return;
    }
    _metadata = _withUpdatedTags(newTags);
    await _saveMetadata();
  }

  Future<void> _removeTagFromEntries(String tag) async {
    final items = await _vaultService.listAll(masterPassword: _masterPassword!);
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
          notes: payload.notes,
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
    final items = await _vaultService.listAll(masterPassword: _masterPassword!);
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
          notes: payload.notes,
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
    final wasSyncingMasterKey = _syncSettings.syncMasterKey;
    _syncSettings = settings;
    await _saveSyncSettings();
    _configureAutoSync();
    if (_syncSettings.syncMasterKey && _metadataKey == null) {
      _metadataKey = await _ensureMetadataKey(_masterPassword!);
    }
    _vaultService.setSessionMetadataKey(
      _metadataKey,
      allowEncryption: _syncSettings.syncMasterKey,
    );
    if (wasSyncingMasterKey && !_syncSettings.syncMasterKey) {
      await _vaultService.migrateMetadataToRecordKey(_masterPassword!);
    }
    _notifyListeners();
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
    _metadata = _withUpdatedTags(updated);
    await _saveMetadata();
    _scheduleSyncSoon();
    _notifyListeners();
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
    if (!listEquals(updatedTags, _metadata.tags)) {
      _metadata = _withUpdatedTags(updatedTags);
      await _saveMetadata();
    }
    await _replaceTagInEntries(oldTag, trimmed);
    await reload();
    _scheduleSyncSoon();
  }

  Future<void> deleteTag(String tag) async {
    _ensureUnlocked();
    final updatedTags = _metadata.tags.where((entry) => entry != tag).toList()
      ..sort();
    if (!listEquals(updatedTags, _metadata.tags)) {
      _metadata = _withUpdatedTags(updatedTags);
      await _saveMetadata();
    }
    await _removeTagFromEntries(tag);
    await reload();
    _scheduleSyncSoon();
  }

  Future<void> updateSortOrder(VaultSortOrder order) async {
    _ensureUnlocked();
    _metadata = _metadata.copyWith(sortOrder: order);
    await _saveMetadata();
    _scheduleSyncSoon();
    _notifyListeners();
  }

  void _ensureUnlocked() {
    if (!_isUnlocked || _masterPassword == null) {
      throw StateError('Vault is locked');
    }
  }

  int _nowUtcMillis() {
    return DateTime.now().toUtc().millisecondsSinceEpoch;
  }

  VaultMetadata _withUpdatedTags(List<String> tags) {
    return _metadata.copyWith(tags: tags, tagsUpdatedAt: _nowUtcMillis());
  }

  Uint8List _generateNonce() {
    final random = Random.secure();
    final bytes = List<int>.generate(12, (_) => random.nextInt(256));
    return Uint8List.fromList(bytes);
  }

  Uint8List _generateSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return Uint8List.fromList(bytes);
  }

  Future<Uint8List?> _ensureMetadataKey(String masterPassword) async {
    final record = _masterKeyRecord;
    if (record == null) {
      return null;
    }
    var metadataSalt = record.metadataSalt;
    var metadataIterations = record.metadataIterations;
    if (metadataSalt == null || metadataSalt.isEmpty) {
      if (!_syncSettings.syncMasterKey) {
        return null;
      }
      final existingMetadata = await _vaultMetadataStore.read();
      if (existingMetadata != null &&
          existingMetadata.kdfSalt.isNotEmpty) {
        metadataSalt = existingMetadata.kdfSalt;
        metadataIterations = existingMetadata.kdfIterations;
      } else {
        metadataSalt = _generateSalt();
        metadataIterations = record.iterations;
      }
      _masterKeyRecord = MasterKeyRecord(
        salt: record.salt,
        iterations: record.iterations,
        verifier: record.verifier,
        metadataSalt: metadataSalt,
        metadataIterations: metadataIterations,
      );
      await _masterKeyStore.save(_masterKeyRecord!);
    }
    return _deriveKeyCached(
      salt: metadataSalt,
      iterations: metadataIterations ?? record.iterations,
    );
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
      final decoded = await _decryptMetadataRecord(record);
      if (decoded != null) {
        _metadata = decoded;
      }
    } catch (_) {}
  }

  Future<void> _saveMetadata() async {
    final record = await _encryptMetadataRecord(_metadata);
    await _vaultMetadataStore.save(record);
  }

  Future<VaultMetadata?> _decryptMetadataRecord(
    VaultMetadataRecord record, {
    Uint8List? key,
  }) async {
    Uint8List? decrypted;
    final sessionKey = key ?? _metadataKey;
    if (sessionKey != null) {
      try {
        decrypted = await _cryptoService.decrypt(
          record.encryptedPayload,
          sessionKey,
        );
      } catch (_) {}
    }
    decrypted ??= await _cryptoService.decrypt(
      record.encryptedPayload,
      (await _keyDerivationService.deriveKey(
        _masterPassword!,
        salt: Uint8List.fromList(record.kdfSalt),
        iterations: record.kdfIterations,
      ))
          .bytes,
    );
    final decoded = jsonDecode(utf8.decode(decrypted));
    if (decoded is! Map) {
      return null;
    }
    return VaultMetadata.fromJson(Map<String, Object?>.from(decoded));
  }

  Future<_ResolvedMasterKey?> _resolveRemoteMasterKey(
    Map<String, Object?>? raw,
  ) async {
    if (raw == null || _masterPassword == null) {
      return null;
    }
    final remoteRecord = MasterKeyRecord.fromJson(raw);
    if (_masterKeyRecord != null &&
        _sameMasterKey(_masterKeyRecord!, remoteRecord)) {
      final metadataKey = _metadataKey ??
          await _deriveKeyCached(
            salt: remoteRecord.metadataSalt ?? remoteRecord.salt,
            iterations:
                remoteRecord.metadataIterations ?? remoteRecord.iterations,
          );
      return _ResolvedMasterKey(
        record: _masterKeyRecord!,
        metadataKey: metadataKey,
      );
    }
    final derived = await _deriveKeyCached(
      salt: remoteRecord.salt,
      iterations: remoteRecord.iterations,
    );
    final verifier = base64Decode(remoteRecord.verifier);
    if (!_bytesEqual(derived, verifier)) {
      return null;
    }
    final metadataKey = await _deriveMetadataKeyFromRecord(remoteRecord);
    return _ResolvedMasterKey(record: remoteRecord, metadataKey: metadataKey);
  }

  Future<Uint8List> _deriveMetadataKeyFromRecord(
    MasterKeyRecord record,
  ) async {
    return _deriveKeyCached(
      salt: record.metadataSalt ?? record.salt,
      iterations: record.metadataIterations ?? record.iterations,
    );
  }

  Future<Uint8List?> _resolveRemoteMetadataKey(
    VaultMetadataRecord? record,
  ) async {
    if (record == null || _masterPassword == null) {
      return null;
    }
    if (_metadataKey != null &&
        _masterKeyRecord != null &&
        listEquals(record.kdfSalt, _masterKeyRecord!.metadataSalt) &&
        record.kdfIterations ==
            (_masterKeyRecord!.metadataIterations ??
                _masterKeyRecord!.iterations)) {
      return _metadataKey;
    }
    final derived = await _deriveKeyCached(
      salt: record.kdfSalt,
      iterations: record.kdfIterations,
    );
    try {
      await _cryptoService.decrypt(record.encryptedPayload, derived);
    } catch (_) {
      return null;
    }
    return Uint8List.fromList(derived);
  }

  void _cacheDerivedKey(
    List<int> salt,
    int iterations,
    Uint8List bytes,
  ) {
    _derivedKeyCache[_kdfCacheKey(salt, iterations)] =
        Uint8List.fromList(bytes);
  }

  Future<Uint8List> _deriveKeyCached({
    required List<int> salt,
    required int iterations,
  }) async {
    final key = _kdfCacheKey(salt, iterations);
    final cached = _derivedKeyCache[key];
    if (cached != null) {
      return cached;
    }
    final derived = await _keyDerivationService.deriveKey(
      _masterPassword!,
      salt: Uint8List.fromList(salt),
      iterations: iterations,
    );
    _cacheDerivedKey(derived.salt, derived.iterations, derived.bytes);
    return Uint8List.fromList(derived.bytes);
  }

  String _kdfCacheKey(List<int> salt, int iterations) {
    return '${base64Encode(salt)}:$iterations';
  }

  Future<List<VaultItem>> _decryptRecordsWithFallbackKeys(
    List<VaultItemRecord> records, {
    Uint8List? primaryKey,
    Uint8List? secondaryKey,
  }) async {
    if (records.isEmpty) {
      return [];
    }
    final originalKey = _metadataKey;
    final items = <VaultItem>[];
    Object? lastError;

    Future<List<VaultItemRecord>> attempt(
      List<VaultItemRecord> pending,
      Uint8List? key,
    ) async {
      if (pending.isEmpty) {
        return pending;
      }
      _vaultService.setSessionMetadataKey(
        key,
        allowEncryption: _syncSettings.syncMasterKey,
      );
      final failed = <VaultItemRecord>[];
      for (final record in pending) {
        try {
          items.add(
            await _vaultService.decryptRecord(
              record,
              masterPassword: _masterPassword!,
            ),
          );
        } catch (error) {
          lastError = error;
          failed.add(record);
        }
      }
      return failed;
    }

    var pending = records;
    if (primaryKey != null) {
      pending = await attempt(pending, primaryKey);
    }
    if (secondaryKey != null &&
        pending.isNotEmpty &&
        (primaryKey == null || !_sameKey(primaryKey, secondaryKey))) {
      pending = await attempt(pending, secondaryKey);
    }
    if (pending.isNotEmpty) {
      pending = await attempt(pending, null);
    }

    _vaultService.setSessionMetadataKey(
      originalKey,
      allowEncryption: _syncSettings.syncMasterKey,
    );
    if (pending.isNotEmpty) {
      throw lastError ?? StateError('远端数据解密失败');
    }
    return items;
  }

  Future<List<VaultItem>> _resolveLocalItems(
    List<VaultItemRecord> records,
    Uint8List? sessionKey,
  ) async {
    if (_items.length == records.length) {
      final ids = <String>{};
      var matches = true;
      for (final item in _items) {
        if (!ids.add(item.id)) {
          matches = false;
          break;
        }
      }
      if (matches) {
        for (final record in records) {
          if (!ids.contains(record.id)) {
            matches = false;
            break;
          }
        }
      }
      if (matches) {
        return List<VaultItem>.from(_items);
      }
    }
    _vaultService.setSessionMetadataKey(
      sessionKey,
      allowEncryption: _syncSettings.syncMasterKey,
    );
    return _vaultService.decryptRecords(
      records,
      masterPassword: _masterPassword!,
    );
  }

  Future<VaultMetadataRecord> _encryptMetadataRecord(
    VaultMetadata metadata,
  ) async {
    final jsonPayload = jsonEncode(metadata.toJson());
    final kdfSalt =
        _masterKeyRecord?.metadataSalt ?? _masterKeyRecord?.salt ?? [];
    final kdfIterations =
        _masterKeyRecord?.metadataIterations ??
        _masterKeyRecord?.iterations ??
        120000;
    final keyBytes = _metadataKey ??
        (await _keyDerivationService.deriveKey(
          _masterPassword!,
          salt: Uint8List.fromList(kdfSalt),
          iterations: kdfIterations,
        ))
            .bytes;
    final encrypted = await _cryptoService.encrypt(
      Uint8List.fromList(utf8.encode(jsonPayload)),
      keyBytes,
      nonce: _generateNonce(),
    );
    return VaultMetadataRecord(
      encryptedPayload: encrypted,
      kdfSalt: kdfSalt,
      kdfIterations: kdfIterations,
    );
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

  void _scheduleSyncSoon() {
    if (!_isUnlocked || !_syncSettings.autoSyncEnabled) {
      return;
    }
    _syncDebounceTimer?.cancel();
    _syncDebounceTimer = Timer(const Duration(seconds: 5), () async {
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
    await _vaultService.migrateLegacyRecords(_masterPassword!);
    final records = await _vaultService.listAllRecords();
    final masterRecord = await _masterKeyStore.read();
    final metadataRecord = await _encryptMetadataRecord(_metadata);
    final payload = {
      'version': 2,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'deviceId': _deviceId,
      'revision': _syncSettings.lastSyncRevision,
      'masterKey': _syncSettings.syncMasterKey ? masterRecord?.toJson() : null,
      'metadataRecord': metadataRecord.toJson(),
      'items': records.map(vaultRecordToJson).toList(),
    };
    return jsonEncode(payload);
  }

  Future<_SyncMergeResult> _mergeWithRemote({
    required String localPayload,
    required String? remotePayload,
  }) async {
    final local = _decodePayload(localPayload);
    final localSessionKey = _metadataKey;
    final mergeTimings = <String, Duration>{};
    final localWatch = Stopwatch()..start();
    final localItems =
        await _resolveLocalItems(local.records, localSessionKey);
    mergeTimings['local'] = localWatch.elapsed;
    if (remotePayload == null || remotePayload.trim().isEmpty) {
      final deleteCount =
          localItems.where((item) => item.isDeleted).length;
      return _SyncMergeResult(
        payload: localPayload,
        stats: MergeStats(
          total: localItems.length,
          conflicts: 0,
          deletes: deleteCount,
        ),
        revision: local.revision,
        timings: mergeTimings,
        shouldApply: false,
      );
    }
    final remote = _decodePayload(remotePayload);
    final remoteResolution = await _resolveRemoteMasterKey(remote.masterKey);
    final remoteSessionKey = remoteResolution?.metadataKey ??
        await _resolveRemoteMetadataKey(remote.metadataRecord);
    final remoteWatch = Stopwatch()..start();
    final List<VaultItem> remoteItems;
    try {
      remoteItems = await _decryptRecordsWithFallbackKeys(
        remote.records,
        primaryKey: remoteSessionKey,
        secondaryKey: localSessionKey,
      );
    } catch (_) {
      throw StateError('远端数据解密失败，可能未同步主密钥或主密码不一致');
    }
    mergeTimings['remote'] = remoteWatch.elapsed;
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
    final mergeWatch = Stopwatch()..start();
    final mergeResult = merger.merge(
      localItems: localItems,
      remoteItems: remoteItems,
    );
    mergeTimings['compute'] = mergeWatch.elapsed;
    final metadataWatch = Stopwatch()..start();
    final mergedTags = await _mergeTags(
      items: mergeResult.items,
      localRecord: local.metadataRecord,
      remoteRecord: remote.metadataRecord,
      localMetadataKey: localSessionKey,
      remoteMetadataKey: remoteSessionKey,
    );
    final legacyBaseCount = mergedTags.tags.length;
    mergedTags.tags.addAll(local.legacyTags);
    mergedTags.tags.addAll(remote.legacyTags);
    var mergedTagsUpdatedAt = mergedTags.updatedAt;
    if (mergedTags.tags.length != legacyBaseCount) {
      mergedTagsUpdatedAt = _nowUtcMillis();
    }
    final mergedMetadata = _metadata.copyWith(
      tags: mergedTags.tags.toList()..sort(),
      tagsUpdatedAt: mergedTagsUpdatedAt,
    );
    if (remoteResolution != null && _syncSettings.syncMasterKey) {
      if (_masterKeyRecord == null ||
          !_sameMasterKey(_masterKeyRecord!, remoteResolution.record)) {
        _masterKeyRecord = remoteResolution.record;
        await _masterKeyStore.save(remoteResolution.record);
      }
      _metadataKey = remoteResolution.metadataKey;
      _vaultService.setSessionMetadataKey(
        _metadataKey,
        allowEncryption: _syncSettings.syncMasterKey,
      );
    }
    final localMetadata = mergedTags.localMetadata ?? _metadata;
    final remoteMetadata = mergedTags.remoteMetadata;
    final mergedMasterKeyPayload = _syncSettings.syncMasterKey
        ? (remoteResolution != null ? remote.masterKey : local.masterKey)
        : null;
    final matchesLocal = _sameItemList(mergeResult.items, localItems) &&
        _sameMetadata(mergedMetadata, localMetadata) &&
        _sameMasterKeyPayload(mergedMasterKeyPayload, local.masterKey);
    final matchesRemote = _sameItemList(mergeResult.items, remoteItems) &&
        _sameMetadata(mergedMetadata, remoteMetadata) &&
        _sameMasterKeyPayload(mergedMasterKeyPayload, remote.masterKey);
    if (matchesRemote) {
      mergeTimings['metadata'] = metadataWatch.elapsed;
      return _SyncMergeResult(
        payload: remotePayload!,
        stats: mergeResult.stats,
        revision: remote.revision,
        timings: mergeTimings,
        shouldUpload: false,
        shouldApply: !matchesLocal,
      );
    }
    final mergedMetadataRecord = await _encryptMetadataRecord(mergedMetadata);
    mergeTimings['metadata'] = metadataWatch.elapsed;
    final mergedRecords = <VaultItemRecord>[];
    final localItemById = {for (final item in localItems) item.id: item};
    final remoteItemById = {for (final item in remoteItems) item.id: item};
    final localRecordById = {
      for (final record in local.records) record.id: record,
    };
    final remoteRecordById = {
      for (final record in remote.records) record.id: record,
    };
    final recordsWatch = Stopwatch()..start();
    for (final item in mergeResult.items) {
      VaultItemRecord? record;
      final localItem = localItemById[item.id];
      if (localItem != null &&
          identical(item, localItem) &&
          (remoteSessionKey == null ||
              _sameKey(remoteSessionKey, localSessionKey))) {
        record = localRecordById[item.id];
      }
      if (record == null) {
        final remoteItem = remoteItemById[item.id];
        if (remoteItem != null && identical(item, remoteItem)) {
          record = remoteRecordById[item.id];
        }
      }
      if (record != null && record.encryptedMetadata != null) {
        mergedRecords.add(record);
        continue;
      }
      mergedRecords.add(
        await _vaultService.encryptRecord(
          item,
          masterPassword: _masterPassword!,
        ),
      );
    }
    mergeTimings['records'] = recordsWatch.elapsed;
    final mergedRevision =
        (local.revision > remote.revision ? local.revision : remote.revision) +
            1;
    final mergedPayload = {
      'version': 2,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'deviceId': _deviceId,
      'revision': mergedRevision,
      'masterKey': mergedMasterKeyPayload,
      'metadataRecord': mergedMetadataRecord.toJson(),
      'items': mergedRecords.map(vaultRecordToJson).toList(),
    };
    return _SyncMergeResult(
      payload: jsonEncode(mergedPayload),
      stats: mergeResult.stats,
      revision: mergedRevision,
      timings: mergeTimings,
      shouldApply: !matchesLocal,
    );
  }

  Future<void> _applySyncPayload(String payload) async {
    final decoded = _decodePayload(payload);
    final upgradedRecords = <VaultItemRecord>[];
    for (final record in decoded.records) {
      if (record.encryptedMetadata == null) {
        final item = await _vaultService.decryptRecord(
          record,
          masterPassword: _masterPassword!,
        );
        upgradedRecords.add(
          await _vaultService.encryptRecord(
            item,
            masterPassword: _masterPassword!,
          ),
        );
        continue;
      }
      final sessionKey = _metadataKey;
      if (sessionKey != null) {
        try {
          await _cryptoService.decrypt(record.encryptedMetadata!, sessionKey);
          upgradedRecords.add(record);
          continue;
        } catch (_) {}
      }
      final item = await _vaultService.decryptRecord(
        record,
        masterPassword: _masterPassword!,
      );
      upgradedRecords.add(
        await _vaultService.encryptRecord(
          item,
          masterPassword: _masterPassword!,
        ),
      );
    }
    await _vaultService.saveRecords(upgradedRecords);
    if (decoded.metadataRecord != null) {
      await _vaultMetadataStore.save(decoded.metadataRecord!);
      final decodedMeta =
          await _decryptMetadataRecord(decoded.metadataRecord!);
      if (decodedMeta != null) {
        _metadata = decodedMeta;
      }
    } else {
      final items = await _vaultService.decryptRecords(
        upgradedRecords,
        masterPassword: _masterPassword!,
      );
      await _refreshMetadataTags(items: items, extraTags: decoded.legacyTags);
    }
    await reloadWithOptions(eagerDecrypt: false);
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
    _notifyListeners();
  }

  Future<void> _appendSyncLog(String message, {String level = 'info'}) async {
    final entry = SyncLogEntry(
      timestamp: DateTime.now().toUtc(),
      message: message,
      level: level,
    );
    final updatedLogs = [entry, ..._syncSettings.logs];
    final trimmedLogs = updatedLogs.length > 50
        ? updatedLogs.sublist(0, 50)
        : updatedLogs;
    _syncSettings = _syncSettings.copyWith(logs: trimmedLogs);
    await _saveSyncSettings();
    _notifyListeners();
  }

  String _formatSyncTimings(
    Map<String, Duration> timings, {
    required Duration total,
    required int attempt,
    Map<String, Duration>? mergeDetails,
  }) {
    final parts = <String>[
      'local=${_formatDuration(timings['local'])}',
      'download=${_formatDuration(timings['download'])}',
      'merge=${_formatDuration(timings['merge'])}',
      'apply=${_formatDuration(timings['apply'])}',
      'upload=${_formatDuration(timings['upload'])}',
      'verify=${_formatDuration(timings['verify'])}',
      'total=${_formatDuration(total)}',
    ];
    if (mergeDetails != null && mergeDetails.isNotEmpty) {
      final mergeParts = <String>[
        'local=${_formatDuration(mergeDetails['local'])}',
        'remote=${_formatDuration(mergeDetails['remote'])}',
        'compute=${_formatDuration(mergeDetails['compute'])}',
        'metadata=${_formatDuration(mergeDetails['metadata'])}',
        'records=${_formatDuration(mergeDetails['records'])}',
      ];
      parts.add('mergeDetail=${mergeParts.join(',')}');
    }
    return '同步耗时(第$attempt次): ${parts.join(' ')}';
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) {
      return '-';
    }
    if (duration.inMilliseconds < 1000) {
      return '${duration.inMilliseconds}ms';
    }
    final seconds = duration.inMilliseconds / 1000.0;
    return '${seconds.toStringAsFixed(1)}s';
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
        records: [],
        masterKey: null,
        metadataRecord: null,
        legacyTags: [],
        revision: 0,
        deviceId: '',
      );
    }
    final decoded = jsonDecode(payload);
    if (decoded is! Map) {
      return const _DecodedPayload(
        records: [],
        masterKey: null,
        metadataRecord: null,
        legacyTags: [],
        revision: 0,
        deviceId: '',
      );
    }
    final masterKey = decoded['masterKey'] as Map?;
    final legacyMetadata = decoded['metadata'] as Map?;
    final legacyTags =
        (legacyMetadata?['tags'] as List?)?.whereType<String>().toList() ?? [];
    final metadataRecordRaw = decoded['metadataRecord'] as Map?;
    final metadataRecord = metadataRecordRaw == null
        ? null
        : VaultMetadataRecord.fromJson(
            Map<String, Object?>.from(metadataRecordRaw),
          );
    final revision = decoded['revision'] as int? ?? 0;
    final deviceId = decoded['deviceId'] as String? ?? '';
    final records = (decoded['items'] as List? ?? [])
        .whereType<Map>()
        .map((entry) => vaultRecordFromJson(Map<String, Object?>.from(entry)))
        .toList();
    return _DecodedPayload(
      records: records,
      masterKey: masterKey != null
          ? Map<String, Object?>.from(masterKey)
          : null,
      metadataRecord: metadataRecord,
      legacyTags: legacyTags,
      revision: revision,
      deviceId: deviceId,
    );
  }

  Future<_MergedTags> _mergeTags({
    required List<VaultItem> items,
    VaultMetadataRecord? localRecord,
    VaultMetadataRecord? remoteRecord,
    Uint8List? localMetadataKey,
    Uint8List? remoteMetadataKey,
  }) async {
    final itemTags =
        _normalizeTags(await _collectTagsFromItems(items));
    VaultMetadata? localMetadata;
    VaultMetadata? remoteMetadata;
    if (localRecord != null) {
      localMetadata =
          await _decryptMetadataRecord(localRecord, key: localMetadataKey);
    }
    if (remoteRecord != null) {
      remoteMetadata =
          await _decryptMetadataRecord(remoteRecord, key: remoteMetadataKey);
    }

    var baseTags = <String>{};
    var baseUpdatedAt = 0;
    if (localMetadata != null && remoteMetadata != null) {
      final localTags = _normalizeTags(localMetadata.tags);
      final remoteTags = _normalizeTags(remoteMetadata.tags);
      if (localMetadata.tagsUpdatedAt != remoteMetadata.tagsUpdatedAt) {
        if (localMetadata.tagsUpdatedAt > remoteMetadata.tagsUpdatedAt) {
          baseTags = localTags;
          baseUpdatedAt = localMetadata.tagsUpdatedAt;
        } else {
          baseTags = remoteTags;
          baseUpdatedAt = remoteMetadata.tagsUpdatedAt;
        }
      } else {
        baseTags = {...localTags, ...remoteTags};
        baseUpdatedAt = localMetadata.tagsUpdatedAt;
      }
    } else if (localMetadata != null) {
      baseTags = _normalizeTags(localMetadata.tags);
      baseUpdatedAt = localMetadata.tagsUpdatedAt;
    } else if (remoteMetadata != null) {
      baseTags = _normalizeTags(remoteMetadata.tags);
      baseUpdatedAt = remoteMetadata.tagsUpdatedAt;
    }

    final mergedTags = {...baseTags, ...itemTags};
    var mergedUpdatedAt = baseUpdatedAt;
    if (mergedUpdatedAt == 0 && mergedTags.isNotEmpty) {
      mergedUpdatedAt = _nowUtcMillis();
    }
    if (!_setEquals(mergedTags, baseTags)) {
      mergedUpdatedAt = _nowUtcMillis();
    }
    return _MergedTags(
      tags: mergedTags,
      updatedAt: mergedUpdatedAt,
      localMetadata: localMetadata,
      remoteMetadata: remoteMetadata,
    );
  }

  Future<Set<String>> _collectTagsFromItems(List<VaultItem> items) async {
    final tagSet = <String>{};
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
    return tagSet;
  }

  Set<String> _normalizeTags(Iterable<String> tags) {
    return tags.map((tag) => tag.trim()).where((tag) => tag.isNotEmpty).toSet();
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
    _metadata = _withUpdatedTags(updated);
    await _saveMetadata();
  }

  bool _isConflictItem(VaultItem item) {
    return item.label.contains('(冲突-') || item.label.contains('冲突');
  }

  void _applyLocalItemUpdate(
    VaultItem item, {
    required List<String> tags,
  }) {
    final updatedItems = List<VaultItem>.from(_items);
    final itemIndex = updatedItems.indexWhere((entry) => entry.id == item.id);
    if (itemIndex >= 0) {
      updatedItems[itemIndex] = item;
    } else {
      updatedItems.add(item);
    }
    _items = updatedItems;

    final updatedViews = List<VaultEntryView>.from(_entryViews);
    final viewIndex =
        updatedViews.indexWhere((entry) => entry.item.id == item.id);
    if (item.isDeleted) {
      if (viewIndex >= 0) {
        updatedViews.removeAt(viewIndex);
      }
    } else {
      final view = _buildEntryView(
        item: item,
        credential: null,
        server: null,
        tags: tags,
        isConflict: _isConflictItem(item),
      );
      if (viewIndex >= 0) {
        updatedViews[viewIndex] = view;
      } else {
        updatedViews.add(view);
      }
    }
    _entryViews = updatedViews;
    _notifyListeners();
  }

  Future<VaultItem?> _softDeleteItem(VaultItem item) async {
    if (item.isDeleted) {
      return null;
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
    await _vaultService.saveItem(
      tombstone,
      masterPassword: _masterPassword!,
    );
    return tombstone;
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

  bool _sameEncryptedPayload(EncryptedPayload a, EncryptedPayload b) {
    return a.version == b.version &&
        _bytesEqual(a.ciphertext, b.ciphertext) &&
        _bytesEqual(a.nonce, b.nonce) &&
        _bytesEqual(a.mac, b.mac);
  }

  bool _sameMetadata(VaultMetadata? a, VaultMetadata? b) {
    if (a == null && b == null) {
      return true;
    }
    if (a == null || b == null) {
      return false;
    }
    return a.sortOrder == b.sortOrder &&
        a.tagsUpdatedAt == b.tagsUpdatedAt &&
        listEquals(a.tags, b.tags);
  }

  bool _sameVersionMap(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) {
      return false;
    }
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  bool _sameItem(VaultItem a, VaultItem b) {
    return a.id == b.id &&
        a.label == b.label &&
        a.type == b.type &&
        a.isDeleted == b.isDeleted &&
        a.kdfIterations == b.kdfIterations &&
        listEquals(a.kdfSalt, b.kdfSalt) &&
        a.createdAt.isAtSameMomentAs(b.createdAt) &&
        a.updatedAt.isAtSameMomentAs(b.updatedAt) &&
        _sameEncryptedPayload(a.encryptedPayload, b.encryptedPayload) &&
        _sameVersionMap(a.version, b.version) &&
        a.updatedBy == b.updatedBy &&
        ((a.deletedAt == null && b.deletedAt == null) ||
            (a.deletedAt != null &&
                b.deletedAt != null &&
                a.deletedAt!.isAtSameMomentAs(b.deletedAt!)));
  }

  bool _sameItemList(List<VaultItem> a, List<VaultItem> b) {
    if (a.length != b.length) {
      return false;
    }
    final bById = {for (final item in b) item.id: item};
    if (bById.length != b.length) {
      return false;
    }
    for (final item in a) {
      final other = bById[item.id];
      if (other == null || !_sameItem(item, other)) {
        return false;
      }
    }
    return true;
  }

  bool _sameMasterKeyPayload(
    Map<String, Object?>? a,
    Map<String, Object?>? b,
  ) {
    if (a == null && b == null) {
      return true;
    }
    if (a == null || b == null) {
      return false;
    }
    return _sameMasterKey(
      MasterKeyRecord.fromJson(a),
      MasterKeyRecord.fromJson(b),
    );
  }

  bool _setEquals(Set<String> a, Set<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (final value in a) {
      if (!b.contains(value)) {
        return false;
      }
    }
    return true;
  }

  bool _sameKey(Uint8List? a, Uint8List? b) {
    if (a == null && b == null) {
      return true;
    }
    if (a == null || b == null) {
      return false;
    }
    return _bytesEqual(a, b);
  }

  bool _sameMasterKey(MasterKeyRecord a, MasterKeyRecord b) {
    return listEquals(a.salt, b.salt) &&
        a.iterations == b.iterations &&
        a.verifier == b.verifier &&
        listEquals(a.metadataSalt, b.metadataSalt) &&
        a.metadataIterations == b.metadataIterations;
  }
}

class VaultEntryView {
  const VaultEntryView({
    required this.item,
    required this.credential,
    required this.server,
    required this.tags,
    required this.isConflict,
    required this.searchIndex,
  });

  final VaultItem item;
  final CredentialPayload? credential;
  final ServerAssetPayload? server;
  final List<String> tags;
  final bool isConflict;
  final VaultEntrySearchIndex searchIndex;
}

class VaultEntrySearchIndex {
  const VaultEntrySearchIndex({
    required this.labelLower,
    required this.appIdLower,
    required this.serverNameLower,
    required this.serverIpLower,
    required this.tagsLower,
    required this.anyLower,
  });

  final String labelLower;
  final String? appIdLower;
  final String? serverNameLower;
  final String? serverIpLower;
  final List<String> tagsLower;
  final String anyLower;
}

class _MergedTags {
  const _MergedTags({
    required this.tags,
    required this.updatedAt,
    this.localMetadata,
    this.remoteMetadata,
  });

  final Set<String> tags;
  final int updatedAt;
  final VaultMetadata? localMetadata;
  final VaultMetadata? remoteMetadata;
}

class _SyncMergeResult {
  const _SyncMergeResult({
    required this.payload,
    required this.stats,
    required this.revision,
    this.shouldUpload = true,
    this.shouldApply = true,
    this.timings = const <String, Duration>{},
  });

  final String payload;
  final MergeStats stats;
  final int revision;
  final bool shouldUpload;
  final bool shouldApply;
  final Map<String, Duration> timings;
}

class _ResolvedMasterKey {
  const _ResolvedMasterKey({
    required this.record,
    required this.metadataKey,
  });

  final MasterKeyRecord record;
  final Uint8List metadataKey;
}

class _DecodedPayload {
  const _DecodedPayload({
    required this.records,
    required this.masterKey,
    required this.metadataRecord,
    required this.legacyTags,
    required this.revision,
    required this.deviceId,
  });

  final List<VaultItemRecord> records;
  final Map<String, Object?>? masterKey;
  final VaultMetadataRecord? metadataRecord;
  final List<String> legacyTags;
  final int revision;
  final String deviceId;
}
