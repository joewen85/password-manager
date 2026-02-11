import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:password_manager_auth/password_manager_auth.dart';
import 'package:password_manager_backup/password_manager_backup.dart';
import 'package:password_manager_core/password_manager_core.dart';
import 'package:password_manager_crypto/password_manager_crypto.dart';
import 'package:password_manager_storage/password_manager_storage.dart';

import 'screens/home_screen.dart';
import 'screens/unlock_screen.dart';
import 'storage/sync_settings_store_selector.dart';
import 'storage/vault_metadata_store_selector.dart';
import 'storage/web_storage.dart';
import 'state/sync_settings.dart';
import 'state/vault_controller.dart';
import 'state/vault_metadata.dart';

class PasswordManagerApp extends StatelessWidget {
  const PasswordManagerApp({super.key, required this.controller});

  final VaultController controller;

  static Future<PasswordManagerApp> bootstrap() async {
    VaultRepository repository;
    MasterKeyStore masterKeyStore;
    if (kIsWeb) {
      final webStorage = await openWebStorage();
      repository = webStorage.repository;
      masterKeyStore = webStorage.masterKeyStore;
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
    final cryptoService = AesGcmCryptoService();
    final vaultService = VaultService(
      cryptoService: cryptoService,
      keyDerivationService: keyDerivationService,
      repository: repository,
    );
    SyncSettingsStore settingsStore;
    VaultMetadataStore metadataStore;
    if (kIsWeb) {
      settingsStore = WebSyncSettingsStore();
      metadataStore = WebVaultMetadataStore();
    } else {
      final directory = await getApplicationSupportDirectory();
      final settingsPath = path.join(directory.path, 'sync_settings.json');
      settingsStore = FileSyncSettingsStore(filePath: settingsPath);
      final metadataPath = path.join(directory.path, 'vault_metadata.json');
      metadataStore = FileVaultMetadataStore(filePath: metadataPath);
    }
    final controller = VaultController(
      vaultService: vaultService,
      backupService: NoopBackupService(),
      cryptoService: cryptoService,
      totpService: const TotpService(),
      keyDerivationService: keyDerivationService,
      masterKeyStore: masterKeyStore,
      syncSettingsStore: settingsStore,
      initialSyncSettings: SyncSettings.defaults(),
      vaultMetadataStore: metadataStore,
      initialMetadata: VaultMetadata.defaults(),
      requireTotp: false,
      totpSecret: null,
    );
    await controller.initialize();
    return PasswordManagerApp(controller: controller);
  }

  @override
  Widget build(BuildContext context) {
    final baseScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0F4C5C),
      brightness: Brightness.light,
    );
    final colorScheme = baseScheme.copyWith(
      primary: const Color(0xFF0F4C5C),
      secondary: const Color(0xFF2F7F79),
      tertiary: const Color(0xFFF2B880),
      surface: const Color(0xFFFDFBF6),
      surfaceVariant: const Color(0xFFF0F2F0),
      background: const Color(0xFFF4F6F0),
      outline: const Color(0xFFC6D1D5),
      outlineVariant: const Color(0xFFE1E6E8),
    );
    final textTheme = GoogleFonts.notoSansSCTextTheme().apply(
      bodyColor: colorScheme.onSurface,
      displayColor: colorScheme.onSurface,
    );
    return MaterialApp(
      title: '密码管理器',
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: colorScheme.background,
        textTheme: textTheme.copyWith(
          headlineMedium: textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
          headlineSmall: textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
          titleMedium: textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          titleTextStyle: textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
          iconTheme: IconThemeData(color: colorScheme.onSurface),
        ),
        cardTheme: CardTheme(
          color: Colors.white,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF8F7F4),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: colorScheme.outlineVariant),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: colorScheme.outlineVariant),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: colorScheme.primary, width: 1.4),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            textStyle: textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        chipTheme: ChipThemeData(
          backgroundColor: const Color(0xFFF0F2F0),
          selectedColor: colorScheme.primaryContainer,
          labelStyle: textTheme.labelLarge,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
            side: BorderSide(color: colorScheme.outlineVariant),
          ),
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: colorScheme.primary,
          foregroundColor: Colors.white,
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? colorScheme.primaryContainer
                  : Colors.white,
            ),
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? colorScheme.onPrimaryContainer
                  : colorScheme.onSurface,
            ),
            side: WidgetStatePropertyAll(
              BorderSide(color: colorScheme.outlineVariant),
            ),
          ),
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
