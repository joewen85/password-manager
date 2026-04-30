import '../state/sync_settings.dart';

abstract class SyncSettingsStore {
  Future<SyncSettingsRecord?> read();
  Future<void> save(SyncSettingsRecord record);
}

class MemorySyncSettingsStore implements SyncSettingsStore {
  SyncSettingsRecord? _record;

  @override
  Future<SyncSettingsRecord?> read() async => _record;

  @override
  Future<void> save(SyncSettingsRecord record) async {
    _record = record;
  }
}
