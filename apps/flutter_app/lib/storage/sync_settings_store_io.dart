import 'dart:convert';
import 'dart:io';

import '../state/sync_settings.dart';
import 'sync_settings_store.dart';

class FileSyncSettingsStore implements SyncSettingsStore {
  FileSyncSettingsStore({required this.filePath});

  final String filePath;

  @override
  Future<SyncSettingsRecord?> read() async {
    final file = File(filePath);
    if (!await file.exists()) {
      return null;
    }
    final contents = await file.readAsString();
    if (contents.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(contents);
    if (decoded is! Map) {
      return null;
    }
    return SyncSettingsRecord.fromJson(Map<String, Object?>.from(decoded));
  }

  @override
  Future<void> save(SyncSettingsRecord record) async {
    final file = File(filePath);
    await file.create(recursive: true);
    await file.writeAsString(jsonEncode(record.toJson()));
  }
}

class WebSyncSettingsStore implements SyncSettingsStore {
  @override
  Future<SyncSettingsRecord?> read() async {
    throw UnsupportedError('Web sync settings store is not supported on IO');
  }

  @override
  Future<void> save(SyncSettingsRecord record) async {
    throw UnsupportedError('Web sync settings store is not supported on IO');
  }
}
