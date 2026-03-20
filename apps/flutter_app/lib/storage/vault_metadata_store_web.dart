import 'package:idb_shim/idb_browser.dart';

import '../state/vault_metadata.dart';
import 'vault_metadata_store.dart';

class WebVaultMetadataStore implements VaultMetadataStore {
  WebVaultMetadataStore({Database? database}) : _database = database;

  Database? _database;

  Future<Database> _db() async {
    if (_database != null) {
      return _database!;
    }
    _database = await idbFactoryBrowser.open(
      'password_manager',
      version: 1,
      onUpgradeNeeded: (event) {
        final db = event.database;
        if (!db.objectStoreNames.contains('meta')) {
          db.createObjectStore('meta', keyPath: 'key');
        }
      },
    );
    return _database!;
  }

  @override
  Future<VaultMetadataRecord?> read() async {
    final db = await _db();
    final txn = db.transaction('meta', idbModeReadOnly);
    final store = txn.objectStore('meta');
    final raw = await store.getObject('vault_metadata');
    await txn.completed;
    if (raw is! Map) {
      return null;
    }
    final payload = raw['payload'];
    if (payload is! Map) {
      return null;
    }
    return VaultMetadataRecord.fromJson(Map<String, Object?>.from(payload));
  }

  @override
  Future<void> save(VaultMetadataRecord record) async {
    final db = await _db();
    final txn = db.transaction('meta', idbModeReadWrite);
    final store = txn.objectStore('meta');
    await store.put({
      'key': 'vault_metadata',
      'payload': record.toJson(),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });
    await txn.completed;
  }
}

class FileVaultMetadataStore implements VaultMetadataStore {
  FileVaultMetadataStore({required this.filePath});

  final String filePath;

  @override
  Future<VaultMetadataRecord?> read() async {
    throw UnsupportedError('File vault metadata store is not supported on web');
  }

  @override
  Future<void> save(VaultMetadataRecord record) async {
    throw UnsupportedError('File vault metadata store is not supported on web');
  }
}
