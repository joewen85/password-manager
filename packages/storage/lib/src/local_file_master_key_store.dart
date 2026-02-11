import 'dart:convert';
import 'dart:io';

import 'master_key_record.dart';
import 'master_key_store.dart';

class LocalFileMasterKeyStore implements MasterKeyStore {
  LocalFileMasterKeyStore({required this.filePath});

  final String filePath;

  @override
  Future<MasterKeyRecord?> read() async {
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
    return MasterKeyRecord.fromJson(Map<String, Object?>.from(decoded));
  }

  @override
  Future<void> save(MasterKeyRecord record) async {
    final file = File(filePath);
    await file.create(recursive: true);
    await file.writeAsString(jsonEncode(record.toJson()));
  }
}
