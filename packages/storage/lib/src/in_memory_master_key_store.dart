import 'master_key_record.dart';
import 'master_key_store.dart';

class InMemoryMasterKeyStore implements MasterKeyStore {
  MasterKeyRecord? _record;

  @override
  Future<MasterKeyRecord?> read() async => _record;

  @override
  Future<void> save(MasterKeyRecord record) async {
    _record = record;
  }
}
