import 'dart:typed_data';

import 'models.dart';

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
