import 'dart:typed_data';

class EncryptedPayload {
  const EncryptedPayload({
    required this.ciphertext,
    required this.nonce,
    required this.mac,
    required this.version,
  });

  final Uint8List ciphertext;
  final Uint8List nonce;
  final Uint8List mac;
  final int version;

  Map<String, Object> toJson() => {
        'ciphertext': ciphertext,
        'nonce': nonce,
        'mac': mac,
        'version': version,
      };
}

class DerivedKey {
  const DerivedKey({
    required this.bytes,
    required this.salt,
    required this.iterations,
  });

  final Uint8List bytes;
  final Uint8List salt;
  final int iterations;
}
