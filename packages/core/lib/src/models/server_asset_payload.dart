class ServerAssetPayload {
  const ServerAssetPayload({
    required this.name,
    required this.ipAddress,
    required this.port,
    required this.username,
    required this.password,
    required this.basicConfig,
    required this.operatingSystem,
    required this.location,
    required this.notes,
    required this.tags,
  });

  final String name;
  final String ipAddress;
  final String port;
  final String username;
  final String password;
  final String basicConfig;
  final String operatingSystem;
  final String location;
  final String notes;
  final List<String> tags;

  Map<String, Object> toJson() => {
        'name': name,
        'ipAddress': ipAddress,
        'port': port,
        'username': username,
        'password': password,
        'basicConfig': basicConfig,
        'operatingSystem': operatingSystem,
        'location': location,
        'notes': notes,
        'tags': tags,
      };

  static ServerAssetPayload fromJson(Map<String, Object?> json) {
    final rawTags = (json['tags'] as List?)?.whereType<String>().toList() ?? [];
    return ServerAssetPayload(
      name: json['name'] as String? ?? '',
      ipAddress: json['ipAddress'] as String? ?? '',
      port: json['port'] as String? ?? '',
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      basicConfig: json['basicConfig'] as String? ?? '',
      operatingSystem: json['operatingSystem'] as String? ?? '',
      location: json['location'] as String? ?? '',
      notes: json['notes'] as String? ?? '',
      tags: rawTags,
    );
  }
}
