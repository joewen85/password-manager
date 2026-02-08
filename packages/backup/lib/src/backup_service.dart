abstract class BackupService {
  Future<void> runBackup();
  Future<void> restoreLatest();
}
