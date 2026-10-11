import 'master_key_record.dart';

abstract class MasterKeyStore {
  Future<MasterKeyRecord?> read();
  Future<void> save(MasterKeyRecord record);
}
