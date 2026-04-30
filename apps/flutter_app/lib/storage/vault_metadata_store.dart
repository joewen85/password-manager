import '../state/vault_metadata.dart';

abstract class VaultMetadataStore {
  Future<VaultMetadataRecord?> read();
  Future<void> save(VaultMetadataRecord record);
}

class MemoryVaultMetadataStore implements VaultMetadataStore {
  VaultMetadataRecord? _record;

  @override
  Future<VaultMetadataRecord?> read() async => _record;

  @override
  Future<void> save(VaultMetadataRecord record) async {
    _record = record;
  }
}
