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
import '../sync/remote_sync_client.dart';
import 'sync_settings.dart';

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
        _requireTotp = requireTotp,
        _totpSecret = totpSecret;

  final VaultService _vaultService;
  final BackupService _backupService;
  final CryptoService _cryptoService;
  final TotpService _totpService;
  final KeyDerivationService _keyDerivationService;
  final MasterKeyStore _masterKeyStore;
  final SyncSettingsStore _syncSettingsStore;
  final bool _requireTotp;
  final String? _totpSecret;
  SyncSettings _syncSettings;

  bool _isUnlocked = false;
  String? _masterPassword;
  MasterKeyRecord? _masterKeyRecord;
  List<VaultItem> _items = [];
  bool _syncInProgress = false;
  Timer? _syncTimer;

  bool get isUnlocked => _isUnlocked;
  bool get requireTotp => _requireTotp;
  bool get hasMasterKey => _masterKeyRecord != null;
  List<VaultItem> get items => List.unmodifiable(_items);
  SyncSettings get syncSettings => _syncSettings;
  bool get isSyncing => _syncInProgress;

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
    await _loadSyncSettings();
    await reload();
    if (_syncSettings.autoSyncOnUnlock) {
      await syncNow();
    }
    notifyListeners();
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
    _ensureUnlocked();
    _items = await _vaultService.listAll();
    notifyListeners();
  }

  Future<VaultItem> addEntry({
    required String label,
    required CredentialPayload payload,
  }) async {
    _ensureUnlocked();
    final item = await _vaultService.addCredential(
      payload,
      label: label,
      masterPassword: _masterPassword!,
      nonce: _generateNonce(),
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
    final updated = await _vaultService.updateCredential(
      item,
      payload,
      label: label,
      masterPassword: _masterPassword!,
      nonce: _generateNonce(),
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

  Future<void> deleteEntry(String id) async {
    _ensureUnlocked();
    await _vaultService.delete(id);
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
      final localPayload = await _buildSyncPayload();
      final remoteResult = await client.download();
      final mergedPayload = await _mergeWithRemote(
        localPayload: localPayload,
        remotePayload: remoteResult.payload,
      );
      await _applySyncPayload(mergedPayload);
      final uploadResult = await client.upload(mergedPayload);
      if (uploadResult.statusCode >= 200 &&
          uploadResult.statusCode < 300) {
        await _recordSyncStatus('success', '同步完成');
      } else {
        await _recordSyncStatus(
          'error',
          '上传失败(${uploadResult.statusCode})',
        );
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
      await _vaultService.delete(item.id);
    }
    await reload();
  }

  Future<void> updateSyncSettings(SyncSettings settings) async {
    _ensureUnlocked();
    _syncSettings = settings;
    await _saveSyncSettings();
    _configureAutoSync();
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
      }
    } catch (_) {}
    _configureAutoSync();
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
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'masterKey': _syncSettings.syncMasterKey ? record?.toJson() : null,
      'items': items.map(vaultItemToJson).toList(),
    };
    return jsonEncode(payload);
  }

  Future<String> _mergeWithRemote({
    required String localPayload,
    required String? remotePayload,
  }) async {
    if (remotePayload == null || remotePayload.trim().isEmpty) {
      return localPayload;
    }
    final local = _decodePayload(localPayload);
    final remote = _decodePayload(remotePayload);
    final mergedItems = _mergeItems(
      localItems: local.items,
      remoteItems: remote.items,
      strategy: _syncSettings.conflictStrategy,
    );
    final mergedPayload = {
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'masterKey': _syncSettings.syncMasterKey
          ? (remote.masterKey ?? local.masterKey)
          : null,
      'items': mergedItems.map(vaultItemToJson).toList(),
    };
    return jsonEncode(mergedPayload);
  }

  Future<void> _applySyncPayload(String payload) async {
    final decoded = _decodePayload(payload);
    final merged = decoded.items;
    final existing = await _vaultService.listAll();
    final incomingIds = merged.map((entry) => entry.id).toSet();
    for (final item in existing) {
      if (!incomingIds.contains(item.id)) {
        await _vaultService.delete(item.id);
      }
    }
    for (final item in merged) {
      await _vaultService.saveItem(item);
    }
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

  _DecodedPayload _decodePayload(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded is! Map) {
      return const _DecodedPayload(items: [], masterKey: null);
    }
    final masterKey = decoded['masterKey'] as Map?;
    final items = (decoded['items'] as List? ?? [])
        .whereType<Map>()
        .map((entry) => vaultItemFromJson(Map<String, Object?>.from(entry)))
        .toList();
    return _DecodedPayload(
      items: items,
      masterKey: masterKey != null
          ? Map<String, Object?>.from(masterKey)
          : null,
    );
  }

  List<VaultItem> _mergeItems({
    required List<VaultItem> localItems,
    required List<VaultItem> remoteItems,
    required ConflictStrategy strategy,
  }) {
    final localMap = {for (final item in localItems) item.id: item};
    final remoteMap = {for (final item in remoteItems) item.id: item};
    final allIds = {...localMap.keys, ...remoteMap.keys};
    final result = <VaultItem>[];
    for (final id in allIds) {
      final local = localMap[id];
      final remote = remoteMap[id];
      if (local == null) {
        result.add(remote!);
        continue;
      }
      if (remote == null) {
        result.add(local);
        continue;
      }
      if (local.updatedAt.isAtSameMomentAs(remote.updatedAt)) {
        result.add(local);
        continue;
      }
      switch (strategy) {
        case ConflictStrategy.remoteWins:
          result.add(remote);
          break;
        case ConflictStrategy.localWins:
          result.add(local);
          break;
        case ConflictStrategy.keepBoth:
          result.add(local);
          final cloned = VaultItem(
            id: _generateId(),
            label: '${remote.label} (冲突-远端)',
            encryptedPayload: remote.encryptedPayload,
            kdfSalt: remote.kdfSalt,
            kdfIterations: remote.kdfIterations,
            createdAt: remote.createdAt,
            updatedAt: remote.updatedAt,
          );
          result.add(cloned);
          break;
      }
    }
    return result;
  }

  String _generateId() {
    final random = Random.secure();
    return '${DateTime.now().microsecondsSinceEpoch}-${random.nextInt(1 << 32)}';
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

class _DecodedPayload {
  const _DecodedPayload({required this.items, required this.masterKey});

  final List<VaultItem> items;
  final Map<String, Object?>? masterKey;
}
