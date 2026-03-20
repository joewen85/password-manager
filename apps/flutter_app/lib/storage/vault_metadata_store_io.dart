import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../state/vault_metadata.dart';
import 'vault_metadata_store.dart';

class FileVaultMetadataStore implements VaultMetadataStore {
  FileVaultMetadataStore({required this.filePath});

  final String filePath;
  Future<void> _pendingWrite = Future<void>.value();

  @override
  Future<VaultMetadataRecord?> read() async {
    await _pendingWrite.catchError((_) {});
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
    final encoded = jsonEncode(record.toJson());
    await _enqueueWrite(encoded);
  }

  Future<void> _enqueueWrite(String contents) async {
    final completer = Completer<void>();
    final previous = _pendingWrite;
    _pendingWrite = completer.future;
    await previous.catchError((_) {});
    try {
      final file = File(filePath);
      await file.create(recursive: true);
      final tempFile = File('$filePath.tmp');
      await tempFile.create(recursive: true);
      await tempFile.writeAsString(contents, flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await tempFile.rename(file.path);
      completer.complete();
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
      rethrow;
    }
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
