import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
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
  final Map<String, _PayloadCacheEntry> _payloadCache = {};
  List<VaultItem> _items = [];
  List<VaultEntryView> _entryViews = [];
  int _entryViewsVersion = 0;
  static const int _tagScanSkipThreshold = 500;
  static const bool _enablePerfLogs =
      bool.fromEnvironment('PASSWORD_MANAGER_PERF_LOGS');
  bool _syncInProgress = false;
  bool _syncRequestedAgain = false;
  int _localChangeRevision = 0;
  Timer? _syncTimer;
  Timer? _syncDebounceTimer;
  Timer? _resumeSyncTimer;
  int _notificationDepth = 0;
  bool _pendingNotify = false;
  bool _appIsActive = true;
  DateTime? _syncStartedAt;
  int _entryHydrationToken = 0;
  int _postUnlockToken = 0;
  bool _isHydratingEntryViews = false;
  static const int _deferredHydrationItemLimit = 120;

  bool get isUnlocked => _isUnlocked;
  bool get requireTotp => _requireTotp;
  bool get hasMasterKey => _masterKeyRecord != null;
  List<VaultItem> get items => List.unmodifiable(_items);
  SyncSettings get syncSettings => _syncSettings;
  bool get isSyncing => _syncInProgress;

  void _notifyListeners({bool allowWhileSuppressed = false}) {
    if (_notificationDepth > 0 && !allowWhileSuppressed) {
      _pendingNotify = true;
      return;
    }
    if (_notificationDepth > 0) {
      _pendingNotify = true;
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
  int get entryViewsVersion => _entryViewsVersion;
  bool get hasConflicts => _items.any((item) => _isConflictItem(item));

  String get _deviceId =>
      _syncSettings.deviceId.isEmpty ? 'legacy' : _syncSettings.deviceId;

  @override
  void dispose() {
    _pauseAutoSync();
    _resumeSyncTimer?.cancel();
    _vaultService.setSessionMetadataKey(null);
    super.dispose();
  }

  Future<void> initialize() async {
    _masterKeyRecord = await _masterKeyStore.read();
    _notifyListeners();
  }

  void handleAppLifecycleStateChanged(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        final wasInactive = !_appIsActive;
        _appIsActive = true;
        _recoverStalledOperations();
        _configureAutoSync();
        if (wasInactive) {
          _scheduleResumeSync();
        }
        return;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _appIsActive = false;
        _pauseAutoSync();
        return;
    }
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
    final unlockWatch = Stopwatch()..start();
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
    final unlockToken = ++_postUnlockToken;
    unawaited(_bootstrapUnlock(masterPassword, unlockToken));
    _logDebugPerf('unlock.ready', {
      'token': unlockToken,
      'elapsedMs': unlockWatch.elapsedMilliseconds,
    });
    return true;
  }

  Future<void> _bootstrapUnlock(String masterPassword, int unlockToken) async {
    final totalWatch = Stopwatch()..start();
    final metadataWatch = Stopwatch()..start();
    try {
      await _loadMetadata();
    } catch (error) {
      await _recordSyncStatus('warning', '解锁后读取元数据失败: $error');
    }
    metadataWatch.stop();
    final reloadWatch = Stopwatch()..start();
    try {
      if (!_isUnlocked ||
          _masterPassword != masterPassword ||
          unlockToken != _postUnlockToken) {
        _logDebugPerf('bootstrap.skip', {
          'stage': 'beforeReload',
          'token': unlockToken,
          'elapsedMs': totalWatch.elapsedMilliseconds,
        });
        return;
      }
      await reloadWithOptions(eagerDecrypt: false);
      reloadWatch.stop();
      if (!_isUnlocked ||
          _masterPassword != masterPassword ||
          unlockToken != _postUnlockToken) {
        _logDebugPerf('bootstrap.skip', {
          'stage': 'afterReload',
          'token': unlockToken,
          'elapsedMs': totalWatch.elapsedMilliseconds,
        });
        return;
      }
      final postWatch = Stopwatch()..start();
      await _postUnlockLoad(masterPassword, unlockToken);
      postWatch.stop();
      _logDebugPerf('bootstrap.done', {
        'token': unlockToken,
        'metadataMs': metadataWatch.elapsedMilliseconds,
        'reloadMs': reloadWatch.elapsedMilliseconds,
        'postMs': postWatch.elapsedMilliseconds,
        'totalMs': totalWatch.elapsedMilliseconds,
      });
    } catch (error) {
      reloadWatch.stop();
      await _recordSyncStatus('warning', '解锁后的本地加载失败: $error');
      _logDebugPerf('bootstrap.error', {
        'token': unlockToken,
        'metadataMs': metadataWatch.elapsedMilliseconds,
        'reloadMs': reloadWatch.elapsedMilliseconds,
        'totalMs': totalWatch.elapsedMilliseconds,
        'error': '$error',
      });
    }
  }

  Future<void> lock() async {
    _masterPassword = null;
    _metadataKey = null;
    _derivedKeyCache.clear();
    _payloadCache.clear();
    _vaultService.setSessionMetadataKey(null);
    _isUnlocked = false;
    _items = [];
    _setEntryViews(const <VaultEntryView>[]);
    _entryHydrationToken++;
    _postUnlockToken++;
    _pauseAutoSync();
    _notifyListeners();
  }

  Future<void> reload() async {
    await reloadWithOptions();
  }

  Future<void> reloadWithOptions({bool eagerDecrypt = true}) async {
    final reloadWatch = Stopwatch()..start();
    _ensureUnlocked();
    final listWatch = Stopwatch()..start();
    _items = await _vaultService.listAll(masterPassword: _masterPassword!);
    listWatch.stop();
    _prunePayloadCache(_items);
    Duration buildDuration = Duration.zero;
    if (eagerDecrypt) {
      final buildWatch = Stopwatch()..start();
      final views = await _buildEntryViews(_items);
      buildWatch.stop();
      buildDuration = buildWatch.elapsed;
      _setEntryViews(views);
      await _refreshMetadataCollectionsFromViews(views);
      _isHydratingEntryViews = false;
    } else {
      _setEntryViews(_buildSkeletonEntryViews(_items));
      if (_items.length <= _deferredHydrationItemLimit) {
        final hydrationToken = ++_entryHydrationToken;
        _isHydratingEntryViews = true;
        unawaited(
          _hydrateEntryViews(
            _items,
            hydrationToken,
            lowPriority: true,
          ),
        );
      } else {
        _isHydratingEntryViews = false;
        _logDebugPerf('hydrate.skip', {
          'reason': 'itemLimit',
          'items': _items.length,
          'limit': _deferredHydrationItemLimit,
        });
      }
    }
    _notifyListeners();
    _logDebugPerf('reload', {
      'mode': eagerDecrypt ? 'eager' : 'deferred',
      'items': _items.length,
      'listMs': listWatch.elapsedMilliseconds,
      'buildMs': buildDuration.inMilliseconds,
      'totalMs': reloadWatch.elapsedMilliseconds,
    });
  }

  Future<VaultItem> addEntry({
    required String label,
    required CredentialPayload payload,
  }) async {
    _ensureUnlocked();
    await _ensureCategory(payload.category);
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
    _applyLocalItemUpdate(
      item,
      credential: payload,
      tags: payload.tags,
      forceNotify: true,
    );
    _scheduleSyncSoon();
    return item;
  }

  Future<VaultItem> updateEntry({
    required VaultItem item,
    required String label,
    required CredentialPayload payload,
  }) async {
    _ensureUnlocked();
    await _ensureCategory(payload.category);
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
    _applyLocalItemUpdate(
      updated,
      credential: payload,
      tags: payload.tags,
      forceNotify: true,
    );
    _scheduleSyncSoon();
    return updated;
  }

  Future<CredentialPayload?> readEntry(VaultItem item) async {
    _ensureUnlocked();
    final cached = _readCachedPayload<CredentialPayload>(item);
    if (cached != null) {
      return cached;
    }
    final payload = await _vaultService.readCredential(
      item,
      masterPassword: _masterPassword!,
    );
    _storeCachedPayload(item, payload);
    return payload;
  }

  Future<VaultItem> addServerAsset({
    required String label,
    required ServerAssetPayload payload,
  }) async {
    _ensureUnlocked();
    await _ensureCategory(payload.category);
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
    _applyLocalItemUpdate(
      item,
      server: payload,
      tags: payload.tags,
      forceNotify: true,
    );
    _scheduleSyncSoon();
    return item;
  }

  Future<VaultItem> updateServerAsset({
    required VaultItem item,
    required String label,
    required ServerAssetPayload payload,
  }) async {
    _ensureUnlocked();
    await _ensureCategory(payload.category);
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
    _applyLocalItemUpdate(
      updated,
      server: payload,
      tags: payload.tags,
      forceNotify: true,
    );
    _scheduleSyncSoon();
    return updated;
  }

  Future<ServerAssetPayload?> readServerAsset(VaultItem item) async {
    _ensureUnlocked();
    final cached = _readCachedPayload<ServerAssetPayload>(item);
    if (cached != null) {
      return cached;
    }
    final payload = await _vaultService.readServerAsset(
      item,
      masterPassword: _masterPassword!,
    );
    _storeCachedPayload(item, payload);
    return payload;
  }

  Future<VaultItem> addService({
    required String label,
    required ServicePayload payload,
  }) async {
    _ensureUnlocked();
    await _ensureCategory(payload.category);
    await _ensureTags(payload.tags);
    final version = _bumpVersion(const <String, int>{});
    final item = await _vaultService.addService(
      payload,
      label: label,
      masterPassword: _masterPassword!,
      nonce: _generateNonce(),
      version: version,
      updatedBy: _deviceId,
    );
    _applyLocalItemUpdate(
      item,
      service: payload,
      tags: payload.tags,
      forceNotify: true,
    );
    _scheduleSyncSoon();
    return item;
  }

  Future<VaultItem> updateService({
    required VaultItem item,
    required String label,
    required ServicePayload payload,
  }) async {
    _ensureUnlocked();
    await _ensureCategory(payload.category);
    await _ensureTags(payload.tags);
    final version = _bumpVersion(item.version);
    final updated = await _vaultService.updateService(
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
    _applyLocalItemUpdate(
      updated,
      service: payload,
      tags: payload.tags,
      forceNotify: true,
    );
    _scheduleSyncSoon();
    return updated;
  }

  Future<ServicePayload?> readService(VaultItem item) async {
    _ensureUnlocked();
    final cached = _readCachedPayload<ServicePayload>(item);
    if (cached != null) {
      return cached;
    }
    final payload = await _vaultService.readService(
      item,
      masterPassword: _masterPassword!,
    );
    _storeCachedPayload(item, payload);
    return payload;
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
      _applyLocalItemUpdate(
        tombstone,
        tags: const <String>[],
        forceNotify: true,
      );
    }
    _scheduleSyncSoon();
  }

  Future<void> runBackup() async {
    await _backupService.runBackup();
    _notifyListeners();
  }

  Future<void> syncNow({bool notifyProgress = false}) async {
    if (!_isUnlocked) {
      return;
    }
    if (_syncSettings.providerType == SyncProviderType.none) {
      await _recordSyncStatus('skipped', '未配置同步');
      return;
    }
    if (!_appIsActive && !notifyProgress) {
      return;
    }
    if (_syncInProgress) {
      _syncRequestedAgain = true;
      return;
    }
    if (notifyProgress) {
      _syncInProgress = true;
      _syncStartedAt = DateTime.now();
      _notifyListeners();
      try {
        await _runWithNotificationsSuppressed(_performSyncLoop,
            autoFlush: false);
      } finally {
        _syncInProgress = false;
        _syncStartedAt = null;
        _notifyOnce();
      }
      return;
    }
    await _runWithNotificationsSuppressed(() async {
      _syncInProgress = true;
      _syncStartedAt = DateTime.now();
      _notifyListeners();
      try {
        await _performSyncLoop();
      } finally {
        _syncInProgress = false;
        _syncStartedAt = null;
        _notifyListeners();
      }
    });
  }

  Future<void> _performSyncLoop() async {
    do {
      _syncRequestedAgain = false;
      await _performSync();
    } while (_syncRequestedAgain);
  }

  @visibleForTesting
  Future<String> mergeSyncPayloadForTest({
    required String localPayload,
    required String? remotePayload,
  }) async {
    final result = await _mergeWithRemote(
      localPayload: localPayload,
      remotePayload: remotePayload,
    );
    return result.payload;
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
        final revisionAtStart = _localChangeRevision;
        final localPayload = await _buildSyncPayload();
        timings['local'] = overall.elapsed;
        final downloadWatch = Stopwatch()..start();
        final remoteResult = await client.download();
        timings['download'] = downloadWatch.elapsed;
        if (!_isSuccessfulDownloadStatus(remoteResult.statusCode)) {
          await _appendSyncLog(
            _formatSyncTimings(
              timings,
              total: overall.elapsed,
              attempt: attempt,
              mergeDetails: mergeResult?.timings,
            ),
            debugOnly: true,
          );
          await _recordSyncStatus(
            'error',
            _buildSyncFailureMessage('下载失败', remoteResult.statusCode),
          );
          return;
        }
        final mergeWatch = Stopwatch()..start();
        mergeResult = await _mergeWithRemote(
          localPayload: localPayload,
          remotePayload: remoteResult.payload,
        );
        timings['merge'] = mergeWatch.elapsed;
        if (mergeResult.shouldApply) {
          if (_localRevisionChangedSince(revisionAtStart)) {
            _syncRequestedAgain = true;
            return;
          }
          final applyWatch = Stopwatch()..start();
          await _applySyncPayload(
            mergeResult.payload,
            revisionAtStart: revisionAtStart,
          );
          timings['apply'] = applyWatch.elapsed;
        }
        if (!mergeResult.shouldUpload) {
          if (_localRevisionChangedSince(revisionAtStart)) {
            _syncRequestedAgain = true;
            return;
          }
          await _appendSyncLog(
            _formatSyncTimings(
              timings,
              total: overall.elapsed,
              attempt: attempt,
              mergeDetails: mergeResult.timings,
            ),
            debugOnly: true,
          );
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
        if (_localRevisionChangedSince(revisionAtStart)) {
          _syncRequestedAgain = true;
          return;
        }
        final uploadWatch = Stopwatch()..start();
        final uploadResult = await client.upload(mergeResult.payload);
        timings['upload'] = uploadWatch.elapsed;
        if (_localRevisionChangedSince(revisionAtStart)) {
          _syncRequestedAgain = true;
          return;
        }
        if (uploadResult.statusCode < 200 || uploadResult.statusCode >= 300) {
          await _appendSyncLog(
            _formatSyncTimings(
              timings,
              total: overall.elapsed,
              attempt: attempt,
              mergeDetails: mergeResult.timings,
            ),
            debugOnly: true,
          );
          await _recordSyncStatus(
            'error',
            '上传失败(${uploadResult.statusCode})',
          );
          return;
        }
        final verifyWatch = Stopwatch()..start();
        final verify = await client.download();
        timings['verify'] = verifyWatch.elapsed;
        if (!_isSuccessfulDownloadStatus(verify.statusCode) ||
            verify.payload == null ||
            verify.payload!.trim().isEmpty) {
          if (_localRevisionChangedSince(revisionAtStart)) {
            _syncRequestedAgain = true;
            return;
          }
          await _appendSyncLog(
            _formatSyncTimings(
              timings,
              total: overall.elapsed,
              attempt: attempt,
              mergeDetails: mergeResult.timings,
            ),
            debugOnly: true,
          );
          await _recordSyncStatus(
            'error',
            _buildSyncFailureMessage('校验失败', verify.statusCode),
          );
          return;
        }
        final verifyPayload = verify.payload!;
        final verifyRevision = _decodePayload(verifyPayload).revision;
        if (verifyRevision == mergeResult.revision) {
          if (_localRevisionChangedSince(revisionAtStart)) {
            _syncRequestedAgain = true;
            return;
          }
          await _appendSyncLog(
            _formatSyncTimings(
              timings,
              total: overall.elapsed,
              attempt: attempt,
              mergeDetails: mergeResult.timings,
            ),
            debugOnly: true,
          );
          await _updateSyncRevision(mergeResult.revision);
          await _recordSyncStatus(
            'success',
            '同步完成：合并${mergeResult.stats.total}项，冲突${mergeResult.stats.conflicts}项，删除${mergeResult.stats.deletes}项，修订${mergeResult.revision}',
          );
          return;
        }
        if (attempt == maxAttempts) {
          await _appendSyncLog(
            _formatSyncTimings(
              timings,
              total: overall.elapsed,
              attempt: attempt,
              mergeDetails: mergeResult.timings,
            ),
            debugOnly: true,
          );
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

  Future<String> exportItemData(VaultItem item) async {
    _ensureUnlocked();
    final currentItem = await _vaultService.getById(
      item.id,
      masterPassword: _masterPassword!,
    );
    if (currentItem == null || currentItem.isDeleted) {
      throw StateError('条目不存在或已删除');
    }
    final exportedItem = await _buildExportItemData(currentItem);
    if (exportedItem == null) {
      throw StateError('无法解密条目');
    }
    return const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'scope': 'item',
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'item': exportedItem,
    });
  }

  Future<String> exportCategoryData(String category) async {
    _ensureUnlocked();
    final normalizedCategory = category.trim();
    final items = await _vaultService.listAll(masterPassword: _masterPassword!);
    final exportedItems = <Map<String, Object?>>[];
    for (final item in items) {
      if (item.isDeleted) {
        continue;
      }
      final exportedItem = await _buildExportItemData(item);
      if (exportedItem == null) {
        continue;
      }
      final itemCategory = exportedItem['category'] as String? ?? '';
      if (itemCategory == normalizedCategory) {
        exportedItems.add(exportedItem);
      }
    }
    exportedItems.sort((a, b) {
      final left = a['label'] as String? ?? '';
      final right = b['label'] as String? ?? '';
      return left.compareTo(right);
    });
    return const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'scope': 'category',
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'category': normalizedCategory,
      'count': exportedItems.length,
      'items': exportedItems,
    });
  }

  Future<ImportPreview> previewItemImport(String contents) async {
    _ensureUnlocked();
    final importedItems = _parseImportContents(
      contents,
      expectedScope: ImportScope.item,
    );
    final plan = await _buildImportPlan(
      importedItems,
      scope: ImportScope.item,
    );
    return _buildImportPreview(plan);
  }

  Future<ImportPreview> previewCategoryImport(String contents) async {
    _ensureUnlocked();
    final importedItems = _parseImportContents(
      contents,
      expectedScope: ImportScope.category,
    );
    final plan = await _buildImportPlan(
      importedItems,
      scope: ImportScope.category,
    );
    return _buildImportPreview(plan);
  }

  Future<ImportExecutionResult> importItemData(
    String contents, {
    ImportConflictStrategy strategy = ImportConflictStrategy.keepCopy,
  }) async {
    _ensureUnlocked();
    final importedItems = _parseImportContents(
      contents,
      expectedScope: ImportScope.item,
    );
    final plan = await _buildImportPlan(
      importedItems,
      scope: ImportScope.item,
    );
    return _executeImportPlan(plan, strategy: strategy);
  }

  Future<ImportExecutionResult> importCategoryData(
    String contents, {
    ImportConflictStrategy strategy = ImportConflictStrategy.keepCopy,
  }) async {
    _ensureUnlocked();
    final importedItems = _parseImportContents(
      contents,
      expectedScope: ImportScope.category,
    );
    final plan = await _buildImportPlan(
      importedItems,
      scope: ImportScope.category,
    );
    return _executeImportPlan(plan, strategy: strategy);
  }

  Future<void> clearAllEntries() async {
    _ensureUnlocked();
    final items = await _vaultService.listAll(masterPassword: _masterPassword!);
    var changed = false;
    for (final item in items) {
      final tombstone = await _softDeleteItem(item);
      changed = changed || tombstone != null;
    }
    if (changed) {
      _recordLocalMutationForSync();
    }
    await reloadWithOptions(eagerDecrypt: false);
    _scheduleSyncSoon();
  }

  Future<Map<String, Object?>?> _buildExportItemData(VaultItem item) async {
    Object? payload;
    String category = '';
    switch (item.type) {
      case VaultEntryType.credential:
        final credential = await readEntry(item);
        if (credential == null) {
          return null;
        }
        payload = credential.toJson();
        category = credential.category.trim();
        break;
      case VaultEntryType.server:
        final server = await readServerAsset(item);
        if (server == null) {
          return null;
        }
        payload = server.toJson();
        category = server.category.trim();
        break;
      case VaultEntryType.service:
        final service = await readService(item);
        if (service == null) {
          return null;
        }
        payload = service.toJson();
        category = service.category.trim();
        break;
    }
    return {
      'id': item.id,
      'label': item.label,
      'type': item.type.name,
      'category': category,
      'createdAt': item.createdAt.toUtc().toIso8601String(),
      'updatedAt': item.updatedAt.toUtc().toIso8601String(),
      'version': item.version,
      'updatedBy': item.updatedBy,
      'payload': payload,
    };
  }

  Map<String, Object?> _decodeJsonObject(String contents) {
    final decoded = jsonDecode(contents);
    if (decoded is! Map) {
      throw const FormatException('JSON 顶层结构必须是对象');
    }
    return Map<String, Object?>.from(decoded);
  }

  List<_ImportedVaultItem> _parseImportContents(
    String contents, {
    required ImportScope expectedScope,
  }) {
    final decoded = _decodeJsonObject(contents);
    switch (expectedScope) {
      case ImportScope.item:
        if (decoded['scope'] != 'item') {
          throw const FormatException('不是单条条目导出 JSON');
        }
        final rawItem = decoded['item'];
        if (rawItem is! Map) {
          throw const FormatException('缺少条目数据');
        }
        return [_parseImportedItem(Map<String, Object?>.from(rawItem))];
      case ImportScope.category:
        if (decoded['scope'] != 'category') {
          throw const FormatException('不是分类导出 JSON');
        }
        final rawItems = decoded['items'];
        if (rawItems is! List) {
          throw const FormatException('缺少分类条目列表');
        }
        return rawItems
            .whereType<Map>()
            .map(
                (entry) => _parseImportedItem(Map<String, Object?>.from(entry)))
            .toList();
    }
  }

  _ImportedVaultItem _parseImportedItem(Map<String, Object?> json) {
    final label = json['label'] as String? ?? '';
    final sourceId = json['id'] as String? ?? '';
    final typeName = json['type'] as String? ?? '';
    final rawPayload = json['payload'];
    if (rawPayload is! Map) {
      throw const FormatException('条目 payload 格式无效');
    }
    final payloadJson = Map<String, Object?>.from(rawPayload);

    switch (typeName) {
      case 'credential':
        return _ImportedVaultItem(
          sourceId: sourceId,
          label: label,
          type: VaultEntryType.credential,
          payload: CredentialPayload.fromJson(payloadJson),
        );
      case 'server':
        return _ImportedVaultItem(
          sourceId: sourceId,
          label: label,
          type: VaultEntryType.server,
          payload: ServerAssetPayload.fromJson(payloadJson),
        );
      case 'service':
        return _ImportedVaultItem(
          sourceId: sourceId,
          label: label,
          type: VaultEntryType.service,
          payload: ServicePayload.fromJson(payloadJson),
        );
    }
    throw FormatException('不支持的条目类型: $typeName');
  }

  Future<VaultItem> _createImportedItem(
    _ImportedVaultItem imported, {
    Map<String, String> idMap = const {},
  }) async {
    switch (imported.type) {
      case VaultEntryType.credential:
        return addEntry(
          label: imported.label,
          payload: imported.payload as CredentialPayload,
        );
      case VaultEntryType.server:
        return addServerAsset(
          label: imported.label,
          payload: imported.payload as ServerAssetPayload,
        );
      case VaultEntryType.service:
        final payload = imported.payload as ServicePayload;
        final remappedPayload = ServicePayload(
          name: payload.name,
          connectionAddress: payload.connectionAddress,
          connectionPort: payload.connectionPort,
          accountId: payload.accountId == null
              ? null
              : (idMap[payload.accountId!] ?? payload.accountId),
          serverIds: payload.serverIds
              .map((entry) => idMap[entry] ?? entry)
              .toList(growable: false),
          accounts: payload.accounts,
          notes: payload.notes,
          tags: payload.tags,
          category: payload.category,
        );
        return addService(
          label: imported.label,
          payload: remappedPayload,
        );
    }
  }

  Future<_ImportPlan> _buildImportPlan(
    List<_ImportedVaultItem> importedItems, {
    required ImportScope scope,
  }) async {
    final previewIdMap = <String, String>{};
    final planItems = <_ImportPlanItem>[];

    Future<void> appendPlanItem(_ImportedVaultItem imported) async {
      final existing = await _findImportTarget(
        imported,
        idMap: previewIdMap,
      );
      final disposition = existing == null
          ? ImportItemDisposition.create
          : await _importPayloadEquals(
              existing,
              imported,
              idMap: previewIdMap,
            )
              ? ImportItemDisposition.exactDuplicate
              : ImportItemDisposition.conflict;
      if (existing != null && imported.sourceId.isNotEmpty) {
        previewIdMap[imported.sourceId] = existing.id;
      }
      planItems.add(
        _ImportPlanItem(
          imported: imported,
          disposition: disposition,
          existingItem: existing,
        ),
      );
    }

    for (final imported in importedItems.where(
      (entry) => entry.type != VaultEntryType.service,
    )) {
      await appendPlanItem(imported);
    }
    for (final imported in importedItems.where(
      (entry) => entry.type == VaultEntryType.service,
    )) {
      await appendPlanItem(imported);
    }
    return _ImportPlan(scope: scope, items: planItems);
  }

  ImportPreview _buildImportPreview(_ImportPlan plan) {
    return ImportPreview(
      scope: plan.scope,
      items: plan.items
          .map(
            (item) => ImportPreviewItem(
              label: item.imported.label,
              type: item.imported.type,
              category: _importedCategory(item.imported),
              disposition: item.disposition,
              existingLabel: item.existingItem?.label,
            ),
          )
          .toList(growable: false),
    );
  }

  Future<ImportExecutionResult> _executeImportPlan(
    _ImportPlan plan, {
    required ImportConflictStrategy strategy,
  }) async {
    var createdCount = 0;
    var updatedCount = 0;
    var skippedCount = 0;
    final idMap = <String, String>{};

    await _runWithNotificationsSuppressed(() async {
      for (final item in plan.items) {
        final imported = item.imported;
        switch (item.disposition) {
          case ImportItemDisposition.create:
            final created = await _createImportedItem(imported, idMap: idMap);
            createdCount += 1;
            if (imported.sourceId.isNotEmpty) {
              idMap[imported.sourceId] = created.id;
            }
            break;
          case ImportItemDisposition.exactDuplicate:
            skippedCount += 1;
            if (item.existingItem != null && imported.sourceId.isNotEmpty) {
              idMap[imported.sourceId] = item.existingItem!.id;
            }
            break;
          case ImportItemDisposition.conflict:
            if (strategy == ImportConflictStrategy.skip) {
              skippedCount += 1;
              if (item.existingItem != null && imported.sourceId.isNotEmpty) {
                idMap[imported.sourceId] = item.existingItem!.id;
              }
              break;
            }
            if (strategy == ImportConflictStrategy.overwrite &&
                item.existingItem != null) {
              final updated = await _updateImportedItem(
                item.existingItem!,
                imported,
                idMap: idMap,
              );
              updatedCount += 1;
              if (imported.sourceId.isNotEmpty) {
                idMap[imported.sourceId] = updated.id;
              }
              break;
            }
            final created = await _createImportedItem(imported, idMap: idMap);
            createdCount += 1;
            if (imported.sourceId.isNotEmpty) {
              idMap[imported.sourceId] = created.id;
            }
            break;
        }
      }
    });

    return ImportExecutionResult(
      scope: plan.scope,
      totalCount: plan.items.length,
      createdCount: createdCount,
      updatedCount: updatedCount,
      skippedCount: skippedCount,
    );
  }

  Future<VaultItem?> _findImportTarget(
    _ImportedVaultItem imported, {
    Map<String, String> idMap = const {},
  }) async {
    final importedLabel = imported.label.trim().toLowerCase();
    final importedCategory = _importedCategory(imported).trim().toLowerCase();
    VaultItem? fallback;
    for (final item in _items) {
      if (item.isDeleted ||
          item.type != imported.type ||
          item.label.trim().toLowerCase() != importedLabel) {
        continue;
      }
      fallback ??= item;
      final category = await _readItemCategory(item);
      if (category.trim().toLowerCase() == importedCategory) {
        return item;
      }
    }
    return fallback;
  }

  Future<String> _readItemCategory(VaultItem item) async {
    switch (item.type) {
      case VaultEntryType.credential:
        return (await readEntry(item))?.category ?? '';
      case VaultEntryType.server:
        return (await readServerAsset(item))?.category ?? '';
      case VaultEntryType.service:
        return (await readService(item))?.category ?? '';
    }
  }

  Future<bool> _importPayloadEquals(
    VaultItem existing,
    _ImportedVaultItem imported, {
    Map<String, String> idMap = const {},
  }) async {
    final importedPayload = _resolveImportedPayload(imported, idMap: idMap);
    switch (existing.type) {
      case VaultEntryType.credential:
        final current = await readEntry(existing);
        return current != null &&
            jsonEncode(current.toJson()) ==
                jsonEncode((importedPayload as CredentialPayload).toJson());
      case VaultEntryType.server:
        final current = await readServerAsset(existing);
        return current != null &&
            jsonEncode(current.toJson()) ==
                jsonEncode((importedPayload as ServerAssetPayload).toJson());
      case VaultEntryType.service:
        final current = await readService(existing);
        return current != null &&
            jsonEncode(current.toJson()) ==
                jsonEncode((importedPayload as ServicePayload).toJson());
    }
  }

  Object _resolveImportedPayload(
    _ImportedVaultItem imported, {
    Map<String, String> idMap = const {},
  }) {
    switch (imported.type) {
      case VaultEntryType.credential:
        return imported.payload;
      case VaultEntryType.server:
        final payload = imported.payload as ServerAssetPayload;
        return ServerAssetPayload(
          name: payload.name,
          ipAddress: payload.ipAddress,
          port: payload.port,
          username: payload.username,
          password: payload.password,
          basicConfig: payload.basicConfig,
          operatingSystem: payload.operatingSystem,
          location: payload.location,
          notes: payload.notes,
          tags: payload.tags,
          accountId: payload.accountId == null
              ? null
              : (idMap[payload.accountId!] ?? payload.accountId),
          category: payload.category,
        );
      case VaultEntryType.service:
        final payload = imported.payload as ServicePayload;
        return ServicePayload(
          name: payload.name,
          connectionAddress: payload.connectionAddress,
          connectionPort: payload.connectionPort,
          accountId: payload.accountId == null
              ? null
              : (idMap[payload.accountId!] ?? payload.accountId),
          serverIds: payload.serverIds
              .map((entry) => idMap[entry] ?? entry)
              .toList(growable: false),
          accounts: payload.accounts,
          notes: payload.notes,
          tags: payload.tags,
          category: payload.category,
        );
    }
  }

  String _importedCategory(_ImportedVaultItem imported) {
    switch (imported.type) {
      case VaultEntryType.credential:
        return (imported.payload as CredentialPayload).category;
      case VaultEntryType.server:
        return (imported.payload as ServerAssetPayload).category;
      case VaultEntryType.service:
        return (imported.payload as ServicePayload).category;
    }
  }

  Future<VaultItem> _updateImportedItem(
    VaultItem existing,
    _ImportedVaultItem imported, {
    Map<String, String> idMap = const {},
  }) async {
    switch (existing.type) {
      case VaultEntryType.credential:
        return updateEntry(
          item: existing,
          label: imported.label,
          payload: _resolveImportedPayload(
            imported,
            idMap: idMap,
          ) as CredentialPayload,
        );
      case VaultEntryType.server:
        return updateServerAsset(
          item: existing,
          label: imported.label,
          payload: _resolveImportedPayload(
            imported,
            idMap: idMap,
          ) as ServerAssetPayload,
        );
      case VaultEntryType.service:
        return updateService(
          item: existing,
          label: imported.label,
          payload:
              _resolveImportedPayload(imported, idMap: idMap) as ServicePayload,
        );
    }
  }

  Future<List<VaultEntryView>> _buildEntryViews(
    List<VaultItem> items, {
    int? maxWorkers,
    int yieldStride = 25,
    Duration pauseBetweenItems = Duration.zero,
  }) async {
    final visibleItems = items.where((item) => !item.isDeleted).toList();
    if (visibleItems.isEmpty) {
      return const <VaultEntryView>[];
    }
    final views = List<VaultEntryView?>.filled(visibleItems.length, null);
    final workerCount = min(maxWorkers ?? 4, visibleItems.length);
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        final index = nextIndex++;
        if (index >= visibleItems.length) {
          return;
        }
        views[index] = await _buildEntryViewForItem(visibleItems[index]);
        if (pauseBetweenItems > Duration.zero) {
          await Future<void>.delayed(pauseBetweenItems);
        }
        await _yieldIfNeeded(index, stride: yieldStride);
      }
    }

    await Future.wait(
      List<Future<void>>.generate(workerCount, (_) => worker()),
    );
    return views.whereType<VaultEntryView>().toList(growable: false);
  }

  Future<VaultEntryView> _buildEntryViewForItem(VaultItem item) async {
    if (item.type == VaultEntryType.server) {
      ServerAssetPayload? payload;
      try {
        payload = await readServerAsset(item);
      } catch (_) {
        payload = null;
      }
      return _buildEntryView(
        item: item,
        credential: null,
        server: payload,
        service: null,
        tags: payload?.tags ?? const [],
        isConflict: _isConflictItem(item),
      );
    }
    if (item.type == VaultEntryType.service) {
      ServicePayload? payload;
      try {
        payload = await readService(item);
      } catch (_) {
        payload = null;
      }
      return _buildEntryView(
        item: item,
        credential: null,
        server: null,
        service: payload,
        tags: payload?.tags ?? const [],
        isConflict: _isConflictItem(item),
      );
    }
    CredentialPayload? payload;
    try {
      payload = await readEntry(item);
    } catch (_) {
      payload = null;
    }
    return _buildEntryView(
      item: item,
      credential: payload,
      server: null,
      service: null,
      tags: payload?.tags ?? const [],
      isConflict: _isConflictItem(item),
    );
  }

  VaultEntryView _buildEntryView({
    required VaultItem item,
    required CredentialPayload? credential,
    required ServerAssetPayload? server,
    required ServicePayload? service,
    required List<String> tags,
    required bool isConflict,
  }) {
    final resolvedTags = (tags.isEmpty ? item.metadataTags : tags)
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
    final category = (credential?.category ??
            server?.category ??
            service?.category ??
            item.metadataCategory)
        .trim();
    return VaultEntryView(
      item: item,
      credential: credential,
      server: server,
      service: service,
      category: category,
      tags: resolvedTags,
      isConflict: isConflict,
      searchIndex: _buildSearchIndex(
        item: item,
        credential: credential,
        server: server,
        service: service,
        tags: resolvedTags,
      ),
    );
  }

  VaultEntrySearchIndex _buildSearchIndex({
    required VaultItem item,
    required CredentialPayload? credential,
    required ServerAssetPayload? server,
    required ServicePayload? service,
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
    final categoryLower = lowerOrNull(
      credential?.category ??
          server?.category ??
          service?.category ??
          item.metadataCategory,
    );
    final tagsLower = tags.isEmpty
        ? const <String>[]
        : tags.map((tag) => tag.toLowerCase()).toList(growable: false);
    final anyLower = _buildAnyLower(
      labelLower: labelLower,
      appIdLower: appIdLower,
      serverNameLower: serverNameLower,
      serverIpLower: serverIpLower,
      categoryLower: categoryLower,
      tagsLower: tagsLower,
    );
    return VaultEntrySearchIndex(
      labelLower: labelLower,
      appIdLower: appIdLower,
      serverNameLower: serverNameLower,
      serverIpLower: serverIpLower,
      categoryLower: categoryLower,
      tagsLower: tagsLower,
      anyLower: anyLower,
    );
  }

  String _buildAnyLower({
    required String labelLower,
    required String? appIdLower,
    required String? serverNameLower,
    required String? serverIpLower,
    required String? categoryLower,
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
    if (categoryLower != null && categoryLower.isNotEmpty) {
      buffer.write('\n');
      buffer.write(categoryLower);
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
            service: null,
            tags: const [],
            isConflict: _isConflictItem(item),
          ),
        )
        .toList();
  }

  Future<void> _hydrateEntryViews(
    List<VaultItem> items,
    int hydrationToken, {
    bool lowPriority = false,
  }) async {
    final watch = Stopwatch()..start();
    if (!_isUnlocked || hydrationToken != _entryHydrationToken) {
      return;
    }
    if (lowPriority) {
      // Give first frames after unlock higher priority.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!_isUnlocked || hydrationToken != _entryHydrationToken) {
        return;
      }
    }
    _logDebugPerf('hydrate.start', {
      'token': hydrationToken,
      'items': items.length,
      'mode': lowPriority ? 'lowPriority' : 'normal',
    });
    final views = await _buildEntryViews(
      items,
      maxWorkers: lowPriority ? 1 : null,
      yieldStride: lowPriority ? 1 : 25,
      pauseBetweenItems:
          lowPriority ? const Duration(milliseconds: 1) : Duration.zero,
    );
    if (!_isUnlocked || hydrationToken != _entryHydrationToken) {
      _logDebugPerf('hydrate.skip', {
        'stage': 'afterBuild',
        'token': hydrationToken,
        'elapsedMs': watch.elapsedMilliseconds,
      });
      return;
    }
    _setEntryViews(views);
    final metadataWatch = Stopwatch()..start();
    await _refreshMetadataCollectionsFromViews(views);
    metadataWatch.stop();
    _notifyListeners();
    _logDebugPerf('hydrate.done', {
      'token': hydrationToken,
      'views': views.length,
      'backfill': 'disabled',
      'mode': lowPriority ? 'lowPriority' : 'normal',
      'metadataMs': metadataWatch.elapsedMilliseconds,
      'totalMs': watch.elapsedMilliseconds,
    });
    _isHydratingEntryViews = false;
  }

  Future<void> _postUnlockLoad(String masterPassword, int unlockToken) async {
    final watch = Stopwatch()..start();
    try {
      final migrateWatch = Stopwatch()..start();
      await _vaultService
          .migrateLegacyRecords(masterPassword)
          .timeout(const Duration(seconds: 8));
      var metadataMigratedCount = 0;
      if (!_syncSettings.syncMasterKey &&
          !_metadata.recordKeyMetadataMigrated) {
        metadataMigratedCount = await _vaultService
            .migrateMetadataToRecordKey(masterPassword)
            .timeout(const Duration(seconds: 8));
        _metadata = _metadata.copyWith(recordKeyMetadataMigrated: true);
        await _saveMetadata();
      } else if (!_syncSettings.syncMasterKey) {
        _logDebugPerf('postUnlock.skipRecordKeyMigration', {
          'token': unlockToken,
          'reason': 'flag',
        });
      }
      migrateWatch.stop();
      if (!_isUnlocked ||
          _masterPassword != masterPassword ||
          unlockToken != _postUnlockToken) {
        _logDebugPerf('postUnlock.skip', {
          'stage': 'afterMigrate',
          'token': unlockToken,
          'migrateMs': migrateWatch.elapsedMilliseconds,
          'elapsedMs': watch.elapsedMilliseconds,
        });
        return;
      }
      final loadWatch = Stopwatch()..start();
      await Future.wait([
        _loadSyncSettings(),
        _loadMetadata(),
      ]).timeout(const Duration(seconds: 8));
      loadWatch.stop();
      if (!_isUnlocked ||
          _masterPassword != masterPassword ||
          unlockToken != _postUnlockToken) {
        _logDebugPerf('postUnlock.skip', {
          'stage': 'afterLoadSettings',
          'token': unlockToken,
          'migrateMs': migrateWatch.elapsedMilliseconds,
          'loadMs': loadWatch.elapsedMilliseconds,
          'elapsedMs': watch.elapsedMilliseconds,
        });
        return;
      }
      if (_syncSettings.autoSyncOnUnlock && _appIsActive) {
        _scheduleResumeSync();
      }
      _logDebugPerf('postUnlock.done', {
        'token': unlockToken,
        'recordMigrated': metadataMigratedCount,
        'migrateMs': migrateWatch.elapsedMilliseconds,
        'loadMs': loadWatch.elapsedMilliseconds,
        'totalMs': watch.elapsedMilliseconds,
      });
    } on TimeoutException {
      await _recordSyncStatus('warning', '解锁后的后台恢复超时，已跳过本次恢复');
      _logDebugPerf('postUnlock.timeout', {
        'token': unlockToken,
        'elapsedMs': watch.elapsedMilliseconds,
      });
    } catch (error) {
      await _recordSyncStatus('warning', '解锁后的后台恢复失败: $error');
      _logDebugPerf('postUnlock.error', {
        'token': unlockToken,
        'elapsedMs': watch.elapsedMilliseconds,
        'error': '$error',
      });
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

  Future<void> _ensureCategory(String category) async {
    final trimmed = category.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final newCategories = {..._metadata.categories, trimmed}.toList()..sort();
    if (listEquals(newCategories, _metadata.categories)) {
      return;
    }
    _metadata = _withUpdatedCategories(newCategories);
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
          accountId: payload.accountId,
          category: payload.category,
        );
        await updateServerAsset(
          item: item,
          label: item.label,
          payload: updatedPayload,
        );
      } else if (item.type == VaultEntryType.service) {
        final payload = await readService(item);
        if (payload == null || !payload.tags.contains(tag)) {
          continue;
        }
        final updatedTags =
            payload.tags.where((entry) => entry != tag).toList();
        final updatedPayload = ServicePayload(
          name: payload.name,
          connectionAddress: payload.connectionAddress,
          connectionPort: payload.connectionPort,
          accountId: payload.accountId,
          serverIds: payload.serverIds,
          accounts: payload.accounts,
          notes: payload.notes,
          tags: updatedTags,
          category: payload.category,
        );
        await updateService(
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
          accessKey: payload.accessKey,
          secretKey: payload.secretKey,
          notes: payload.notes,
          tags: updatedTags,
          category: payload.category,
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
          accountId: payload.accountId,
          category: payload.category,
        );
        await updateServerAsset(
          item: item,
          label: item.label,
          payload: updatedPayload,
        );
      } else if (item.type == VaultEntryType.service) {
        final payload = await readService(item);
        if (payload == null || !payload.tags.contains(oldTag)) {
          continue;
        }
        final updatedTags = payload.tags
            .map((entry) => entry == oldTag ? newTag : entry)
            .toList();
        final updatedPayload = ServicePayload(
          name: payload.name,
          connectionAddress: payload.connectionAddress,
          connectionPort: payload.connectionPort,
          accountId: payload.accountId,
          serverIds: payload.serverIds,
          accounts: payload.accounts,
          notes: payload.notes,
          tags: updatedTags,
          category: payload.category,
        );
        await updateService(
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
          accessKey: payload.accessKey,
          secretKey: payload.secretKey,
          notes: payload.notes,
          tags: updatedTags,
          category: payload.category,
        );
        await updateEntry(
          item: item,
          label: item.label,
          payload: updatedPayload,
        );
      }
    }
  }

  Future<void> _removeCategoryFromEntries(String category) async {
    final items = await _vaultService.listAll(masterPassword: _masterPassword!);
    for (final item in items) {
      if (item.isDeleted) {
        continue;
      }
      if (item.type == VaultEntryType.server) {
        final payload = await readServerAsset(item);
        if (payload == null || payload.category != category) {
          continue;
        }
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
          tags: payload.tags,
          accountId: payload.accountId,
          category: '',
        );
        await updateServerAsset(
          item: item,
          label: item.label,
          payload: updatedPayload,
        );
      } else if (item.type == VaultEntryType.service) {
        final payload = await readService(item);
        if (payload == null || payload.category != category) {
          continue;
        }
        final updatedPayload = ServicePayload(
          name: payload.name,
          connectionAddress: payload.connectionAddress,
          connectionPort: payload.connectionPort,
          accountId: payload.accountId,
          serverIds: payload.serverIds,
          accounts: payload.accounts,
          notes: payload.notes,
          tags: payload.tags,
          category: '',
        );
        await updateService(
          item: item,
          label: item.label,
          payload: updatedPayload,
        );
      } else {
        final payload = await readEntry(item);
        if (payload == null || payload.category != category) {
          continue;
        }
        final updatedPayload = CredentialPayload(
          username: payload.username,
          password: payload.password,
          token: payload.token,
          appId: payload.appId,
          accessKey: payload.accessKey,
          secretKey: payload.secretKey,
          notes: payload.notes,
          tags: payload.tags,
          category: '',
        );
        await updateEntry(
          item: item,
          label: item.label,
          payload: updatedPayload,
        );
      }
    }
  }

  Future<void> _replaceCategoryInEntries(
    String oldCategory,
    String newCategory,
  ) async {
    final items = await _vaultService.listAll(masterPassword: _masterPassword!);
    for (final item in items) {
      if (item.isDeleted) {
        continue;
      }
      if (item.type == VaultEntryType.server) {
        final payload = await readServerAsset(item);
        if (payload == null || payload.category != oldCategory) {
          continue;
        }
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
          tags: payload.tags,
          accountId: payload.accountId,
          category: newCategory,
        );
        await updateServerAsset(
          item: item,
          label: item.label,
          payload: updatedPayload,
        );
      } else if (item.type == VaultEntryType.service) {
        final payload = await readService(item);
        if (payload == null || payload.category != oldCategory) {
          continue;
        }
        final updatedPayload = ServicePayload(
          name: payload.name,
          connectionAddress: payload.connectionAddress,
          connectionPort: payload.connectionPort,
          accountId: payload.accountId,
          serverIds: payload.serverIds,
          accounts: payload.accounts,
          notes: payload.notes,
          tags: payload.tags,
          category: newCategory,
        );
        await updateService(
          item: item,
          label: item.label,
          payload: updatedPayload,
        );
      } else {
        final payload = await readEntry(item);
        if (payload == null || payload.category != oldCategory) {
          continue;
        }
        final updatedPayload = CredentialPayload(
          username: payload.username,
          password: payload.password,
          token: payload.token,
          appId: payload.appId,
          accessKey: payload.accessKey,
          secretKey: payload.secretKey,
          notes: payload.notes,
          tags: payload.tags,
          category: newCategory,
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
    if (!wasSyncingMasterKey &&
        _syncSettings.syncMasterKey &&
        _metadata.recordKeyMetadataMigrated) {
      _metadata = _metadata.copyWith(recordKeyMetadataMigrated: false);
      await _saveMetadata();
    }
    if (wasSyncingMasterKey && !_syncSettings.syncMasterKey) {
      final migrated =
          await _vaultService.migrateMetadataToRecordKey(_masterPassword!);
      if (!_metadata.recordKeyMetadataMigrated || migrated > 0) {
        _metadata = _metadata.copyWith(recordKeyMetadataMigrated: true);
        await _saveMetadata();
      }
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
    await _saveMetadata(markLocalChange: true);
    _scheduleSyncSoon();
    _notifyListeners();
  }

  Future<void> addCategory(String category) async {
    _ensureUnlocked();
    final trimmed = category.trim();
    if (trimmed.isEmpty) {
      return;
    }
    if (_metadata.categories.contains(trimmed)) {
      return;
    }
    final updated = [..._metadata.categories, trimmed]..sort();
    _metadata = _withUpdatedCategories(updated);
    await _saveMetadata(markLocalChange: true);
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
      await _saveMetadata(markLocalChange: true);
    }
    await _replaceTagInEntries(oldTag, trimmed);
    await reload();
    _scheduleSyncSoon();
  }

  Future<void> renameCategory(String oldCategory, String newCategory) async {
    _ensureUnlocked();
    final trimmed = newCategory.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final updatedCategories = _metadata.categories
        .map((entry) => entry == oldCategory ? trimmed : entry)
        .toSet()
        .toList()
      ..sort();
    if (!listEquals(updatedCategories, _metadata.categories)) {
      _metadata = _withUpdatedCategories(updatedCategories);
      await _saveMetadata(markLocalChange: true);
    }
    await _replaceCategoryInEntries(oldCategory, trimmed);
    await reload();
    _scheduleSyncSoon();
  }

  Future<void> deleteTag(String tag) async {
    _ensureUnlocked();
    final updatedTags = _metadata.tags.where((entry) => entry != tag).toList()
      ..sort();
    if (!listEquals(updatedTags, _metadata.tags)) {
      _metadata = _withUpdatedTags(updatedTags);
      await _saveMetadata(markLocalChange: true);
    }
    await _removeTagFromEntries(tag);
    await reload();
    _scheduleSyncSoon();
  }

  Future<void> deleteCategory(String category) async {
    _ensureUnlocked();
    final updatedCategories = _metadata.categories
        .where((entry) => entry != category)
        .toList()
      ..sort();
    if (!listEquals(updatedCategories, _metadata.categories)) {
      _metadata = _withUpdatedCategories(updatedCategories);
      await _saveMetadata(markLocalChange: true);
    }
    await _removeCategoryFromEntries(category);
    await reload();
    _scheduleSyncSoon();
  }

  Future<void> updateSortOrder(VaultSortOrder order) async {
    _ensureUnlocked();
    _metadata = _metadata.copyWith(sortOrder: order);
    await _saveMetadata(markLocalChange: true);
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

  Future<void> _yieldIfNeeded(int index, {int stride = 25}) async {
    if (index % stride == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  VaultMetadata _withUpdatedTags(List<String> tags) {
    return _metadata.copyWith(tags: tags, tagsUpdatedAt: _nowUtcMillis());
  }

  VaultMetadata _withUpdatedCategories(List<String> categories) {
    return _metadata.copyWith(
      categories: categories,
      categoriesUpdatedAt: _nowUtcMillis(),
    );
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
      if (existingMetadata != null && existingMetadata.kdfSalt.isNotEmpty) {
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
        final sanitizedLogs = _sanitizeSyncLogsForCurrentBuild(
          _syncSettings.logs,
        );
        if (!listEquals(sanitizedLogs, _syncSettings.logs)) {
          _syncSettings = _syncSettings.copyWith(logs: sanitizedLogs);
          await _saveSyncSettings();
        }
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

  Future<void> _saveMetadata({bool markLocalChange = false}) async {
    final record = await _encryptMetadataRecord(_metadata);
    await _vaultMetadataStore.save(record);
    if (markLocalChange) {
      _recordLocalMutationForSync();
    }
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
      var index = 0;
      for (final record in pending) {
        await _yieldIfNeeded(index);
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
        index++;
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
    final kdfIterations = _masterKeyRecord?.metadataIterations ??
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
    if (!_appIsActive || !_syncSettings.autoSyncEnabled || !_isUnlocked) {
      return;
    }
    final minutes = _syncSettings.autoSyncIntervalMinutes;
    final interval = Duration(minutes: minutes <= 0 ? 30 : minutes);
    _syncTimer = Timer.periodic(interval, (_) {
      unawaited(syncNow());
    });
  }

  void _pauseAutoSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _syncDebounceTimer?.cancel();
    _syncDebounceTimer = null;
    _resumeSyncTimer?.cancel();
    _resumeSyncTimer = null;
  }

  void _scheduleResumeSync() {
    _resumeSyncTimer?.cancel();
    if (!_appIsActive || !_isUnlocked || !_syncSettings.autoSyncEnabled) {
      return;
    }
    final delay = _isHydratingEntryViews
        ? const Duration(seconds: 12)
        : const Duration(seconds: 2);
    _resumeSyncTimer = Timer(delay, () {
      if (!_isUnlocked || !_appIsActive) {
        return;
      }
      if (_isHydratingEntryViews) {
        _scheduleResumeSync();
        return;
      }
      unawaited(syncNow());
    });
  }

  void _scheduleSyncSoon() {
    if (!_appIsActive || !_isUnlocked || !_syncSettings.autoSyncEnabled) {
      return;
    }
    _syncDebounceTimer?.cancel();
    _syncDebounceTimer = Timer(const Duration(seconds: 5), () {
      unawaited(syncNow());
    });
  }

  void _recoverStalledOperations() {
    final startedAt = _syncStartedAt;
    if (_syncInProgress &&
        startedAt != null &&
        DateTime.now().difference(startedAt) > const Duration(seconds: 45)) {
      _syncInProgress = false;
      _syncStartedAt = null;
      unawaited(_recordSyncStatus('warning', '检测到同步挂起，已自动重置同步状态'));
      _notifyListeners();
    }
  }

  bool _isSuccessfulDownloadStatus(int statusCode) {
    return statusCode == 404 || (statusCode >= 200 && statusCode < 300);
  }

  String _buildSyncFailureMessage(String action, int statusCode) {
    switch (statusCode) {
      case 408:
        return '$action超时，请在网络恢复后重试';
      case 503:
        return '$action失败，网络或服务暂不可用';
      case 404:
        return '$action失败，远端文件不存在';
      default:
        return '$action($statusCode)';
    }
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
    final localItems = await _resolveLocalItems(local.records, localSessionKey);
    mergeTimings['local'] = localWatch.elapsed;
    if (remotePayload == null || remotePayload.trim().isEmpty) {
      final deleteCount = localItems.where((item) => item.isDeleted).length;
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
        final shortId = who.length > 6 ? who.substring(who.length - 6) : who;
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
    final localMetadata = mergedTags.localMetadata ?? _metadata;
    final remoteMetadata = mergedTags.remoteMetadata;
    final mergedRecordKeyMetadataMigrated = _syncSettings.syncMasterKey
        ? false
        : _resolveRecordKeyMetadataMigrated(
            local: localMetadata,
            remote: remoteMetadata,
          );
    final mergedMetadata = _metadata.copyWith(
      tags: mergedTags.tags.toList()..sort(),
      categories: mergedTags.categories.toList()..sort(),
      tagsUpdatedAt: mergedTagsUpdatedAt,
      categoriesUpdatedAt: mergedTags.categoriesUpdatedAt,
      recordKeyMetadataMigrated: mergedRecordKeyMetadataMigrated,
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
    final mergedMasterKeyPayload = _syncSettings.syncMasterKey
        ? (remoteResolution != null ? remote.masterKey : local.masterKey)
        : null;
    final matchesLocal = _sameItemList(mergeResult.items, localItems) &&
        _sameMetadata(mergedMetadata, localMetadata) &&
        _sameMasterKeyPayload(mergedMasterKeyPayload, local.masterKey);
    final matchesRemote = _sameItemList(mergeResult.items, remoteItems) &&
        _sameMetadata(mergedMetadata, remoteMetadata) &&
        _sameMasterKeyPayload(mergedMasterKeyPayload, remote.masterKey);
    final canReuseRemotePayload =
        remoteSessionKey == null || _sameKey(remoteSessionKey, _metadataKey);
    if (matchesRemote && canReuseRemotePayload) {
      mergeTimings['metadata'] = metadataWatch.elapsed;
      return _SyncMergeResult(
        payload: remotePayload,
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
    for (var index = 0; index < mergeResult.items.length; index++) {
      await _yieldIfNeeded(index);
      final item = mergeResult.items[index];
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
        if (remoteItem != null &&
            identical(item, remoteItem) &&
            canReuseRemotePayload) {
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

  Future<void> _applySyncPayload(
    String payload, {
    required int revisionAtStart,
  }) async {
    final decoded = _decodePayload(payload);
    final upgradedRecords = <VaultItemRecord>[];
    for (var index = 0; index < decoded.records.length; index++) {
      await _yieldIfNeeded(index);
      final record = decoded.records[index];
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
    if (_localRevisionChangedSince(revisionAtStart)) {
      _syncRequestedAgain = true;
      return;
    }
    await _vaultService.saveRecords(upgradedRecords);
    if (decoded.metadataRecord != null) {
      if (_localRevisionChangedSince(revisionAtStart)) {
        _syncRequestedAgain = true;
        return;
      }
      await _vaultMetadataStore.save(decoded.metadataRecord!);
      final decodedMeta = await _decryptMetadataRecord(decoded.metadataRecord!);
      if (decodedMeta != null) {
        _metadata = decodedMeta;
      }
    } else {
      final items = await _vaultService.decryptRecords(
        upgradedRecords,
        masterPassword: _masterPassword!,
      );
      await _refreshMetadataCollections(
        items: items,
        extraTags: decoded.legacyTags,
      );
    }
    await reloadWithOptions(eagerDecrypt: false);
  }

  Future<void> _recordSyncStatus(String status, String message) async {
    final entry = SyncLogEntry(
      timestamp: DateTime.now().toUtc(),
      message: message,
      level: status == 'error' ? 'error' : 'info',
    );
    final currentLogs = _sanitizeSyncLogsForCurrentBuild(_syncSettings.logs);
    final updatedLogs = [entry, ...currentLogs];
    final trimmedLogs =
        updatedLogs.length > 50 ? updatedLogs.sublist(0, 50) : updatedLogs;
    _syncSettings = _syncSettings.copyWith(
      lastSyncAt: entry.timestamp,
      lastSyncStatus: status,
      lastSyncMessage: message,
      logs: trimmedLogs,
    );
    await _saveSyncSettings();
    _notifyListeners();
  }

  Future<void> _appendSyncLog(
    String message, {
    String level = 'info',
    bool debugOnly = false,
  }) async {
    if (debugOnly && !kDebugMode) {
      return;
    }
    if (!kDebugMode && _isSyncTimingLog(message)) {
      return;
    }
    final entry = SyncLogEntry(
      timestamp: DateTime.now().toUtc(),
      message: message,
      level: level,
    );
    final currentLogs = _sanitizeSyncLogsForCurrentBuild(_syncSettings.logs);
    final updatedLogs = [entry, ...currentLogs];
    final trimmedLogs =
        updatedLogs.length > 50 ? updatedLogs.sublist(0, 50) : updatedLogs;
    _syncSettings = _syncSettings.copyWith(logs: trimmedLogs);
    await _saveSyncSettings();
    _notifyListeners();
  }

  List<SyncLogEntry> _sanitizeSyncLogsForCurrentBuild(
    List<SyncLogEntry> logs,
  ) {
    if (kDebugMode) {
      return logs;
    }
    return logs.where((entry) => !_isSyncTimingLog(entry.message)).toList();
  }

  bool _isSyncTimingLog(String message) {
    return message.contains('同步耗时(');
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
      masterKey:
          masterKey != null ? Map<String, Object?>.from(masterKey) : null,
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
    final skipLargeEmptyTags = _shouldSkipLargeEmptyTagScan(
      localMetadata,
      remoteMetadata,
      items.length,
    );
    final shouldScanItems = !skipLargeEmptyTags &&
        _shouldScanItemMetadata(
          localMetadata,
          remoteMetadata,
        );
    final itemTags = shouldScanItems
        ? _normalizeTags(await _collectTagsFromItems(items))
        : <String>{};
    final itemCategories = shouldScanItems
        ? _normalizeCategories(await _collectCategoriesFromItems(items))
        : <String>{};

    var baseTags = <String>{};
    var baseUpdatedAt = 0;
    var baseCategories = <String>{};
    var baseCategoriesUpdatedAt = 0;
    if (localMetadata != null && remoteMetadata != null) {
      final localTags = _normalizeTags(localMetadata.tags);
      final remoteTags = _normalizeTags(remoteMetadata.tags);
      final localCategories = _normalizeCategories(localMetadata.categories);
      final remoteCategories = _normalizeCategories(remoteMetadata.categories);
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
      if (localMetadata.categoriesUpdatedAt !=
          remoteMetadata.categoriesUpdatedAt) {
        if (localMetadata.categoriesUpdatedAt >
            remoteMetadata.categoriesUpdatedAt) {
          baseCategories = localCategories;
          baseCategoriesUpdatedAt = localMetadata.categoriesUpdatedAt;
        } else {
          baseCategories = remoteCategories;
          baseCategoriesUpdatedAt = remoteMetadata.categoriesUpdatedAt;
        }
      } else {
        baseCategories = {...localCategories, ...remoteCategories};
        baseCategoriesUpdatedAt = localMetadata.categoriesUpdatedAt;
      }
    } else if (localMetadata != null) {
      baseTags = _normalizeTags(localMetadata.tags);
      baseUpdatedAt = localMetadata.tagsUpdatedAt;
      baseCategories = _normalizeCategories(localMetadata.categories);
      baseCategoriesUpdatedAt = localMetadata.categoriesUpdatedAt;
    } else if (remoteMetadata != null) {
      baseTags = _normalizeTags(remoteMetadata.tags);
      baseUpdatedAt = remoteMetadata.tagsUpdatedAt;
      baseCategories = _normalizeCategories(remoteMetadata.categories);
      baseCategoriesUpdatedAt = remoteMetadata.categoriesUpdatedAt;
    }

    final mergedTags = {...baseTags, ...itemTags};
    final mergedCategories = {...baseCategories, ...itemCategories};
    var mergedUpdatedAt = baseUpdatedAt;
    var mergedCategoriesUpdatedAt = baseCategoriesUpdatedAt;
    if (mergedUpdatedAt == 0 && mergedTags.isNotEmpty) {
      mergedUpdatedAt = _nowUtcMillis();
    }
    if (!_setEquals(mergedTags, baseTags)) {
      mergedUpdatedAt = _nowUtcMillis();
    }
    if (mergedCategoriesUpdatedAt == 0 && mergedCategories.isNotEmpty) {
      mergedCategoriesUpdatedAt = _nowUtcMillis();
    }
    if (!_setEquals(mergedCategories, baseCategories)) {
      mergedCategoriesUpdatedAt = _nowUtcMillis();
    }
    if (shouldScanItems && mergedUpdatedAt == 0) {
      mergedUpdatedAt = _nowUtcMillis();
    }
    if (shouldScanItems && mergedCategoriesUpdatedAt == 0) {
      mergedCategoriesUpdatedAt = _nowUtcMillis();
    }
    if (skipLargeEmptyTags && mergedUpdatedAt == 0) {
      mergedUpdatedAt = _nowUtcMillis();
    }
    if (skipLargeEmptyTags && mergedCategoriesUpdatedAt == 0) {
      mergedCategoriesUpdatedAt = _nowUtcMillis();
    }
    return _MergedTags(
      tags: mergedTags,
      categories: mergedCategories,
      updatedAt: mergedUpdatedAt,
      categoriesUpdatedAt: mergedCategoriesUpdatedAt,
      localMetadata: localMetadata,
      remoteMetadata: remoteMetadata,
    );
  }

  bool _shouldSkipLargeEmptyTagScan(
    VaultMetadata? localMetadata,
    VaultMetadata? remoteMetadata,
    int itemCount,
  ) {
    if (itemCount < _tagScanSkipThreshold) {
      return false;
    }
    final localUpdatedAt = localMetadata?.tagsUpdatedAt ?? 0;
    final remoteUpdatedAt = remoteMetadata?.tagsUpdatedAt ?? 0;
    if (localUpdatedAt > 0 || remoteUpdatedAt > 0) {
      return false;
    }
    final hasTags = (localMetadata?.tags.isNotEmpty ?? false) ||
        (remoteMetadata?.tags.isNotEmpty ?? false);
    return !hasTags;
  }

  bool _shouldScanItemMetadata(
    VaultMetadata? localMetadata,
    VaultMetadata? remoteMetadata,
  ) {
    if (localMetadata == null || remoteMetadata == null) {
      return true;
    }
    final hasUpdatedAt =
        localMetadata.tagsUpdatedAt > 0 || remoteMetadata.tagsUpdatedAt > 0;
    if (hasUpdatedAt) {
      return false;
    }
    final hasTags =
        localMetadata.tags.isNotEmpty || remoteMetadata.tags.isNotEmpty;
    final hasCategories = localMetadata.categories.isNotEmpty ||
        remoteMetadata.categories.isNotEmpty;
    return !hasTags || !hasCategories;
  }

  Future<Set<String>> _collectTagsFromItems(List<VaultItem> items) async {
    final tagSet = <String>{};
    for (var index = 0; index < items.length; index++) {
      await _yieldIfNeeded(index);
      final item = items[index];
      if (item.isDeleted) {
        continue;
      }
      if (item.type == VaultEntryType.server) {
        final payload = await readServerAsset(item);
        if (payload != null) {
          tagSet.addAll(payload.tags);
        }
      } else if (item.type == VaultEntryType.service) {
        final payload = await readService(item);
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

  Future<Set<String>> _collectCategoriesFromItems(List<VaultItem> items) async {
    final categorySet = <String>{};
    for (var index = 0; index < items.length; index++) {
      await _yieldIfNeeded(index);
      final item = items[index];
      if (item.isDeleted) {
        continue;
      }
      if (item.type == VaultEntryType.server) {
        final payload = await readServerAsset(item);
        final category = payload?.category.trim() ?? '';
        if (category.isNotEmpty) {
          categorySet.add(category);
        }
      } else if (item.type == VaultEntryType.service) {
        final payload = await readService(item);
        final category = payload?.category.trim() ?? '';
        if (category.isNotEmpty) {
          categorySet.add(category);
        }
      } else {
        final payload = await readEntry(item);
        final category = payload?.category.trim() ?? '';
        if (category.isNotEmpty) {
          categorySet.add(category);
        }
      }
    }
    return categorySet;
  }

  Set<String> _normalizeTags(Iterable<String> tags) {
    return tags.map((tag) => tag.trim()).where((tag) => tag.isNotEmpty).toSet();
  }

  Set<String> _normalizeCategories(Iterable<String> categories) {
    return categories
        .map((category) => category.trim())
        .where((category) => category.isNotEmpty)
        .toSet();
  }

  Future<void> _refreshMetadataCollections({
    required List<VaultItem> items,
    required List<String> extraTags,
  }) async {
    final tagSet = <String>{..._metadata.tags, ...extraTags};
    final categorySet = <String>{..._metadata.categories};
    for (var index = 0; index < items.length; index++) {
      await _yieldIfNeeded(index);
      final item = items[index];
      if (item.isDeleted) {
        continue;
      }
      if (item.type == VaultEntryType.server) {
        final payload = await readServerAsset(item);
        if (payload != null) {
          tagSet.addAll(payload.tags);
          final category = payload.category.trim();
          if (category.isNotEmpty) {
            categorySet.add(category);
          }
        }
      } else if (item.type == VaultEntryType.service) {
        final payload = await readService(item);
        if (payload != null) {
          tagSet.addAll(payload.tags);
          final category = payload.category.trim();
          if (category.isNotEmpty) {
            categorySet.add(category);
          }
        }
      } else {
        final payload = await readEntry(item);
        if (payload != null) {
          tagSet.addAll(payload.tags);
          final category = payload.category.trim();
          if (category.isNotEmpty) {
            categorySet.add(category);
          }
        }
      }
    }
    final updatedTags = tagSet
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final updatedCategories = categorySet
        .map((category) => category.trim())
        .where((category) => category.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    if (listEquals(updatedTags, _metadata.tags) &&
        listEquals(updatedCategories, _metadata.categories)) {
      return;
    }
    _metadata = _metadata.copyWith(
      tags: updatedTags,
      categories: updatedCategories,
      tagsUpdatedAt: _nowUtcMillis(),
      categoriesUpdatedAt: _nowUtcMillis(),
    );
    await _saveMetadata();
  }

  bool _isConflictItem(VaultItem item) {
    return item.label.contains('(冲突-') || item.label.contains('冲突');
  }

  void _applyLocalItemUpdate(
    VaultItem item, {
    CredentialPayload? credential,
    ServerAssetPayload? server,
    required List<String> tags,
    ServicePayload? service,
    bool forceNotify = false,
  }) {
    if (item.isDeleted) {
      _payloadCache.remove(item.id);
    } else {
      _storeCachedPayload(item, credential ?? server ?? service);
    }
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
        credential: credential,
        server: server,
        service: service,
        tags: tags,
        isConflict: _isConflictItem(item),
      );
      if (viewIndex >= 0) {
        updatedViews[viewIndex] = view;
      } else {
        updatedViews.add(view);
      }
    }
    _setEntryViews(updatedViews);
    _recordLocalMutationForSync();
    _notifyListeners(allowWhileSuppressed: forceNotify);
  }

  void _recordLocalMutationForSync() {
    _localChangeRevision += 1;
    if (_syncInProgress) {
      _syncRequestedAgain = true;
    }
  }

  bool _localRevisionChangedSince(int revision) {
    return _localChangeRevision != revision;
  }

  void _setEntryViews(List<VaultEntryView> views) {
    _entryViews = views;
    _entryViewsVersion += 1;
  }

  Future<void> _refreshMetadataCollectionsFromViews(
    List<VaultEntryView> views,
  ) async {
    final tagSet = <String>{..._metadata.tags};
    final categorySet = <String>{..._metadata.categories};
    for (final view in views) {
      if (view.item.isDeleted) {
        continue;
      }
      tagSet.addAll(view.tags.where((tag) => tag.trim().isNotEmpty));
      final category = view.category.trim();
      if (category.isNotEmpty) {
        categorySet.add(category);
      }
    }
    final updatedTags = tagSet.toList()..sort();
    final updatedCategories = categorySet.toList()..sort();
    if (listEquals(updatedTags, _metadata.tags) &&
        listEquals(updatedCategories, _metadata.categories)) {
      return;
    }
    final now = _nowUtcMillis();
    _metadata = _metadata.copyWith(
      tags: updatedTags,
      categories: updatedCategories,
      tagsUpdatedAt: now,
      categoriesUpdatedAt: now,
    );
    await _saveMetadata();
  }

  T? _readCachedPayload<T>(VaultItem item) {
    final cached = _payloadCache[item.id];
    if (cached == null || cached.cacheKey != _payloadCacheKey(item)) {
      return null;
    }
    final payload = cached.payload;
    return payload is T ? payload as T : null;
  }

  void _storeCachedPayload(VaultItem item, Object? payload) {
    if (payload == null || item.isDeleted) {
      _payloadCache.remove(item.id);
      return;
    }
    _payloadCache[item.id] = _PayloadCacheEntry(
      cacheKey: _payloadCacheKey(item),
      payload: payload,
    );
  }

  void _prunePayloadCache(List<VaultItem> items) {
    final validIds =
        items.where((item) => !item.isDeleted).map((item) => item.id).toSet();
    _payloadCache.removeWhere((key, _) => !validIds.contains(key));
  }

  void _logDebugPerf(String stage, [Map<String, Object?> details = const {}]) {
    if (!kDebugMode || !_enablePerfLogs) {
      return;
    }
    final buffer = StringBuffer('[Perf][$stage]');
    if (details.isNotEmpty) {
      details.forEach((key, value) {
        buffer.write(' $key=$value');
      });
    }
    debugPrint(buffer.toString());
  }

  String _payloadCacheKey(VaultItem item) {
    return '${item.type.name}|${item.updatedAt.microsecondsSinceEpoch}|'
        '${item.deletedAt?.microsecondsSinceEpoch ?? 0}|${item.isDeleted}';
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
      metadataCategory: item.metadataCategory,
      metadataTags: item.metadataTags,
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
        a.categoriesUpdatedAt == b.categoriesUpdatedAt &&
        a.recordKeyMetadataMigrated == b.recordKeyMetadataMigrated &&
        listEquals(a.tags, b.tags) &&
        listEquals(a.categories, b.categories);
  }

  bool _resolveRecordKeyMetadataMigrated({
    required VaultMetadata? local,
    required VaultMetadata? remote,
  }) {
    if (local == null && remote == null) {
      return _metadata.recordKeyMetadataMigrated;
    }
    if (local != null && remote != null) {
      return local.recordKeyMetadataMigrated &&
          remote.recordKeyMetadataMigrated;
    }
    return (local ?? remote)!.recordKeyMetadataMigrated;
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
        a.metadataCategory == b.metadataCategory &&
        listEquals(a.metadataTags, b.metadataTags) &&
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
    required this.service,
    required this.category,
    required this.tags,
    required this.isConflict,
    required this.searchIndex,
  });

  final VaultItem item;
  final CredentialPayload? credential;
  final ServerAssetPayload? server;
  final ServicePayload? service;
  final String category;
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
    required this.categoryLower,
    required this.tagsLower,
    required this.anyLower,
  });

  final String labelLower;
  final String? appIdLower;
  final String? serverNameLower;
  final String? serverIpLower;
  final String? categoryLower;
  final List<String> tagsLower;
  final String anyLower;
}

enum ImportScope { item, category }

enum ImportConflictStrategy { skip, overwrite, keepCopy }

enum ImportItemDisposition { create, exactDuplicate, conflict }

class ImportPreview {
  const ImportPreview({
    required this.scope,
    required this.items,
  });

  final ImportScope scope;
  final List<ImportPreviewItem> items;

  int get totalCount => items.length;
  int get createCount => items
      .where((item) => item.disposition == ImportItemDisposition.create)
      .length;
  int get exactDuplicateCount => items
      .where((item) => item.disposition == ImportItemDisposition.exactDuplicate)
      .length;
  int get conflictCount => items
      .where((item) => item.disposition == ImportItemDisposition.conflict)
      .length;
  bool get hasConflicts => exactDuplicateCount > 0 || conflictCount > 0;
}

class ImportPreviewItem {
  const ImportPreviewItem({
    required this.label,
    required this.type,
    required this.category,
    required this.disposition,
    this.existingLabel,
  });

  final String label;
  final VaultEntryType type;
  final String category;
  final ImportItemDisposition disposition;
  final String? existingLabel;
}

class ImportExecutionResult {
  const ImportExecutionResult({
    required this.scope,
    required this.totalCount,
    required this.createdCount,
    required this.updatedCount,
    required this.skippedCount,
  });

  final ImportScope scope;
  final int totalCount;
  final int createdCount;
  final int updatedCount;
  final int skippedCount;
}

class _ImportPlan {
  const _ImportPlan({
    required this.scope,
    required this.items,
  });

  final ImportScope scope;
  final List<_ImportPlanItem> items;
}

class _ImportPlanItem {
  const _ImportPlanItem({
    required this.imported,
    required this.disposition,
    this.existingItem,
  });

  final _ImportedVaultItem imported;
  final ImportItemDisposition disposition;
  final VaultItem? existingItem;
}

class _ImportedVaultItem {
  const _ImportedVaultItem({
    required this.sourceId,
    required this.label,
    required this.type,
    required this.payload,
  });

  final String sourceId;
  final String label;
  final VaultEntryType type;
  final Object payload;
}

class _MergedTags {
  const _MergedTags({
    required this.tags,
    required this.categories,
    required this.updatedAt,
    required this.categoriesUpdatedAt,
    this.localMetadata,
    this.remoteMetadata,
  });

  final Set<String> tags;
  final Set<String> categories;
  final int updatedAt;
  final int categoriesUpdatedAt;
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

class _PayloadCacheEntry {
  const _PayloadCacheEntry({
    required this.cacheKey,
    required this.payload,
  });

  final String cacheKey;
  final Object payload;
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
