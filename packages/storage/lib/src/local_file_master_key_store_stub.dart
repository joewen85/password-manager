import 'master_key_record.dart';
import 'master_key_store.dart';

class LocalFileMasterKeyStore implements MasterKeyStore {
  LocalFileMasterKeyStore({required this.filePath});

  final String filePath;

  @override
  Future<MasterKeyRecord?> read() async {
    throw UnsupportedError('LocalFileMasterKeyStore is not supported on web');
  }

  @override
  Future<void> save(MasterKeyRecord record) async {
    throw UnsupportedError('LocalFileMasterKeyStore is not supported on web');
  }
}
