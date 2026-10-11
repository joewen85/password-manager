class SyncStatus {
  const SyncStatus({
    required this.lastSyncedAt,
    required this.pendingUploads,
  });

  final DateTime? lastSyncedAt;
  final int pendingUploads;
}

abstract class SyncProvider {
  Future<void> pushAll();
  Future<void> pullAll();
  Future<SyncStatus> status();
}
