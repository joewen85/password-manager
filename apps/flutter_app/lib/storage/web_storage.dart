import 'dart:convert';

import 'package:password_manager_core/password_manager_core.dart';
import 'package:password_manager_storage/password_manager_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WebVaultRepository implements VaultRepository {
  WebVaultRepository({
    required SharedPreferences preferences,
    this.storageKey = 'vault_items',
  }) : _preferences = preferences;

  final SharedPreferences _preferences;
  final String storageKey;

  @override
  Future<void> save(VaultItem item) async {
    final items = await listAll();
    final index = items.indexWhere((entry) => entry.id == item.id);
    if (index >= 0) {
      items[index] = item;
    } else {
      items.add(item);
    }
    await _writeAll(items);
  }

  @override
  Future<VaultItem?> getById(String id) async {
    final items = await listAll();
    return items.cast<VaultItem?>().firstWhere(
          (entry) => entry?.id == id,
          orElse: () => null,
        );
  }

  @override
  Future<List<VaultItem>> listAll() async {
    final raw = _preferences.getString(storageKey);
    if (raw == null || raw.trim().isEmpty) {
      return [];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return [];
    }
    return decoded
        .whereType<Map>()
        .map((entry) => vaultItemFromJson(Map<String, Object?>.from(entry)))
        .toList();
  }

  @override
  Future<void> delete(String id) async {
    final items = await listAll();
    items.removeWhere((entry) => entry.id == id);
    await _writeAll(items);
  }

  Future<void> _writeAll(List<VaultItem> items) async {
    final encoded = jsonEncode(items.map(vaultItemToJson).toList());
    await _preferences.setString(storageKey, encoded);
  }
}

class WebMasterKeyStore implements MasterKeyStore {
  WebMasterKeyStore({
    required SharedPreferences preferences,
    this.storageKey = 'master_key_record',
  }) : _preferences = preferences;

  final SharedPreferences _preferences;
  final String storageKey;

  @override
  Future<MasterKeyRecord?> read() async {
    final raw = _preferences.getString(storageKey);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return null;
    }
    return MasterKeyRecord.fromJson(Map<String, Object?>.from(decoded));
  }

  @override
  Future<void> save(MasterKeyRecord record) async {
    await _preferences.setString(storageKey, jsonEncode(record.toJson()));
  }
}
