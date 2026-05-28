import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:password_manager_crypto/src/models.dart';

class KeyDerivationService {
  KeyDerivationService({int iterations = defaultIterations})
      : _defaultIterations = _validateDefaultIterations(iterations);

  KeyDerivationService.insecureForTesting({int iterations = 1000})
      : _defaultIterations = _validateRecordIterations(iterations);

  static const int defaultIterations = 600000;
  static const int minIterations = 120000;
  static const int saltLength = 16;

  final int _defaultIterations;

  Future<DerivedKey> deriveKey(
    String password, {
    Uint8List? salt,
    int? iterations,
  }) async {
    final saltBytes = salt ?? _randomSalt();
    if (saltBytes.length < saltLength) {
      throw ArgumentError.value(
        saltBytes.length,
        'salt',
        'Salt must be at least $saltLength bytes.',
      );
    }
    final kdfIterations = _validateRecordIterations(
      iterations ?? _defaultIterations,
    );
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
    final bytes = List<int>.generate(saltLength, (_) => random.nextInt(256));
    return Uint8List.fromList(bytes);
  }

  static int _validateDefaultIterations(int iterations) {
    if (iterations < minIterations) {
      throw ArgumentError.value(
        iterations,
        'iterations',
        'PBKDF2 iterations must be at least $minIterations.',
      );
    }
    return iterations;
  }

  static int _validateRecordIterations(int iterations) {
    if (iterations <= 0) {
      throw ArgumentError.value(
        iterations,
        'iterations',
        'PBKDF2 iterations must be positive.',
      );
    }
    return iterations;
  }
}
