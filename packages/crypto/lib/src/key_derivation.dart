import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'models.dart';

class KeyDerivationService {
  KeyDerivationService({Pbkdf2? pbkdf2})
      : _pbkdf2 = pbkdf2 ?? Pbkdf2(
          macAlgorithm: Hmac.sha256(),
          iterations: 120000,
          bits: 256,
        );

  final Pbkdf2 _pbkdf2;

  Future<DerivedKey> deriveKey(String password, {Uint8List? salt}) async {
    final saltBytes = salt ?? _randomSalt();
    final secretKey = await _pbkdf2.deriveKey(
      secretKey: SecretKey(Uint8List.fromList(utf8.encode(password))),
      nonce: saltBytes,
    );
    final keyBytes = await secretKey.extractBytes();
    return DerivedKey(
      bytes: Uint8List.fromList(keyBytes),
      salt: saltBytes,
      iterations: _pbkdf2.iterations,
    );
  }

  Uint8List _randomSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return Uint8List.fromList(bytes);
  }

}
