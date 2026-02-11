import 'package:password_manager_core/password_manager_core.dart';

class LocalFileVaultRepository implements VaultRepository {
  LocalFileVaultRepository({required this.filePath});

  final String filePath;

  @override
  Future<void> delete(String id) async {
    throw UnsupportedError('LocalFileVaultRepository is not supported on web');
  }

  @override
  Future<VaultItem?> getById(String id) async {
    throw UnsupportedError('LocalFileVaultRepository is not supported on web');
  }

  @override
  Future<List<VaultItem>> listAll() async {
    throw UnsupportedError('LocalFileVaultRepository is not supported on web');
  }

  @override
  Future<void> save(VaultItem item) async {
    throw UnsupportedError('LocalFileVaultRepository is not supported on web');
  }
}
