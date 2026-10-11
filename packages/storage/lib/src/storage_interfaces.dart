abstract class EncryptedStorage<T> {
  Future<void> save(String id, T data);
  Future<T?> get(String id);
  Future<List<T>> list();
  Future<void> remove(String id);
}
