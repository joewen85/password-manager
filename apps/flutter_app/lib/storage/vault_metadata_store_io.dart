import 'dart:convert';
import 'dart:io';

import '../state/vault_metadata.dart';
import 'vault_metadata_store.dart';

class FileVaultMetadataStore implements VaultMetadataStore {
  FileVaultMetadataStore({required this.filePath});

  final String filePath;

  @override
  Future<VaultMetadataRecord?> read() async {
    final file = File(filePath);
    if (!await file.exists()) {
      return null;
    }
    final contents = await file.readAsString();
    if (contents.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(contents);
    if (decoded is! Map) {
      return null;
    }
    return VaultMetadataRecord.fromJson(Map<String, Object?>.from(decoded));
  }

  @override
  Future<void> save(VaultMetadataRecord record) async {
    final file = File(filePath);
    await file.create(recursive: true);
    await file.writeAsString(jsonEncode(record.toJson()));
  }
}

class WebVaultMetadataStore implements VaultMetadataStore {
  @override
  Future<VaultMetadataRecord?> read() async {
    throw UnsupportedError('Web vault metadata store is not supported on IO');
  }

  @override
  Future<void> save(VaultMetadataRecord record) async {
    throw UnsupportedError('Web vault metadata store is not supported on IO');
  }
}
