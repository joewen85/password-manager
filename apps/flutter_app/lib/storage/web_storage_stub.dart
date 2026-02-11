import 'package:password_manager_core/password_manager_core.dart';
import 'package:password_manager_storage/password_manager_storage.dart';

class WebStorageBundle {
  WebStorageBundle({required this.repository, required this.masterKeyStore});

  final VaultRepository repository;
  final MasterKeyStore masterKeyStore;
}

Future<WebStorageBundle> openWebStorage() async {
  throw UnsupportedError('IndexedDB is not supported on this platform');
}
