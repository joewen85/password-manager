import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'crypto_service.dart';
import 'models.dart';

class AesGcmCryptoService implements CryptoService {
  AesGcmCryptoService({AesGcm? cipher}) : _cipher = cipher ?? AesGcm.with256bits();

  final AesGcm _cipher;

  @override
  Future<EncryptedPayload> encrypt(
    Uint8List plaintext,
    Uint8List keyBytes, {
    required Uint8List nonce,
  }) async {
    final secretKey = SecretKey(keyBytes);
    final secretBox = await _cipher.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: nonce,
    );
    return EncryptedPayload(
      ciphertext: Uint8List.fromList(secretBox.cipherText),
      nonce: Uint8List.fromList(secretBox.nonce),
      mac: Uint8List.fromList(secretBox.mac.bytes),
      version: 1,
    );
  }

  @override
  Future<Uint8List> decrypt(
    EncryptedPayload payload,
    Uint8List keyBytes,
  ) async {
    final secretKey = SecretKey(keyBytes);
    final secretBox = SecretBox(
      payload.ciphertext,
      nonce: payload.nonce,
      mac: Mac(payload.mac),
    );
    final clearBytes = await _cipher.decrypt(
      secretBox,
      secretKey: secretKey,
    );
    return Uint8List.fromList(clearBytes);
  }
}
