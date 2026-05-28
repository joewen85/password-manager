import 'package:otp/otp.dart';
import 'package:password_manager_auth/password_manager_auth.dart';
import 'package:test/test.dart';

void main() {
  group('TotpService', () {
    test('generates RFC 6238 SHA1 test vector', () {
      const service = TotpService(
        config: TotpConfig(digits: 8, skewWindows: 0),
      );

      final code = service.generateCode(
        '12345678901234567890',
        time: DateTime.fromMillisecondsSinceEpoch(
          59000,
          isUtc: true,
        ),
      );

      expect(code, equals('94287082'));
    });

    test('accepts adjacent time step within configured skew window', () {
      const secret = 'JBSWY3DPEHPK3PXP';
      const service = TotpService();
      final now = DateTime.fromMillisecondsSinceEpoch(
        60000,
        isUtc: true,
      );
      final previousCode = service.generateCode(
        secret,
        time: now.subtract(const Duration(seconds: 30)),
      );

      expect(service.verifyCode(secret, previousCode, time: now), isTrue);
    });

    test('rejects malformed and out-of-window codes', () {
      const secret = 'JBSWY3DPEHPK3PXP';
      const service = TotpService(
        config: TotpConfig(algorithm: Algorithm.SHA1, skewWindows: 0),
      );
      final now = DateTime.fromMillisecondsSinceEpoch(
        60000,
        isUtc: true,
      );
      final oldCode = service.generateCode(
        secret,
        time: now.subtract(const Duration(seconds: 30)),
      );

      expect(service.verifyCode(secret, 'abc123', time: now), isFalse);
      expect(service.verifyCode(secret, oldCode, time: now), isFalse);
    });
  });
}
