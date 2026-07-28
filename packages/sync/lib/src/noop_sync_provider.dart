import 'package:password_manager_sync/src/sync_interfaces.dart';

class NoopSyncProvider implements SyncProvider {
  DateTime? _lastSyncedAt;

  @override
  Future<void> pushAll() async {
    _lastSyncedAt = DateTime.now().toUtc();
  }

  @override
  Future<void> pullAll() async {
    _lastSyncedAt = DateTime.now().toUtc();
  }

  @override
  Future<SyncStatus> status() async {
    return SyncStatus(lastSyncedAt: _lastSyncedAt, pendingUploads: 0);
  }
}
