import 'package:otp/otp.dart';

class TotpConfig {
  const TotpConfig({
    this.period = 30,
    this.digits = 6,
    this.algorithm = Algorithm.SHA1,
    this.skewWindows = 1,
  });

  final int period;
  final int digits;
  final Algorithm algorithm;
  final int skewWindows;
}

class TotpService {
  const TotpService({this.config = const TotpConfig()});

  final TotpConfig config;

  String generateCode(String secret, {DateTime? time}) {
    final milliseconds = (time ?? DateTime.now()).millisecondsSinceEpoch;
    return _generateCodeAtMilliseconds(secret, milliseconds);
  }

  bool verifyCode(String secret, String code, {DateTime? time}) {
    final normalizedCode = code.trim();
    if (!RegExp(r'^[0-9]{' + config.digits.toString() + r'}$')
        .hasMatch(normalizedCode)) {
      return false;
    }
    final milliseconds = (time ?? DateTime.now()).millisecondsSinceEpoch;
    for (var offset = -config.skewWindows;
        offset <= config.skewWindows;
        offset++) {
      final expected = _generateCodeAtMilliseconds(
        secret,
        milliseconds + offset * config.period * 1000,
      );
      if (_constantTimeEquals(expected, normalizedCode)) {
        return true;
      }
    }
    return false;
  }

  String _generateCodeAtMilliseconds(String secret, int milliseconds) {
    return OTP.generateTOTPCodeString(
      secret,
      milliseconds,
      interval: config.period,
      length: config.digits,
      algorithm: config.algorithm,
    );
  }

  bool _constantTimeEquals(String left, String right) {
    final leftUnits = left.codeUnits;
    final rightUnits = right.codeUnits;
    var diff = leftUnits.length ^ rightUnits.length;
    final maxLength = leftUnits.length > rightUnits.length
        ? leftUnits.length
        : rightUnits.length;
    for (var i = 0; i < maxLength; i++) {
      final leftUnit = i < leftUnits.length ? leftUnits[i] : 0;
      final rightUnit = i < rightUnits.length ? rightUnits[i] : 0;
      diff |= leftUnit ^ rightUnit;
    }
    return diff == 0;
  }
}
