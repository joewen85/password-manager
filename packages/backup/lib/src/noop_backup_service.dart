import 'backup_service.dart';

class NoopBackupService implements BackupService {
  DateTime? lastBackupAt;

  @override
  Future<void> runBackup() async {
    lastBackupAt = DateTime.now().toUtc();
  }

  @override
  Future<void> restoreLatest() async {
    return;
  }
}
