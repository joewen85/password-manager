import 'dart:convert';

class MasterKeyRecord {
  const MasterKeyRecord({
    required this.salt,
    required this.iterations,
    required this.verifier,
  });

  final List<int> salt;
  final int iterations;
  final String verifier;

  Map<String, Object?> toJson() => {
        'salt': base64Encode(salt),
        'iterations': iterations,
        'verifier': verifier,
      };

  static MasterKeyRecord fromJson(Map<String, Object?> json) {
    return MasterKeyRecord(
      salt: base64Decode(json['salt'] as String? ?? ''),
      iterations: json['iterations'] as int? ?? 120000,
      verifier: json['verifier'] as String? ?? '',
    );
  }
}
