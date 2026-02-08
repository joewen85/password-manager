import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'models.dart';

class KeyDerivationService {
  KeyDerivationService({int iterations = 120000})
      : _defaultIterations = iterations;

  final int _defaultIterations;

  Future<DerivedKey> deriveKey(
    String password, {
    Uint8List? salt,
    int? iterations,
  }) async {
    final saltBytes = salt ?? _randomSalt();
    final kdfIterations = iterations ?? _defaultIterations;
    final pbkdf2 = _pbkdf2For(kdfIterations);
    final secretKey = await pbkdf2.deriveKey(
      secretKey: SecretKey(Uint8List.fromList(utf8.encode(password))),
      nonce: saltBytes,
    );
    final keyBytes = await secretKey.extractBytes();
    return DerivedKey(
      bytes: Uint8List.fromList(keyBytes),
      salt: saltBytes,
      iterations: kdfIterations,
    );
  }

  Pbkdf2 _pbkdf2For(int iterations) {
    return Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
  }

  Uint8List _randomSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return Uint8List.fromList(bytes);
  }

}
