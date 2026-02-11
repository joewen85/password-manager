import 'package:password_manager_core/password_manager_core.dart';

class InMemoryVaultRepository implements VaultRepository {
  final Map<String, VaultItem> _store = {};

  @override
  Future<void> delete(String id) async {
    _store.remove(id);
  }

  @override
  Future<VaultItem?> getById(String id) async => _store[id];

  @override
  Future<List<VaultItem>> listAll() async => _store.values.toList();

  @override
  Future<void> save(VaultItem item) async {
    _store[item.id] = item;
  }
}
