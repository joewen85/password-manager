import 'dart:convert';
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
        'ciphertext': base64Encode(ciphertext),
        'nonce': base64Encode(nonce),
        'mac': base64Encode(mac),
        'version': version,
      };

  static EncryptedPayload fromJson(Map<String, Object?> json) {
    return EncryptedPayload(
      ciphertext: base64Decode(json['ciphertext'] as String? ?? ''),
      nonce: base64Decode(json['nonce'] as String? ?? ''),
      mac: base64Decode(json['mac'] as String? ?? ''),
      version: (json['version'] as int?) ?? 1,
    );
  }
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
