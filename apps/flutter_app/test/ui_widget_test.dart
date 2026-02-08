import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager_auth/password_manager_auth.dart';
import 'package:password_manager_backup/password_manager_backup.dart';
import 'package:password_manager_core/password_manager_core.dart';
import 'package:password_manager_crypto/password_manager_crypto.dart';
import 'package:password_manager_sync/password_manager_sync.dart';

import 'package:password_manager_app/screens/home_screen.dart';
import 'package:password_manager_app/screens/unlock_screen.dart';
import 'package:password_manager_app/state/vault_controller.dart';

class InMemoryVaultRepository implements VaultRepository {
  final Map<String, VaultItem> _store = {};

  @override
  Future<void> delete(String id) async {
    _store.remove(id);
  }

  @override
  Future<VaultItem?> getById(String id) async => _store[id];

  @override
  Future<List<VaultItem>> listAll() async => _store.values.toList();

  @override
  Future<void> save(VaultItem item) async {
    _store[item.id] = item;
  }
}

VaultController buildController({required bool requireTotp}) {
  final vaultService = VaultService(
    cryptoService: AesGcmCryptoService(),
    keyDerivationService: KeyDerivationService(iterations: 1000),
    repository: InMemoryVaultRepository(),
  );
  return VaultController(
    vaultService: vaultService,
    syncProvider: NoopSyncProvider(),
    backupService: NoopBackupService(),
    totpService: const TotpService(),
    requireTotp: requireTotp,
    totpSecret: requireTotp ? 'JBSWY3DPEHPK3PXP' : null,
  );
}

void main() {
  Finder _fieldWithLabel(String label) {
    return find.byWidgetPredicate((widget) {
      return widget is TextFormField && widget.decoration?.labelText == label;
    });
  }

  testWidgets('Unlock screen shows master password field', (tester) async {
    final controller = buildController(requireTotp: false);
    await tester.pumpWidget(
      MaterialApp(home: UnlockScreen(controller: controller)),
    );

    expect(find.text('Unlock Vault'), findsOneWidget);
    expect(find.text('Master Password'), findsOneWidget);
    expect(find.text('Unlock'), findsOneWidget);
  });

  testWidgets('Unlock screen shows 2FA field when required', (tester) async {
    final controller = buildController(requireTotp: true);
    await tester.pumpWidget(
      MaterialApp(home: UnlockScreen(controller: controller)),
    );

    expect(find.text('2FA Code'), findsOneWidget);
  });

  testWidgets('Home screen shows empty state', (tester) async {
    final controller = buildController(requireTotp: false);
    await controller.unlock('master');

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );

    expect(find.textContaining('No entries yet'), findsOneWidget);
  });

  testWidgets('Add entry flow adds item to list', (tester) async {
    final controller = buildController(requireTotp: false);
    await controller.unlock('master');

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    await tester.enterText(_fieldWithLabel('Label'), 'AWS Console');
    await tester.enterText(_fieldWithLabel('Username'), 'user@example.com');
    await tester.enterText(_fieldWithLabel('Password'), 'secret-pass');
    await tester.enterText(_fieldWithLabel('Token'), 'token-123');
    await tester.enterText(_fieldWithLabel('App ID'), 'app-xyz');
    await tester.enterText(_fieldWithLabel('Access Token'), 'access-456');
    await tester.enterText(_fieldWithLabel('Secret Key'), 'sk-789');

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('AWS Console'), findsOneWidget);
  });

  testWidgets('Entry details dialog shows decrypted payload', (tester) async {
    final controller = buildController(requireTotp: false);
    await controller.unlock('master');

    await controller.addEntry(
      label: 'GitHub',
      payload: const CredentialPayload(
        username: 'octo',
        password: 'pass123',
        token: 'token',
        appId: 'appid',
        accessToken: 'access',
        secretKey: 'secret',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.visibility_outlined).first);
    await tester.pumpAndSettle();

    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('octo'), findsOneWidget);
    expect(find.text('pass123'), findsOneWidget);
  });
}
