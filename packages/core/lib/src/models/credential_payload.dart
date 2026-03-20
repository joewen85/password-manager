class CredentialPayload {
  const CredentialPayload({
    required this.username,
    required this.password,
    required this.token,
    required this.appId,
    required this.accessToken,
    required this.secretKey,
    required this.notes,
    required this.tags,
    this.category = '',
  });

  final String username;
  final String password;
  final String token;
  final String appId;
  final String accessToken;
  final String secretKey;
  final String notes;
  final List<String> tags;
  final String category;

  Map<String, Object> toJson() => {
        'username': username,
        'password': password,
        'token': token,
        'appId': appId,
        'accessToken': accessToken,
        'secretKey': secretKey,
        'notes': notes,
        'tags': tags,
        'category': category,
      };

  static CredentialPayload fromJson(Map<String, Object?> json) {
    final rawTags = (json['tags'] as List?)?.whereType<String>().toList() ?? [];
    return CredentialPayload(
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      token: json['token'] as String? ?? '',
      appId: json['appId'] as String? ?? '',
      accessToken: json['accessToken'] as String? ?? '',
      secretKey: json['secretKey'] as String? ?? '',
      notes: json['notes'] as String? ?? '',
      tags: rawTags,
      category: json['category'] as String? ?? '',
    );
  }
}
