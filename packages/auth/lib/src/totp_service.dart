import 'package:otp/otp.dart';

class TotpConfig {
  const TotpConfig({
    this.period = 30,
    this.digits = 6,
    this.algorithm = Algorithm.SHA1,
  });

  final int period;
  final int digits;
  final Algorithm algorithm;
}

class TotpService {
  const TotpService({this.config = const TotpConfig()});

  final TotpConfig config;

  String generateCode(String secret, {DateTime? time}) {
    final seconds = (time ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    return OTP.generateTOTPCodeString(
      secret,
      seconds,
      interval: config.period,
      length: config.digits,
      algorithm: config.algorithm,
    );
  }

  bool verifyCode(String secret, String code, {DateTime? time}) {
    return generateCode(secret, time: time) == code;
  }
}
