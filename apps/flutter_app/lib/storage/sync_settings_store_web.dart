import 'package:idb_shim/idb.dart';
import 'package:idb_shim/idb_browser.dart';

import '../state/sync_settings.dart';
import 'sync_settings_store.dart';

class WebSyncSettingsStore implements SyncSettingsStore {
  WebSyncSettingsStore({Database? database}) : _database = database;

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
  Future<SyncSettingsRecord?> read() async {
    final db = await _db();
    final txn = db.transaction('meta', idbModeReadOnly);
    final store = txn.objectStore('meta');
    final raw = await store.getObject('sync_settings');
    await txn.completed;
    if (raw is! Map) {
      return null;
    }
    final payload = raw['payload'];
    if (payload is! Map) {
      return null;
    }
    return SyncSettingsRecord.fromJson(Map<String, Object?>.from(payload));
  }

  @override
  Future<void> save(SyncSettingsRecord record) async {
    final db = await _db();
    final txn = db.transaction('meta', idbModeReadWrite);
    final store = txn.objectStore('meta');
    await store.put({
      'key': 'sync_settings',
      'payload': record.toJson(),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });
    await txn.completed;
  }
}

class FileSyncSettingsStore implements SyncSettingsStore {
  FileSyncSettingsStore({required this.filePath});

  final String filePath;

  @override
  Future<SyncSettingsRecord?> read() async {
    throw UnsupportedError('File sync settings store is not supported on web');
  }

  @override
  Future<void> save(SyncSettingsRecord record) async {
    throw UnsupportedError('File sync settings store is not supported on web');
  }
}
