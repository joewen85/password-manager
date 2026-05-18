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
import 'utils/adaptive_layout.dart';

class PasswordManagerApp extends StatelessWidget {
  const PasswordManagerApp({super.key, required this.controller});

  final VaultController controller;
  static const bool _isTest = bool.fromEnvironment('FLUTTER_TEST');

  static Future<PasswordManagerApp> bootstrap() async {
    String? supportDirectoryPath;
    if (!kIsWeb) {
      try {
        supportDirectoryPath = (await getApplicationSupportDirectory()).path;
      } catch (error) {
        debugPrint('File storage fallback to memory: $error');
      }
    }

    VaultRepository repository;
    MasterKeyStore masterKeyStore;
    if (kIsWeb) {
      final webStorage = await openWebStorage();
      repository = webStorage.repository;
      masterKeyStore = webStorage.masterKeyStore;
    } else if (supportDirectoryPath != null) {
      final vaultPath = path.join(supportDirectoryPath, 'vault.json');
      final masterKeyPath = path.join(supportDirectoryPath, 'master_key.json');
      repository = LocalFileVaultRepository(filePath: vaultPath);
      masterKeyStore = LocalFileMasterKeyStore(filePath: masterKeyPath);
    } else {
      repository = InMemoryVaultRepository();
      masterKeyStore = InMemoryMasterKeyStore();
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
    } else if (supportDirectoryPath != null) {
      final settingsPath =
          path.join(supportDirectoryPath, 'sync_settings.json');
      settingsStore = FileSyncSettingsStore(filePath: settingsPath);
      final metadataPath =
          path.join(supportDirectoryPath, 'vault_metadata.json');
      metadataStore = FileVaultMetadataStore(filePath: metadataPath);
    } else {
      settingsStore = MemorySyncSettingsStore();
      metadataStore = MemoryVaultMetadataStore();
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
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    ThemeData buildTheme(Brightness brightness) {
      final baseScheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF0F4C5C),
        brightness: brightness,
      );
      final colorScheme = brightness == Brightness.light
          ? baseScheme.copyWith(
              primary: const Color(0xFF0F4C5C),
              secondary: const Color(0xFF2F7F79),
              tertiary: const Color(0xFFF2B880),
              surface: const Color(0xFFFDFBF6),
              surfaceContainerHighest: const Color(0xFFF0F2F0),
              outline: const Color(0xFFC6D1D5),
              outlineVariant: const Color(0xFFE1E6E8),
            )
          : baseScheme.copyWith(
              primary: const Color(0xFF73D6C7),
              secondary: const Color(0xFF4DB2A1),
              tertiary: const Color(0xFFF2B880),
              surface: const Color(0xFF141A1D),
              surfaceContainerHighest: const Color(0xFF1F2528),
              outline: const Color(0xFF394246),
              outlineVariant: const Color(0xFF2B3438),
            );
      final baseTypography = isAndroid
          ? Typography.material2021(platform: TargetPlatform.android)
          : Typography.material2021(platform: defaultTargetPlatform);
      final baseTextTheme = isAndroid
          ? (brightness == Brightness.dark
              ? baseTypography.white
              : baseTypography.black)
          : null;
      final rawTextTheme = baseTextTheme == null
          ? GoogleFonts.notoSansScTextTheme()
          : GoogleFonts.notoSansScTextTheme(baseTextTheme);
      final textTheme = rawTextTheme.apply(
        bodyColor: colorScheme.onSurface,
        displayColor: colorScheme.onSurface,
      );
      final baseTheme = ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        typography: baseTypography,
        splashFactory: _isTest ? NoSplash.splashFactory : null,
        scaffoldBackgroundColor: colorScheme.surface,
        textTheme: textTheme,
      );
      if (isAndroid) {
        return baseTheme.copyWith(
          appBarTheme: AppBarTheme(
            backgroundColor: colorScheme.surface,
            surfaceTintColor: colorScheme.surfaceTint,
            elevation: 0,
            scrolledUnderElevation: 2,
            titleTextStyle: textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            iconTheme: IconThemeData(color: colorScheme.onSurface),
          ),
          cardTheme: CardThemeData(
            color: colorScheme.surface,
            elevation: 1,
            surfaceTintColor: colorScheme.surfaceTint,
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: colorScheme.surfaceContainerHighest,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: colorScheme.outlineVariant),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: colorScheme.outlineVariant),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: colorScheme.primary, width: 1.2),
            ),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 12,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              textStyle: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              textStyle: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          chipTheme: ChipThemeData(
            backgroundColor: colorScheme.surfaceContainerHighest,
            selectedColor: colorScheme.secondaryContainer,
            labelStyle: textTheme.labelLarge,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
              side: BorderSide(color: colorScheme.outlineVariant),
            ),
          ),
          floatingActionButtonTheme: FloatingActionButtonThemeData(
            backgroundColor: colorScheme.primaryContainer,
            foregroundColor: colorScheme.onPrimaryContainer,
            elevation: 1,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        );
      }
      return baseTheme.copyWith(
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
        cardTheme: CardThemeData(
          color: colorScheme.surface,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: colorScheme.surfaceContainerHighest,
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
          backgroundColor: colorScheme.surfaceContainerHighest,
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
          foregroundColor: colorScheme.onPrimary,
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
                  : colorScheme.surface,
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
      );
    }

    return MaterialApp(
      title: '密码管理器',
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        final width = mediaQuery.size.width;
        final baseScale = mediaQuery.textScaler.scale(1);
        final adaptiveScale = adaptiveTextScaleFor(width);
        final effectiveScale = baseScale * adaptiveScale;
        return MediaQuery(
          data: mediaQuery.copyWith(
            textScaler: TextScaler.linear(effectiveScale),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: VaultShell(controller: controller),
    );
  }
}

class VaultShell extends StatefulWidget {
  const VaultShell({super.key, required this.controller});

  final VaultController controller;

  @override
  State<VaultShell> createState() => _VaultShellState();
}

class _VaultShellState extends State<VaultShell> with WidgetsBindingObserver {
  String? _lastMetricsLog;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.controller.handleAppLifecycleStateChanged(state);
  }

  @override
  void didChangeMetrics() {
    if (!mounted) {
      return;
    }
    _logMetricsIfNeeded();
    setState(() {});
  }

  void _logMetricsIfNeeded() {
    if (!kDebugMode) {
      return;
    }
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) {
      return;
    }
    final view = views.first;
    final physicalSize = view.physicalSize;
    final devicePixelRatio = view.devicePixelRatio;
    final logicalWidth = physicalSize.width / devicePixelRatio;
    final logicalHeight = physicalSize.height / devicePixelRatio;
    final displayFeatures = MediaQueryData.fromView(view).displayFeatures;
    final signature = [
      logicalWidth.toStringAsFixed(1),
      logicalHeight.toStringAsFixed(1),
      devicePixelRatio.toStringAsFixed(2),
      displayFeatures.length,
    ].join('|');
    if (signature == _lastMetricsLog) {
      return;
    }
    _lastMetricsLog = signature;
    debugPrint(
      '[Adaptive][metrics] width=${logicalWidth.toStringAsFixed(1)} '
      'height=${logicalHeight.toStringAsFixed(1)} '
      'dpr=${devicePixelRatio.toStringAsFixed(2)} '
      'features=${displayFeatures.length}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        return widget.controller.isUnlocked
            ? HomeScreen(controller: widget.controller)
            : UnlockScreen(controller: widget.controller);
      },
    );
  }
}
