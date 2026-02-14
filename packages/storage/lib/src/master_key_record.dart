import 'dart:convert';

class MasterKeyRecord {
  const MasterKeyRecord({
    required this.salt,
    required this.iterations,
    required this.verifier,
    this.metadataSalt,
    this.metadataIterations,
  });

  final List<int> salt;
  final int iterations;
  final String verifier;
  final List<int>? metadataSalt;
  final int? metadataIterations;

  Map<String, Object?> toJson() => {
        'salt': base64Encode(salt),
        'iterations': iterations,
        'verifier': verifier,
        'metadataSalt': metadataSalt == null ? null : base64Encode(metadataSalt!),
        'metadataIterations': metadataIterations,
      };

  static MasterKeyRecord fromJson(Map<String, Object?> json) {
    return MasterKeyRecord(
      salt: base64Decode(json['salt'] as String? ?? ''),
      iterations: json['iterations'] as int? ?? 120000,
      verifier: json['verifier'] as String? ?? '',
      metadataSalt: _decodeOptionalBytes(json['metadataSalt']),
      metadataIterations: json['metadataIterations'] as int?,
    );
  }
}

List<int>? _decodeOptionalBytes(Object? raw) {
  if (raw is! String || raw.isEmpty) {
    return null;
  }
  return base64Decode(raw);
}
