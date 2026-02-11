import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:password_manager_auth/password_manager_auth.dart';
import 'package:password_manager_backup/password_manager_backup.dart';
import 'package:password_manager_core/password_manager_core.dart';
import 'package:password_manager_crypto/password_manager_crypto.dart';
import 'package:password_manager_storage/password_manager_storage.dart';
import 'package:password_manager_sync/password_manager_sync.dart';

class VaultController extends ChangeNotifier {
  VaultController({
    required VaultService vaultService,
    required SyncProvider syncProvider,
    required BackupService backupService,
    required TotpService totpService,
    required KeyDerivationService keyDerivationService,
    required MasterKeyStore masterKeyStore,
    required bool requireTotp,
    required String? totpSecret,
  })  : _vaultService = vaultService,
        _syncProvider = syncProvider,
        _backupService = backupService,
        _totpService = totpService,
        _keyDerivationService = keyDerivationService,
        _masterKeyStore = masterKeyStore,
        _requireTotp = requireTotp,
        _totpSecret = totpSecret;

  final VaultService _vaultService;
  final SyncProvider _syncProvider;
  final BackupService _backupService;
  final TotpService _totpService;
  final KeyDerivationService _keyDerivationService;
  final MasterKeyStore _masterKeyStore;
  final bool _requireTotp;
  final String? _totpSecret;

  bool _isUnlocked = false;
  String? _masterPassword;
  MasterKeyRecord? _masterKeyRecord;
  List<VaultItem> _items = [];

  bool get isUnlocked => _isUnlocked;
  bool get requireTotp => _requireTotp;
  bool get hasMasterKey => _masterKeyRecord != null;
  List<VaultItem> get items => List.unmodifiable(_items);

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
    await reload();
    notifyListeners();
    return true;
  }

  Future<void> lock() async {
    _masterPassword = null;
    _isUnlocked = false;
    _items = [];
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

  Future<void> syncNow() async {
    await _syncProvider.pushAll();
    await _syncProvider.pullAll();
    notifyListeners();
  }

  Future<void> runBackup() async {
    await _backupService.runBackup();
    notifyListeners();
  }

  Future<SyncStatus> syncStatus() => _syncProvider.status();

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
