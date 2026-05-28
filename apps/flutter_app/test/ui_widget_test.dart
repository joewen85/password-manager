import 'dart:convert';
import 'dart:typed_data';

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
import 'package:password_manager_app/widgets/entry_details_dialog.dart';

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
  final keyDerivationService =
      KeyDerivationService.insecureForTesting(iterations: 1000);
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

Widget _wrapApp(Widget home) {
  return MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      splashFactory: NoSplash.splashFactory,
    ),
    home: home,
  );
}

Future<void> _selectCompactFilter(
  WidgetTester tester, {
  required String tooltip,
  required String value,
}) async {
  await tester.tap(find.byTooltip(tooltip));
  await tester.pumpAndSettle();
  await tester.tap(find.text(value).last);
  await tester.pumpAndSettle();
}

Future<void> _searchAndroid(WidgetTester tester, String query) async {
  await tester.tap(find.byType(TextField));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).last, query);
  await tester.tap(find.text('完成'));
  await tester.pumpAndSettle();
}

void main() {
  Finder fieldAt(int index) => find.byType(TextFormField).at(index);

  testWidgets('Unlock screen shows master password field', (tester) async {
    final controller = buildController(requireTotp: false);
    await tester.pumpWidget(
      _wrapApp(UnlockScreen(controller: controller)),
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
      _wrapApp(UnlockScreen(controller: controller)),
    );

    expect(find.text('2FA 验证码'), findsOneWidget);
  });

  testWidgets('Home screen shows empty state', (tester) async {
    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');

    await tester.pumpWidget(
      _wrapApp(HomeScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('暂无条目'), findsOneWidget);
  });

  testWidgets('Compact layout keeps entries visible on short windows',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1088);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');
    await controller.addEntry(
      label: 'Alpha Dev',
      payload: const CredentialPayload(
        username: 'dev-user',
        password: 'pass123',
        token: '',
        appId: '',
        accessKey: '',
        secretKey: '',
        notes: '',
        tags: ['dev'],
        category: '研发',
      ),
    );

    await tester.pumpWidget(
      _wrapApp(HomeScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text('安全地保存账号信息'), findsNothing);
    expect(find.text('AES-256 · 多端同步'), findsNothing);
    expect(find.byTooltip('分类'), findsOneWidget);
    expect(find.byTooltip('标签'), findsOneWidget);
    expect(find.text('Alpha Dev'), findsOneWidget);

    await _searchAndroid(tester, 'Alpha');

    expect(find.text('Alpha Dev'), findsOneWidget);
    expect(find.text('结果: 1'), findsNothing);
  });

  testWidgets('Compact layout category picker still filters entries',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1088);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');
    await controller.addEntry(
      label: 'Alpha Dev',
      payload: const CredentialPayload(
        username: 'dev-user',
        password: 'pass123',
        token: '',
        appId: '',
        accessKey: '',
        secretKey: '',
        notes: '',
        tags: ['dev'],
        category: '研发',
      ),
    );
    await controller.addEntry(
      label: 'Alpha Ops',
      payload: const CredentialPayload(
        username: 'ops-user',
        password: 'pass456',
        token: '',
        appId: '',
        accessKey: '',
        secretKey: '',
        notes: '',
        tags: ['ops'],
        category: '运维',
      ),
    );

    await tester.pumpWidget(
      _wrapApp(HomeScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    await _searchAndroid(tester, 'Alpha');
    expect(find.text('Alpha Dev'), findsOneWidget);
    expect(find.text('Alpha Ops'), findsOneWidget);

    await tester.tap(find.byTooltip('分类'));
    await tester.pumpAndSettle();

    expect(find.text('全部分类'), findsWidgets);

    await tester.tap(find.text('研发').last);
    await tester.pumpAndSettle();

    expect(find.text('Alpha Dev'), findsOneWidget);
    expect(find.text('Alpha Ops'), findsNothing);
    expect(find.text('结果: 1'), findsNothing);
  });

  test('Unlock loads category and tags without requiring sync', () async {
    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');
    await controller.addEntry(
      label: 'GitHub',
      payload: const CredentialPayload(
        username: 'octo',
        password: 'pass123',
        token: '',
        appId: '',
        accessKey: '',
        secretKey: '',
        notes: '',
        tags: ['dev'],
        category: ' 研发 ',
      ),
    );
    await controller.lock();

    final unlocked = await controller.unlock('master');

    expect(unlocked, isTrue);
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline) &&
        (controller.entryViews.isEmpty ||
            controller.entryViews.single.category != '研发' ||
            !controller.entryViews.single.tags.contains('dev'))) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(controller.entryViews, isNotEmpty);
    expect(controller.entryViews.single.category, '研发');
    expect(controller.entryViews.single.tags, contains('dev'));
    expect(controller.metadata.categories, contains('研发'));
    expect(controller.metadata.tags, contains('dev'));
  });

  test('Lock clears decrypted entry views', () async {
    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');
    await controller.addEntry(
      label: 'GitHub',
      payload: const CredentialPayload(
        username: 'octo',
        password: 'pass123',
        token: '',
        appId: '',
        accessKey: '',
        secretKey: '',
        notes: '',
        tags: ['dev'],
        category: '研发',
      ),
    );

    expect(controller.entryViews, isNotEmpty);
    expect(controller.entryViews.single.credential?.password, 'pass123');
    final versionBeforeLock = controller.entryViewsVersion;

    await controller.lock();

    expect(controller.entryViews, isEmpty);
    expect(controller.entryViewsVersion, greaterThan(versionBeforeLock));
  });

  test('Merge re-encrypts remote metadata before local apply', () async {
    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');
    await controller.updateSyncSettings(
      controller.syncSettings.copyWith(syncMasterKey: false),
    );

    final cryptoService = AesGcmCryptoService();
    final keyDerivationService =
        KeyDerivationService.insecureForTesting(iterations: 1000);

    Future<VaultItemRecord> buildRecord({
      required String label,
      required String username,
      required Map<String, int> version,
      required String updatedBy,
      Uint8List? metadataKey,
    }) async {
      final repository = InMemoryVaultRepository();
      final service = VaultService(
        cryptoService: cryptoService,
        keyDerivationService: keyDerivationService,
        repository: repository,
      );
      service.setSessionMetadataKey(
        metadataKey,
        allowEncryption: metadataKey != null,
      );
      final item = await service.addCredential(
        CredentialPayload(
          username: username,
          password: '$username-pass',
          token: '',
          appId: '',
          accessKey: '',
          secretKey: '',
          notes: '',
          tags: const ['sync'],
          category: '测试',
        ),
        label: label,
        masterPassword: 'master',
        nonce: Uint8List.fromList(List<int>.generate(12, (i) => i + 1)),
        version: version,
        updatedBy: updatedBy,
      );
      final record = await repository.getById(item.id);
      return VaultItemRecord(
        id: 'shared-entry',
        encryptedPayload: record!.encryptedPayload,
        encryptedMetadata: record.encryptedMetadata,
        kdfSalt: record.kdfSalt,
        kdfIterations: record.kdfIterations,
      );
    }

    String payloadFor({
      required int revision,
      required String deviceId,
      required VaultItemRecord record,
      VaultMetadataRecord? metadataRecord,
    }) {
      return jsonEncode({
        'version': 2,
        'exportedAt': DateTime.utc(2026).toIso8601String(),
        'deviceId': deviceId,
        'revision': revision,
        'masterKey': null,
        'metadataRecord': metadataRecord?.toJson(),
        'items': [vaultRecordToJson(record)],
      });
    }

    final remoteMetadataKey = await keyDerivationService.deriveKey(
      'master',
      salt: Uint8List.fromList(List<int>.generate(16, (i) => i + 40)),
      iterations: 1000,
    );
    final remoteMetadataPayload = await cryptoService.encrypt(
      Uint8List.fromList(
        utf8.encode(jsonEncode(VaultMetadata.defaults().toJson())),
      ),
      remoteMetadataKey.bytes,
      nonce: Uint8List.fromList(List<int>.generate(12, (i) => i + 90)),
    );
    final remoteMetadataRecord = VaultMetadataRecord(
      encryptedPayload: remoteMetadataPayload,
      kdfSalt: remoteMetadataKey.salt,
      kdfIterations: remoteMetadataKey.iterations,
    );

    final localRecord = await buildRecord(
      label: 'Local',
      username: 'local-user',
      version: const {'local': 1},
      updatedBy: 'local',
    );
    final remoteRecord = await buildRecord(
      label: 'Remote',
      username: 'remote-user',
      version: const {'local': 1, 'remote': 1},
      updatedBy: 'remote',
      metadataKey: remoteMetadataKey.bytes,
    );

    final mergedPayload = await controller.mergeSyncPayloadForTest(
      localPayload: payloadFor(
        revision: 1,
        deviceId: 'local',
        record: localRecord,
      ),
      remotePayload: payloadFor(
        revision: 2,
        deviceId: 'remote',
        record: remoteRecord,
        metadataRecord: remoteMetadataRecord,
      ),
    );

    final decoded = jsonDecode(mergedPayload) as Map;
    final mergedRecord = vaultRecordFromJson(
      Map<String, Object?>.from((decoded['items'] as List).single as Map),
    );
    final verifier = VaultService(
      cryptoService: cryptoService,
      keyDerivationService: keyDerivationService,
      repository: InMemoryVaultRepository(),
    );

    final mergedItem = await verifier.decryptRecord(
      mergedRecord,
      masterPassword: 'master',
    );
    final mergedCredential = await verifier.readCredential(
      mergedItem,
      masterPassword: 'master',
    );

    expect(mergedItem.label, 'Remote');
    expect(mergedCredential?.username, 'remote-user');
  });

  testWidgets('Add entry flow adds item to list', (tester) async {
    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');

    await tester.pumpWidget(
      _wrapApp(HomeScreen(controller: controller)),
    );

    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建账号'));
    await tester.pumpAndSettle();

    await tester.enterText(fieldAt(0), 'AWS Console');
    await tester.enterText(fieldAt(1), 'user@example.com');
    await tester.enterText(fieldAt(2), 'secret-pass');
    await tester.enterText(fieldAt(3), 'token-123');
    await tester.enterText(fieldAt(4), 'app-xyz');
    await tester.enterText(fieldAt(5), 'access-456');
    await tester.enterText(fieldAt(6), 'sk-789');

    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('AWS Console'), findsOneWidget);
  });

  testWidgets('Add server flow defaults category and supports linked account',
      (tester) async {
    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');
    final account = await controller.addEntry(
      label: 'Root Account',
      payload: const CredentialPayload(
        username: 'root',
        password: 'secret',
        token: '',
        appId: '',
        accessKey: '',
        secretKey: '',
        notes: '',
        tags: [],
      ),
    );

    await tester.pumpWidget(
      _wrapApp(HomeScreen(controller: controller)),
    );

    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建服务器'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('不关联账号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Root Account').last);
    await tester.pumpAndSettle();

    await tester.enterText(fieldAt(0), 'Prod Server');
    await tester.enterText(fieldAt(1), '10.0.0.1');

    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final serverItem = controller.items.singleWhere(
      (item) =>
          item.type == VaultEntryType.server && item.label == 'Prod Server',
    );
    final payload = await controller.readServerAsset(serverItem);

    expect(payload, isNotNull);
    expect(payload!.category, '服务器');
    expect(payload.accountId, account.id);
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
        accessKey: 'access',
        secretKey: 'secret',
        notes: 'note',
        tags: ['dev'],
      ),
    );

    await tester.pumpWidget(
      _wrapApp(HomeScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('GitHub').first);
    await tester.pumpAndSettle();

    expect(find.text('GitHub'), findsWidgets);
    expect(find.text('用户名: octo'), findsOneWidget);
    expect(find.text('密码: pass123'), findsOneWidget);
  });

  testWidgets('Category filter remains responsive after search',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');
    await controller.addEntry(
      label: 'Alpha Dev',
      payload: const CredentialPayload(
        username: 'dev-user',
        password: 'pass123',
        token: '',
        appId: '',
        accessKey: '',
        secretKey: '',
        notes: '',
        tags: ['dev'],
        category: '研发',
      ),
    );
    await controller.addEntry(
      label: 'Alpha Ops',
      payload: const CredentialPayload(
        username: 'ops-user',
        password: 'pass456',
        token: '',
        appId: '',
        accessKey: '',
        secretKey: '',
        notes: '',
        tags: ['ops'],
        category: '运维',
      ),
    );

    await tester.pumpWidget(_wrapApp(HomeScreen(controller: controller)));
    await tester.pumpAndSettle();

    await _searchAndroid(tester, 'Alpha');

    expect(find.text('结果: 2'), findsOneWidget);

    await _selectCompactFilter(tester, tooltip: '分类', value: '研发');

    expect(find.text('分类: 研发'), findsWidgets);
    expect(find.text('结果: 1'), findsOneWidget);

    await _selectCompactFilter(tester, tooltip: '分类', value: '运维');

    expect(find.text('分类: 运维'), findsWidgets);
    expect(find.text('结果: 1'), findsOneWidget);
  });

  testWidgets('Android medium freeform uses stable collapsed filters',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1800);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');
    await controller.addEntry(
      label: 'Alpha Dev',
      payload: const CredentialPayload(
        username: 'dev-user',
        password: 'pass123',
        token: '',
        appId: '',
        accessKey: '',
        secretKey: '',
        notes: '',
        tags: ['dev'],
        category: '研发',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.android,
          useMaterial3: true,
          splashFactory: NoSplash.splashFactory,
        ),
        home: HomeScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('分类'), findsOneWidget);
    expect(find.byTooltip('标签'), findsOneWidget);
    expect(find.text('全部分类'), findsNothing);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.text('搜索'), findsWidgets);
    await tester.enterText(find.byType(TextField).last, 'Alpha');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    await tester.pumpAndSettle();

    expect(find.byTooltip('分类'), findsOneWidget);
    expect(find.byTooltip('标签'), findsOneWidget);
    expect(find.text('全部分类'), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('Android entry details releases search keyboard', (tester) async {
    tester.view.physicalSize = const Size(1600, 1800);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');
    await controller.addEntry(
      label: 'Alpha Dev',
      payload: const CredentialPayload(
        username: 'dev-user',
        password: 'pass123',
        token: '',
        appId: '',
        accessKey: '',
        secretKey: '',
        notes: '',
        tags: ['dev'],
        category: '研发',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.android,
          useMaterial3: true,
          splashFactory: NoSplash.splashFactory,
        ),
        home: HomeScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Alpha');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(find.text('Alpha Dev'), findsOneWidget);
    await tester.tap(find.text('Alpha Dev'));
    await tester.pumpAndSettle();

    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('Android search opens dedicated search page', (tester) async {
    tester.view.physicalSize = const Size(1800, 1800);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');
    await controller.addEntry(
      label: 'Alpha Dev',
      payload: const CredentialPayload(
        username: 'dev-user',
        password: 'pass123',
        token: '',
        appId: '',
        accessKey: '',
        secretKey: '',
        notes: '',
        tags: ['dev'],
        category: '研发',
      ),
    );

    await tester.pumpWidget(_wrapApp(HomeScreen(controller: controller)));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    expect(find.text('搜索'), findsWidgets);
    expect(find.text('Search 用法'), findsNothing);
    await tester.tap(find.byTooltip('搜索用法').last);
    await tester.pumpAndSettle();
    expect(find.text('Search 用法'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField).last);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.enterText(find.byType(TextField).last, 'Alpha');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(find.text('搜索'), findsNothing);
    expect(find.text('结果: 1'), findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('Android keyboard preserves compact filter layout',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1088);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');
    await controller.addEntry(
      label: 'Alpha Dev',
      payload: const CredentialPayload(
        username: 'dev-user',
        password: 'pass123',
        token: '',
        appId: '',
        accessKey: '',
        secretKey: '',
        notes: '',
        tags: ['dev'],
        category: '研发',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.android,
          useMaterial3: true,
          splashFactory: NoSplash.splashFactory,
        ),
        home: HomeScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('分类'), findsOneWidget);
    expect(find.byTooltip('标签'), findsOneWidget);

    await _searchAndroid(tester, 'Alpha');
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    await tester.pumpAndSettle();

    expect(find.byTooltip('分类'), findsOneWidget);
    expect(find.byTooltip('标签'), findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('Expanded tag filters collapse after three tags', (tester) async {
    tester.view.physicalSize = const Size(2000, 1800);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');
    for (final tag in ['dev', 'ops', 'prod', 'qa', 'stage']) {
      await controller.addTag(tag);
    }

    await tester.pumpWidget(_wrapApp(HomeScreen(controller: controller)));
    await tester.pumpAndSettle();

    expect(find.text('dev'), findsOneWidget);
    expect(find.text('ops'), findsOneWidget);
    expect(find.text('prod'), findsOneWidget);
    expect(find.text('qa'), findsNothing);
    expect(find.text('stage'), findsNothing);
    expect(find.text('...+2'), findsOneWidget);

    await tester.tap(find.text('...+2'));
    await tester.pumpAndSettle();

    expect(find.text('全部标签'), findsOneWidget);
    expect(find.text('qa'), findsOneWidget);
    expect(find.text('stage'), findsOneWidget);
  });

  testWidgets('Tag filter remains responsive after search', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');
    await controller.addEntry(
      label: 'Alpha Dev',
      payload: const CredentialPayload(
        username: 'dev-user',
        password: 'pass123',
        token: '',
        appId: '',
        accessKey: '',
        secretKey: '',
        notes: '',
        tags: ['dev'],
        category: '研发',
      ),
    );
    await controller.addEntry(
      label: 'Alpha Ops',
      payload: const CredentialPayload(
        username: 'ops-user',
        password: 'pass456',
        token: '',
        appId: '',
        accessKey: '',
        secretKey: '',
        notes: '',
        tags: ['ops'],
        category: '运维',
      ),
    );

    await tester.pumpWidget(_wrapApp(HomeScreen(controller: controller)));
    await tester.pumpAndSettle();

    await _searchAndroid(tester, 'Alpha');

    await _selectCompactFilter(tester, tooltip: '标签', value: 'dev');

    expect(find.text('标签: dev'), findsWidgets);
    expect(find.text('结果: 1'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);

    await _selectCompactFilter(tester, tooltip: '标签', value: 'ops');

    expect(find.text('标签: ops'), findsWidgets);
    expect(find.text('结果: 1'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('Service details show multiple accounts as separated blocks',
      (tester) async {
    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');

    final service = await controller.addService(
      label: 'Ops Service',
      payload: const ServicePayload(
        name: 'Ops Service',
        connectionAddress: 'ops.example.com',
        connectionPort: '443',
        accountId: null,
        serverIds: [],
        accounts: [
          ServiceAccount(
            username: 'alice',
            password: 'alice-pass',
            note: 'admin',
          ),
          ServiceAccount(
            username: 'bob',
            password: 'bob-pass',
            note: 'readonly',
          ),
        ],
        notes: '',
        tags: ['ops'],
        category: '服务',
      ),
    );

    await tester.pumpWidget(
      _wrapApp(
        Scaffold(
          body: EntryDetailsContent(
            controller: controller,
            item: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('服务账号列表'), findsOneWidget);
    expect(find.textContaining('账号1: alice'), findsOneWidget);
    expect(find.textContaining('密码: alice-pass'), findsOneWidget);
    expect(find.textContaining('备注: admin'), findsOneWidget);
    expect(find.textContaining('---'), findsOneWidget);
    expect(find.textContaining('账号2: bob'), findsOneWidget);
    expect(find.textContaining('密码: bob-pass'), findsOneWidget);
    expect(find.textContaining('备注: readonly'), findsOneWidget);
  });

  test('Exports single item as json', () async {
    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');

    final item = await controller.addEntry(
      label: 'GitHub',
      payload: const CredentialPayload(
        username: 'octo',
        password: 'pass123',
        token: 'token',
        appId: 'appid',
        accessKey: 'access',
        secretKey: 'secret',
        notes: 'note',
        tags: ['dev'],
        category: '开发',
      ),
    );

    final exported = await controller.exportItemData(item);
    final decoded = jsonDecode(exported) as Map<String, Object?>;
    final exportedItem = decoded['item'] as Map<String, Object?>;
    final payload = exportedItem['payload'] as Map<String, Object?>;

    expect(decoded['scope'], 'item');
    expect(exportedItem['label'], 'GitHub');
    expect(exportedItem['type'], 'credential');
    expect(exportedItem['category'], '开发');
    expect(payload['username'], 'octo');
    expect(payload['category'], '开发');
  });

  test('Exports category as json', () async {
    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');

    await controller.addEntry(
      label: 'AWS',
      payload: const CredentialPayload(
        username: 'aws-user',
        password: 'aws-pass',
        token: '',
        appId: 'aws-app',
        accessKey: '',
        secretKey: '',
        notes: '',
        tags: ['cloud'],
        category: '云平台',
      ),
    );
    await controller.addServerAsset(
      label: 'Prod Server',
      payload: const ServerAssetPayload(
        name: 'prod-01',
        ipAddress: '10.0.0.1',
        port: '22',
        username: 'root',
        password: 'server-pass',
        basicConfig: '',
        operatingSystem: 'Linux',
        location: 'cn',
        notes: '',
        tags: ['prod'],
        category: '基础设施',
      ),
    );
    await controller.addService(
      label: 'Cloud Console',
      payload: const ServicePayload(
        name: 'Cloud Console',
        connectionAddress: 'console.example.com',
        connectionPort: '443',
        accountId: null,
        serverIds: [],
        accounts: [],
        notes: '',
        tags: ['cloud'],
        category: '云平台',
      ),
    );

    final exported = await controller.exportCategoryData('云平台');
    final decoded = jsonDecode(exported) as Map<String, Object?>;
    final items = (decoded['items'] as List).cast<Map<String, Object?>>();

    expect(decoded['scope'], 'category');
    expect(decoded['category'], '云平台');
    expect(decoded['count'], 2);
    expect(items.map((entry) => entry['label']), ['AWS', 'Cloud Console']);
  });

  test('Imports single item json', () async {
    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');

    const json = '''
{
  "version": 1,
  "scope": "item",
  "exportedAt": "2026-03-30T12:00:00.000Z",
  "item": {
    "id": "source-credential-1",
    "label": "GitLab",
    "type": "credential",
    "category": "研发",
    "payload": {
      "username": "alice",
      "password": "pwd-123",
      "token": "totp",
      "appId": "gitlab-app",
      "accessKey": "acc",
      "secretKey": "sec",
      "notes": "hello",
      "tags": ["dev"],
      "category": "研发"
    }
  }
}
''';

    final result = await controller.importItemData(json);
    final items = controller.items.where((entry) => !entry.isDeleted).toList();
    final payload = await controller.readEntry(items.single);

    expect(result.createdCount, 1);
    expect(items.single.label, 'GitLab');
    expect(payload?.username, 'alice');
    expect(payload?.category, '研发');
  });

  test('Imports category json and remaps service references', () async {
    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');

    const json = '''
{
  "version": 1,
  "scope": "category",
  "exportedAt": "2026-03-30T12:00:00.000Z",
  "category": "云平台",
  "count": 3,
  "items": [
    {
      "id": "cred-1",
      "label": "AWS Account",
      "type": "credential",
      "category": "云平台",
      "payload": {
        "username": "root",
        "password": "pwd",
        "token": "",
        "appId": "aws",
        "accessKey": "",
        "secretKey": "",
        "notes": "",
        "tags": ["cloud"],
        "category": "云平台"
      }
    },
    {
      "id": "srv-1",
      "label": "Bastion",
      "type": "server",
      "category": "云平台",
      "payload": {
        "name": "bastion",
        "ipAddress": "10.0.0.8",
        "port": "22",
        "username": "root",
        "password": "pwd",
        "basicConfig": "",
        "operatingSystem": "Linux",
        "location": "cn",
        "notes": "",
        "tags": ["cloud"],
        "category": "云平台"
      }
    },
    {
      "id": "svc-1",
      "label": "AWS Console",
      "type": "service",
      "category": "云平台",
      "payload": {
        "name": "AWS Console",
        "connectionAddress": "console.aws.amazon.com",
        "connectionPort": "443",
        "accountId": "cred-1",
        "serverIds": ["srv-1"],
        "accounts": [],
        "notes": "",
        "tags": ["cloud"],
        "category": "云平台"
      }
    }
  ]
}
''';

    final result = await controller.importCategoryData(json);
    final items = controller.items.where((entry) => !entry.isDeleted).toList();
    final account = items.firstWhere((entry) => entry.label == 'AWS Account');
    final server = items.firstWhere((entry) => entry.label == 'Bastion');
    final service = items.firstWhere((entry) => entry.label == 'AWS Console');
    final servicePayload = await controller.readService(service);

    expect(result.createdCount, 3);
    expect(servicePayload?.accountId, account.id);
    expect(servicePayload?.serverIds, [server.id]);
    expect(servicePayload?.category, '云平台');
  });

  test('Preview import marks exact duplicates and conflicts', () async {
    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');

    await controller.addEntry(
      label: 'GitHub',
      payload: const CredentialPayload(
        username: 'same-user',
        password: 'same-pass',
        token: '',
        appId: '',
        accessKey: '',
        secretKey: '',
        notes: '',
        tags: ['dev'],
        category: '研发',
      ),
    );

    final exactPreview = await controller.previewItemImport('''
{
  "scope": "item",
  "item": {
    "id": "a1",
    "label": "GitHub",
    "type": "credential",
    "payload": {
      "username": "same-user",
      "password": "same-pass",
      "token": "",
      "appId": "",
      "accessKey": "",
      "secretKey": "",
      "notes": "",
      "tags": ["dev"],
      "category": "研发"
    }
  }
}
''');
    final conflictPreview = await controller.previewItemImport('''
{
  "scope": "item",
  "item": {
    "id": "a2",
    "label": "GitHub",
    "type": "credential",
    "payload": {
      "username": "other-user",
      "password": "other-pass",
      "token": "",
      "appId": "",
      "accessKey": "",
      "secretKey": "",
      "notes": "",
      "tags": ["dev"],
      "category": "研发"
    }
  }
}
''');

    expect(exactPreview.exactDuplicateCount, 1);
    expect(conflictPreview.conflictCount, 1);
  });

  test('Import conflict can skip or overwrite', () async {
    final controller = buildController(requireTotp: false);
    await controller.setupMasterPassword('master', 'master');

    final item = await controller.addEntry(
      label: 'GitHub',
      payload: const CredentialPayload(
        username: 'old-user',
        password: 'old-pass',
        token: '',
        appId: '',
        accessKey: '',
        secretKey: '',
        notes: '',
        tags: ['dev'],
        category: '研发',
      ),
    );

    const json = '''
{
  "scope": "item",
  "item": {
    "id": "a3",
    "label": "GitHub",
    "type": "credential",
    "payload": {
      "username": "new-user",
      "password": "new-pass",
      "token": "",
      "appId": "",
      "accessKey": "",
      "secretKey": "",
      "notes": "",
      "tags": ["ops"],
      "category": "研发"
    }
  }
}
''';

    final skipped = await controller.importItemData(
      json,
      strategy: ImportConflictStrategy.skip,
    );
    final skippedPayload = await controller.readEntry(item);
    expect(skipped.skippedCount, 1);
    expect(skippedPayload?.username, 'old-user');

    final overwritten = await controller.importItemData(
      json,
      strategy: ImportConflictStrategy.overwrite,
    );
    final updatedItem =
        controller.items.firstWhere((entry) => entry.id == item.id);
    final overwrittenPayload = await controller.readEntry(updatedItem);
    expect(overwritten.updatedCount, 1);
    expect(overwrittenPayload?.username, 'new-user');
    expect(overwrittenPayload?.tags, ['ops']);
  });
}
