import '../state/sync_settings.dart';

abstract class SyncSettingsStore {
  Future<SyncSettingsRecord?> read();
  Future<void> save(SyncSettingsRecord record);
}
