import 'service_payload.dart';

class CredentialPayload {
  const CredentialPayload({
    required this.username,
    required this.password,
    this.accounts = const <ServiceAccount>[],
    required this.token,
    required this.appId,
    required this.accessKey,
    required this.secretKey,
    required this.notes,
    required this.tags,
    this.category = '',
  });

  final String username;
  final String password;
  final List<ServiceAccount> accounts;
  final String token;
  final String appId;
  final String accessKey;
  final String secretKey;
  final String notes;
  final List<String> tags;
  final String category;

  Map<String, Object> toJson() => {
        'username': username,
        'password': password,
        'accounts': accounts.map((entry) => entry.toJson()).toList(),
        'token': token,
        'appId': appId,
        'accessKey': accessKey,
        'secretKey': secretKey,
        'notes': notes,
        'tags': tags,
        'category': category,
      };

  static CredentialPayload fromJson(Map<String, Object?> json) {
    final rawTags = (json['tags'] as List?)?.whereType<String>().toList() ?? [];
    final rawAccessKey = json['accessKey'] ?? json['accessToken'];
    final rawAccounts = (json['accounts'] as List?) ?? const [];
    final accounts = rawAccounts
        .whereType<Map>()
        .map((entry) => ServiceAccount.fromJson(
              Map<String, Object?>.from(entry),
            ))
        .toList();
    return CredentialPayload(
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      accounts: accounts,
      token: json['token'] as String? ?? '',
      appId: json['appId'] as String? ?? '',
      accessKey: rawAccessKey is String ? rawAccessKey : '',
      secretKey: json['secretKey'] as String? ?? '',
      notes: json['notes'] as String? ?? '',
      tags: rawTags,
      category: json['category'] as String? ?? '',
    );
  }
}
