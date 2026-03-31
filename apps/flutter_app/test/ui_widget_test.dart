import 'dart:convert';

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

Widget _wrapApp(Widget home) {
  return MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      splashFactory: NoSplash.splashFactory,
    ),
    home: home,
  );
}

void main() {
  Finder _fieldAt(int index) => find.byType(TextFormField).at(index);

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
        accessToken: '',
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

    await tester.enterText(_fieldAt(0), 'Prod Server');
    await tester.enterText(_fieldAt(1), '10.0.0.1');

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
        accessToken: 'access',
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
        accessToken: 'access',
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
        accessToken: '',
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
      "accessToken": "acc",
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
        "accessToken": "",
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
        accessToken: '',
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
      "accessToken": "",
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
      "accessToken": "",
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
        accessToken: '',
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
      "accessToken": "",
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
