import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:password_manager_auth/password_manager_auth.dart';
import 'package:password_manager_backup/password_manager_backup.dart';
import 'package:password_manager_core/password_manager_core.dart';
import 'package:password_manager_sync/password_manager_sync.dart';

class VaultController extends ChangeNotifier {
  VaultController({
    required VaultService vaultService,
    required SyncProvider syncProvider,
    required BackupService backupService,
    required TotpService totpService,
    required bool requireTotp,
    required String? totpSecret,
  })  : _vaultService = vaultService,
        _syncProvider = syncProvider,
        _backupService = backupService,
        _totpService = totpService,
        _requireTotp = requireTotp,
        _totpSecret = totpSecret;

  final VaultService _vaultService;
  final SyncProvider _syncProvider;
  final BackupService _backupService;
  final TotpService _totpService;
  final bool _requireTotp;
  final String? _totpSecret;

  bool _isUnlocked = false;
  String? _masterPassword;
  List<VaultItem> _items = [];

  bool get isUnlocked => _isUnlocked;
  bool get requireTotp => _requireTotp;
  List<VaultItem> get items => List.unmodifiable(_items);

  Future<bool> unlock(String masterPassword, {String? totpCode}) async {
    if (_requireTotp) {
      if (_totpSecret == null || totpCode == null) {
        return false;
      }
      if (!_totpService.verifyCode(_totpSecret!, totpCode)) {
        return false;
      }
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
}
