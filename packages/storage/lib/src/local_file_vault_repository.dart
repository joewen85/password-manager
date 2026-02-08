import 'dart:convert';
import 'dart:io';

import 'package:password_manager_core/password_manager_core.dart';

import 'vault_serialization.dart';

class LocalFileVaultRepository implements VaultRepository {
  LocalFileVaultRepository({required this.filePath});

  final String filePath;

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
    final file = await _ensureFile();
    final contents = await file.readAsString();
    if (contents.trim().isEmpty) {
      return [];
    }
    final decoded = jsonDecode(contents);
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

  Future<File> _ensureFile() async {
    final file = File(filePath);
    if (!await file.exists()) {
      await file.create(recursive: true);
      await file.writeAsString(jsonEncode(<Object>[]));
    }
    return file;
  }

  Future<void> _writeAll(List<VaultItem> items) async {
    final file = await _ensureFile();
    final encoded = jsonEncode(items.map(vaultItemToJson).toList());
    await file.writeAsString(encoded);
  }
}
