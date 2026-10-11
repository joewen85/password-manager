import 'dart:typed_data';

import 'package:password_manager_crypto/password_manager_crypto.dart';
import 'package:test/test.dart';

void main() {
  group('AesGcmCryptoService', () {
    test('encrypts and decrypts payload', () async {
      final service = AesGcmCryptoService();
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final nonce = Uint8List.fromList(List<int>.generate(12, (i) => 12 - i));
      final plaintext = Uint8List.fromList('hello-world'.codeUnits);

      final encrypted = await service.encrypt(
        plaintext,
        key,
        nonce: nonce,
      );
      final decrypted = await service.decrypt(encrypted, key);

      expect(decrypted, equals(plaintext));
    });

    test('decrypt fails with wrong key', () async {
      final service = AesGcmCryptoService();
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final wrongKey =
          Uint8List.fromList(List<int>.generate(32, (i) => 31 - i));
      final nonce = Uint8List.fromList(List<int>.generate(12, (i) => i));
      final plaintext = Uint8List.fromList('secret'.codeUnits);

      final encrypted = await service.encrypt(
        plaintext,
        key,
        nonce: nonce,
      );

      expect(() => service.decrypt(encrypted, wrongKey),
          throwsA(isA<Exception>()));
    });
  });

  group('KeyDerivationService', () {
    test('derives same key with same salt and iterations', () async {
      final service = KeyDerivationService.insecureForTesting(iterations: 1000);
      final salt = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));

      final first = await service.deriveKey('password', salt: salt);
      final second = await service.deriveKey('password', salt: salt);

      expect(first.bytes, equals(second.bytes));
      expect(first.iterations, equals(1000));
    });

    test('uses hardened PBKDF2 default for new keys', () async {
      final service = KeyDerivationService();
      final salt = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));

      final derived = await service.deriveKey('password', salt: salt);

      expect(
          derived.iterations, equals(KeyDerivationService.defaultIterations));
      expect(derived.iterations, greaterThanOrEqualTo(600000));
    });

    test('rejects weak default iteration configuration', () {
      expect(
        () => KeyDerivationService(iterations: 1000),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects short salts and non-positive record iterations', () async {
      final service = KeyDerivationService();

      await expectLater(
        () => service.deriveKey(
          'password',
          salt: Uint8List.fromList(List<int>.generate(15, (i) => i)),
        ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        () => service.deriveKey(
          'password',
          salt: Uint8List.fromList(List<int>.generate(16, (i) => i)),
          iterations: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('EncryptedPayload', () {
    test('serializes and deserializes', () {
      final payload = EncryptedPayload(
        ciphertext: Uint8List.fromList([1, 2, 3]),
        nonce: Uint8List.fromList([4, 5, 6]),
        mac: Uint8List.fromList([7, 8, 9]),
        version: 1,
      );

      final json = payload.toJson();
      final restored = EncryptedPayload.fromJson(json);

      expect(restored.ciphertext, equals(payload.ciphertext));
      expect(restored.nonce, equals(payload.nonce));
      expect(restored.mac, equals(payload.mac));
      expect(restored.version, equals(payload.version));
    });
  });
}
