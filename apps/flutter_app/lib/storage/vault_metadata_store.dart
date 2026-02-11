import '../state/vault_metadata.dart';

abstract class VaultMetadataStore {
  Future<VaultMetadataRecord?> read();
  Future<void> save(VaultMetadataRecord record);
}
