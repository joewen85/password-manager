class ServiceAccount {
  const ServiceAccount({
    required this.username,
    required this.password,
    required this.note,
  });

  final String username;
  final String password;
  final String note;

  Map<String, Object?> toJson() => {
        'username': username,
        'password': password,
        'note': note,
      };

  static ServiceAccount fromJson(Map<String, Object?> json) {
    return ServiceAccount(
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      note: json['note'] as String? ?? '',
    );
  }
}

class ServicePayload {
  const ServicePayload({
    required this.name,
    required this.connectionAddress,
    required this.connectionPort,
    required this.accountId,
    required this.serverIds,
    required this.accounts,
    required this.notes,
    required this.tags,
    this.category = '',
  });

  final String name;
  final String connectionAddress;
  final String connectionPort;
  final String? accountId;
  final List<String> serverIds;
  final List<ServiceAccount> accounts;
  final String notes;
  final List<String> tags;
  final String category;

  Map<String, Object?> toJson() => {
        'name': name,
        'connectionAddress': connectionAddress,
        'connectionPort': connectionPort,
        'accountId': accountId,
        'serverIds': serverIds,
        'accounts': accounts.map((entry) => entry.toJson()).toList(),
        'notes': notes,
        'tags': tags,
        'category': category,
      };

  static ServicePayload fromJson(Map<String, Object?> json) {
    final rawServerIds =
        (json['serverIds'] as List?)?.whereType<String>().toList() ?? [];
    final rawAccounts = (json['accounts'] as List?) ?? const [];
    final accounts = rawAccounts
        .whereType<Map>()
        .map((entry) => ServiceAccount.fromJson(
              Map<String, Object?>.from(entry),
            ))
        .toList();
    final rawTags = (json['tags'] as List?)?.whereType<String>().toList() ?? [];
    return ServicePayload(
      name: json['name'] as String? ?? '',
      connectionAddress: json['connectionAddress'] as String? ?? '',
      connectionPort: json['connectionPort'] as String? ?? '',
      accountId: json['accountId'] as String?,
      serverIds: rawServerIds,
      accounts: accounts,
      notes: json['notes'] as String? ?? '',
      tags: rawTags,
      category: json['category'] as String? ?? '',
    );
  }
}
