import 'package:password_manager_core/password_manager_core.dart';

class LocalFileVaultRepository implements VaultRepository {
  LocalFileVaultRepository({required this.filePath});

  final String filePath;

  @override
  Future<void> delete(String id) async {
    throw UnsupportedError('LocalFileVaultRepository is not supported on web');
  }

  @override
  Future<VaultItemRecord?> getById(String id) async {
    throw UnsupportedError('LocalFileVaultRepository is not supported on web');
  }

  @override
  Future<List<VaultItemRecord>> listAll() async {
    throw UnsupportedError('LocalFileVaultRepository is not supported on web');
  }

  @override
  Future<void> save(VaultItemRecord item) async {
    throw UnsupportedError('LocalFileVaultRepository is not supported on web');
  }

  @override
  Future<void> saveAll(List<VaultItemRecord> items) async {
    throw UnsupportedError('LocalFileVaultRepository is not supported on web');
  }
}
