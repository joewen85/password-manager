import 'package:password_manager_core/password_manager_core.dart';

class InMemoryVaultRepository implements VaultRepository {
  final Map<String, VaultItemRecord> _store = {};

  @override
  Future<void> delete(String id) async {
    _store.remove(id);
  }

  @override
  Future<VaultItemRecord?> getById(String id) async => _store[id];

  @override
  Future<List<VaultItemRecord>> listAll() async => _store.values.toList();

  @override
  Future<void> save(VaultItemRecord item) async {
    _store[item.id] = item;
  }

  @override
  Future<void> saveAll(List<VaultItemRecord> items) async {
    for (final item in items) {
      _store[item.id] = item;
    }
  }
}
