import 'package:password_manager_crypto/password_manager_crypto.dart';

class VaultItem {
  const VaultItem({
    required this.id,
    required this.label,
    required this.encryptedPayload,
    required this.kdfSalt,
    required this.kdfIterations,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String label;
  final EncryptedPayload encryptedPayload;
  final List<int> kdfSalt;
  final int kdfIterations;
  final DateTime createdAt;
  final DateTime updatedAt;
}
