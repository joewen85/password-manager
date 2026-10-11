import 'dart:typed_data';

import 'package:password_manager_crypto/src/models.dart';

abstract class CryptoService {
  Future<EncryptedPayload> encrypt(
    Uint8List plaintext,
    Uint8List keyBytes, {
    required Uint8List nonce,
  });

  Future<Uint8List> decrypt(
    EncryptedPayload payload,
    Uint8List keyBytes,
  );
}
