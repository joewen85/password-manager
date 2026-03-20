import 'package:idb_shim/idb_browser.dart';
import 'package:password_manager_core/password_manager_core.dart';
import 'package:password_manager_storage/password_manager_storage.dart';

class WebStorageBundle {
  WebStorageBundle({required this.repository, required this.masterKeyStore});

  final VaultRepository repository;
  final MasterKeyStore masterKeyStore;
}

Future<WebStorageBundle> openWebStorage() async {
  final db = await _openDatabase();
  return WebStorageBundle(
    repository: WebVaultRepository(db: db),
    masterKeyStore: WebMasterKeyStore(db: db),
  );
}

Future<Database> _openDatabase() async {
  return idbFactoryBrowser.open(
    'password_manager',
    version: 1,
    onUpgradeNeeded: (event) {
      final db = event.database;
      if (!db.objectStoreNames.contains('vault_items')) {
        db.createObjectStore('vault_items', keyPath: 'id');
      }
      if (!db.objectStoreNames.contains('meta')) {
        db.createObjectStore('meta', keyPath: 'key');
      }
    },
  );
}

class WebVaultRepository implements VaultRepository {
  WebVaultRepository({required Database db}) : _db = db;

  final Database _db;

  @override
  Future<void> save(VaultItemRecord item) async {
    final txn = _db.transaction('vault_items', idbModeReadWrite);
    final store = txn.objectStore('vault_items');
    await store.put(vaultRecordToJson(item));
    await txn.completed;
  }

  @override
  Future<void> saveAll(List<VaultItemRecord> items) async {
    if (items.isEmpty) {
      return;
    }
    final txn = _db.transaction('vault_items', idbModeReadWrite);
    final store = txn.objectStore('vault_items');
    for (final item in items) {
      await store.put(vaultRecordToJson(item));
    }
    await txn.completed;
  }

  @override
  Future<VaultItemRecord?> getById(String id) async {
    final txn = _db.transaction('vault_items', idbModeReadOnly);
    final store = txn.objectStore('vault_items');
    final raw = await store.getObject(id);
    await txn.completed;
    if (raw is! Map) {
      return null;
    }
    return vaultRecordFromJson(Map<String, Object?>.from(raw));
  }

  @override
  Future<List<VaultItemRecord>> listAll() async {
    final txn = _db.transaction('vault_items', idbModeReadOnly);
    final store = txn.objectStore('vault_items');
    final rawList = await store.getAll();
    await txn.completed;
    return rawList
        .whereType<Map>()
        .map((entry) => vaultRecordFromJson(Map<String, Object?>.from(entry)))
        .toList();
  }

  @override
  Future<void> delete(String id) async {
    final txn = _db.transaction('vault_items', idbModeReadWrite);
    final store = txn.objectStore('vault_items');
    await store.delete(id);
    await txn.completed;
  }
}

class WebMasterKeyStore implements MasterKeyStore {
  WebMasterKeyStore({required Database db}) : _db = db;

  final Database _db;

  @override
  Future<MasterKeyRecord?> read() async {
    final txn = _db.transaction('meta', idbModeReadOnly);
    final store = txn.objectStore('meta');
    final raw = await store.getObject('master_key');
    await txn.completed;
    if (raw is! Map) {
      return null;
    }
    final payload = raw['payload'];
    if (payload is! Map) {
      return null;
    }
    return MasterKeyRecord.fromJson(Map<String, Object?>.from(payload));
  }

  @override
  Future<void> save(MasterKeyRecord record) async {
    final txn = _db.transaction('meta', idbModeReadWrite);
    final store = txn.objectStore('meta');
    final payload = {
      'key': 'master_key',
      'payload': record.toJson(),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
    await store.put(payload);
    await txn.completed;
  }
}
