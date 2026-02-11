import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:password_manager_auth/password_manager_auth.dart';
import 'package:password_manager_backup/password_manager_backup.dart';
import 'package:password_manager_core/password_manager_core.dart';
import 'package:password_manager_crypto/password_manager_crypto.dart';
import 'package:password_manager_storage/password_manager_storage.dart';
import 'package:password_manager_sync/password_manager_sync.dart';

import 'screens/home_screen.dart';
import 'screens/unlock_screen.dart';
import 'state/vault_controller.dart';

class PasswordManagerApp extends StatelessWidget {
  const PasswordManagerApp({super.key, required this.controller});

  final VaultController controller;

  static Future<PasswordManagerApp> bootstrap() async {
    VaultRepository repository;
    MasterKeyStore masterKeyStore;
    if (kIsWeb) {
      repository = InMemoryVaultRepository();
      masterKeyStore = InMemoryMasterKeyStore();
    } else {
      try {
        final directory = await getApplicationSupportDirectory();
        final vaultPath = path.join(directory.path, 'vault.json');
        final masterKeyPath = path.join(directory.path, 'master_key.json');
        repository = LocalFileVaultRepository(filePath: vaultPath);
        masterKeyStore = LocalFileMasterKeyStore(filePath: masterKeyPath);
      } catch (error) {
        debugPrint('Vault storage fallback to memory: $error');
        repository = InMemoryVaultRepository();
        masterKeyStore = InMemoryMasterKeyStore();
      }
    }
    final keyDerivationService = KeyDerivationService();
    final vaultService = VaultService(
      cryptoService: AesGcmCryptoService(),
      keyDerivationService: keyDerivationService,
      repository: repository,
    );
    final controller = VaultController(
      vaultService: vaultService,
      syncProvider: NoopSyncProvider(),
      backupService: NoopBackupService(),
      totpService: const TotpService(),
      keyDerivationService: keyDerivationService,
      masterKeyStore: masterKeyStore,
      requireTotp: false,
      totpSecret: null,
    );
    await controller.initialize();
    return PasswordManagerApp(controller: controller);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0F4C5C),
      brightness: Brightness.light,
    );
    return MaterialApp(
      title: '密码管理器',
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF6F6F2),
        textTheme: const TextTheme(
          headlineMedium: TextStyle(fontWeight: FontWeight.w700),
          titleMedium: TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      home: VaultShell(controller: controller),
    );
  }
}

class VaultShell extends StatelessWidget {
  const VaultShell({super.key, required this.controller});

  final VaultController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return controller.isUnlocked
            ? HomeScreen(controller: controller)
            : UnlockScreen(controller: controller);
      },
    );
  }
}
