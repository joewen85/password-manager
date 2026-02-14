import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager_auth/password_manager_auth.dart';
import 'package:password_manager_backup/password_manager_backup.dart';
import 'package:password_manager_core/password_manager_core.dart';
import 'package:password_manager_crypto/password_manager_crypto.dart';
import 'package:password_manager_storage/password_manager_storage.dart';

import 'package:password_manager_app/screens/home_screen.dart';
import 'package:password_manager_app/screens/unlock_screen.dart';
import 'package:password_manager_app/state/sync_settings.dart';
import 'package:password_manager_app/state/vault_controller.dart';
import 'package:password_manager_app/state/vault_metadata.dart';
import 'package:password_manager_app/storage/sync_settings_store.dart';
import 'package:password_manager_app/storage/vault_metadata_store.dart';

class InMemoryVaultRepository implements VaultRepository {
  final Map<String, VaultItemRecord> _store = {};

  @override
  Future<void> delete(String id) async {
    _store.remove(id);
  }

  @override
  Future<VaultItemRecord?> getById(String id) async => _store[id];

  @override
  Future<List<VaultItemRecord>> listAll() async => _store.values.toList();

  @override
  Future<void> save(VaultItemRecord item) async {
    _store[item.id] = item;
  }

  @override
  Future<void> saveAll(List<VaultItemRecord> items) async {
    for (final item in items) {
      _store[item.id] = item;
    }
  }
}

class InMemorySyncSettingsStore implements SyncSettingsStore {
  SyncSettingsRecord? _record;

  @override
  Future<SyncSettingsRecord?> read() async => _record;

  @override
  Future<void> save(SyncSettingsRecord record) async {
    _record = record;
  }
}

class InMemoryVaultMetadataStore implements VaultMetadataStore {
  VaultMetadataRecord? _record;

  @override
  Future<VaultMetadataRecord?> read() async => _record;

  @override
  Future<void> save(VaultMetadataRecord record) async {
    _record = record;
  }
}

VaultController buildController({required bool requireTotp}) {
  final keyDerivationService = KeyDerivationService(iterations: 1000);
  final cryptoService = AesGcmCryptoService();
  final masterKeyStore = InMemoryMasterKeyStore();
  final syncSettingsStore = InMemorySyncSettingsStore();
  final metadataStore = InMemoryVaultMetadataStore();
  final vaultService = VaultService(
    cryptoService: cryptoService,
    keyDerivationService: keyDerivationService,
    repository: InMemoryVaultRepository(),
  );
  return VaultController(
    vaultService: vaultService,
    backupService: NoopBackupService(),
    cryptoService: cryptoService,
    totpService: const TotpService(),
    keyDerivationService: keyDerivationService,
    masterKeyStore: masterKeyStore,
    syncSettingsStore: syncSettingsStore,
    initialSyncSettings: SyncSettings.defaults(),
    vaultMetadataStore: metadataStore,
    initialMetadata: VaultMetadata.defaults(),
    requireTotp: requireTotp,
    totpSecret: requireTotp ? 'JBSWY3DPEHPK3PXP' : null,
  );
}

void main() {
  Finder _fieldAt(int index) => find.byType(TextFormField).at(index);

  testWidgets('Unlock screen shows master password field', (tester) async {
    final controller = buildController(requireTotp: false);
    await tester.pumpWidget(
      MaterialApp(home: UnlockScreen(controller: controller)),
    );

    expect(find.text('初始化密码库'), findsOneWidget);
    expect(find.text('主密码'), findsOneWidget);
    expect(find.text('初始化'), findsOneWidget);
    expect(find.text('确认主密码'), findsOneWidget);
  });

  testWidgets('Unlock screen shows 2FA field when required', (tester) async {
    final controller = buildController(requireTotp: true);
    await controller.setupMasterPassword('master', 'master');
    await controller.lock();
    await tester.pumpWidget(
      MaterialApp(home: UnlockScreen(controller: controller)),
    );

    expect(find.text('2FA 验证码'), findsOneWidget);
  });

  testWidgets('Home screen shows empty state', (tester) async {
    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('暂无条目'), findsOneWidget);
  });

  testWidgets('Add entry flow adds item to list', (tester) async {
    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );

    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();

    await tester.enterText(_fieldAt(0), 'AWS Console');
    await tester.enterText(_fieldAt(1), 'user@example.com');
    await tester.enterText(_fieldAt(2), 'secret-pass');
    await tester.enterText(_fieldAt(3), 'token-123');
    await tester.enterText(_fieldAt(4), 'app-xyz');
    await tester.enterText(_fieldAt(5), 'access-456');
    await tester.enterText(_fieldAt(6), 'sk-789');

    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('AWS Console'), findsOneWidget);
  });

  testWidgets('Entry details dialog shows decrypted payload', (tester) async {
    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');

    await controller.addEntry(
      label: 'GitHub',
      payload: const CredentialPayload(
        username: 'octo',
        password: 'pass123',
        token: 'token',
        appId: 'appid',
        accessToken: 'access',
        secretKey: 'secret',
        tags: ['dev'],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('GitHub').first);
    await tester.pumpAndSettle();

    expect(find.text('GitHub'), findsWidgets);
    expect(find.text('octo'), findsOneWidget);
    expect(find.text('pass123'), findsOneWidget);
  });
}
