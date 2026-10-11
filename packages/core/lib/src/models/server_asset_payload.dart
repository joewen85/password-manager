import 'service_payload.dart';

class ServerAssetPayload {
  const ServerAssetPayload({
    required this.name,
    required this.ipAddress,
    required this.port,
    required this.username,
    required this.password,
    this.accounts = const <ServiceAccount>[],
    required this.basicConfig,
    required this.operatingSystem,
    required this.location,
    required this.notes,
    required this.tags,
    this.accountId,
    this.category = '',
  });

  final String name;
  final String ipAddress;
  final String port;
  final String username;
  final String password;
  final List<ServiceAccount> accounts;
  final String basicConfig;
  final String operatingSystem;
  final String location;
  final String notes;
  final List<String> tags;
  final String? accountId;
  final String category;

  Map<String, Object?> toJson() => {
        'name': name,
        'ipAddress': ipAddress,
        'port': port,
        'username': username,
        'password': password,
        'accounts': accounts.map((entry) => entry.toJson()).toList(),
        'basicConfig': basicConfig,
        'operatingSystem': operatingSystem,
        'location': location,
        'notes': notes,
        'tags': tags,
        'accountId': accountId,
        'category': category,
      };

  static ServerAssetPayload fromJson(Map<String, Object?> json) {
    final rawTags = (json['tags'] as List?)?.whereType<String>().toList() ?? [];
    final rawAccounts = (json['accounts'] as List?) ?? const [];
    final accounts = rawAccounts
        .whereType<Map>()
        .map((entry) => ServiceAccount.fromJson(
              Map<String, Object?>.from(entry),
            ))
        .toList();
    return ServerAssetPayload(
      name: json['name'] as String? ?? '',
      ipAddress: json['ipAddress'] as String? ?? '',
      port: json['port'] as String? ?? '',
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      accounts: accounts,
      basicConfig: json['basicConfig'] as String? ?? '',
      operatingSystem: json['operatingSystem'] as String? ?? '',
      location: json['location'] as String? ?? '',
      notes: json['notes'] as String? ?? '',
      tags: rawTags,
      accountId: json['accountId'] as String?,
      category: json['category'] as String? ?? '',
    );
  }
}
