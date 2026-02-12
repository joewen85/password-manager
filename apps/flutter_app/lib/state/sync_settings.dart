import 'dart:convert';
import 'dart:math';

import 'package:password_manager_crypto/password_manager_crypto.dart';

enum SyncProviderType {
  none,
  webdav,
  s3Presigned,
  nasWebdav,
}

enum ConflictStrategy {
  remoteWins,
  localWins,
  keepBoth,
}

class SyncLogEntry {
  const SyncLogEntry({
    required this.timestamp,
    required this.message,
    required this.level,
  });

  final DateTime timestamp;
  final String message;
  final String level;

  Map<String, Object?> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'message': message,
        'level': level,
      };

  static SyncLogEntry fromJson(Map<String, Object?> json) {
    return SyncLogEntry(
      timestamp:
          DateTime.tryParse(json['timestamp'] as String? ?? '')?.toUtc() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      message: json['message'] as String? ?? '',
      level: json['level'] as String? ?? 'info',
    );
  }
}

class SyncSettings {
  const SyncSettings({
    required this.providerType,
    required this.webdavUrl,
    required this.webdavUsername,
    required this.webdavPassword,
    required this.webdavPath,
    required this.presignedDownloadUrl,
    required this.presignedUploadUrl,
    required this.autoSyncEnabled,
    required this.autoSyncIntervalMinutes,
    required this.autoSyncOnUnlock,
    required this.conflictStrategy,
    required this.syncMasterKey,
    required this.deviceId,
    required this.lastSyncRevision,
    required this.lastSyncAt,
    required this.lastSyncStatus,
    required this.lastSyncMessage,
    required this.logs,
  });

  final SyncProviderType providerType;
  final String webdavUrl;
  final String webdavUsername;
  final String webdavPassword;
  final String webdavPath;
  final String presignedDownloadUrl;
  final String presignedUploadUrl;
  final bool autoSyncEnabled;
  final int autoSyncIntervalMinutes;
  final bool autoSyncOnUnlock;
  final ConflictStrategy conflictStrategy;
  final bool syncMasterKey;
  final String deviceId;
  final int lastSyncRevision;
  final DateTime? lastSyncAt;
  final String? lastSyncStatus;
  final String? lastSyncMessage;
  final List<SyncLogEntry> logs;

  factory SyncSettings.defaults() {
    return SyncSettings(
      providerType: SyncProviderType.none,
      webdavUrl: '',
      webdavUsername: '',
      webdavPassword: '',
      webdavPath: '/vault.json',
      presignedDownloadUrl: '',
      presignedUploadUrl: '',
      autoSyncEnabled: false,
      autoSyncIntervalMinutes: 30,
      autoSyncOnUnlock: true,
      conflictStrategy: ConflictStrategy.remoteWins,
      syncMasterKey: true,
      deviceId: generateDeviceId(),
      lastSyncRevision: 0,
      lastSyncAt: null,
      lastSyncStatus: null,
      lastSyncMessage: null,
      logs: <SyncLogEntry>[],
    );
  }

  SyncSettings copyWith({
    SyncProviderType? providerType,
    String? webdavUrl,
    String? webdavUsername,
    String? webdavPassword,
    String? webdavPath,
    String? presignedDownloadUrl,
    String? presignedUploadUrl,
    bool? autoSyncEnabled,
    int? autoSyncIntervalMinutes,
    bool? autoSyncOnUnlock,
    ConflictStrategy? conflictStrategy,
    bool? syncMasterKey,
    String? deviceId,
    int? lastSyncRevision,
    DateTime? lastSyncAt,
    String? lastSyncStatus,
    String? lastSyncMessage,
    List<SyncLogEntry>? logs,
  }) {
    return SyncSettings(
      providerType: providerType ?? this.providerType,
      webdavUrl: webdavUrl ?? this.webdavUrl,
      webdavUsername: webdavUsername ?? this.webdavUsername,
      webdavPassword: webdavPassword ?? this.webdavPassword,
      webdavPath: webdavPath ?? this.webdavPath,
      presignedDownloadUrl: presignedDownloadUrl ?? this.presignedDownloadUrl,
      presignedUploadUrl: presignedUploadUrl ?? this.presignedUploadUrl,
      autoSyncEnabled: autoSyncEnabled ?? this.autoSyncEnabled,
      autoSyncIntervalMinutes:
          autoSyncIntervalMinutes ?? this.autoSyncIntervalMinutes,
      autoSyncOnUnlock: autoSyncOnUnlock ?? this.autoSyncOnUnlock,
      conflictStrategy: conflictStrategy ?? this.conflictStrategy,
      syncMasterKey: syncMasterKey ?? this.syncMasterKey,
      deviceId: deviceId ?? this.deviceId,
      lastSyncRevision: lastSyncRevision ?? this.lastSyncRevision,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastSyncStatus: lastSyncStatus ?? this.lastSyncStatus,
      lastSyncMessage: lastSyncMessage ?? this.lastSyncMessage,
      logs: logs ?? this.logs,
    );
  }

  Map<String, Object?> toJson() => {
        'providerType': providerType.name,
        'webdavUrl': webdavUrl,
        'webdavUsername': webdavUsername,
        'webdavPassword': webdavPassword,
        'webdavPath': webdavPath,
        'presignedDownloadUrl': presignedDownloadUrl,
        'presignedUploadUrl': presignedUploadUrl,
        'autoSyncEnabled': autoSyncEnabled,
        'autoSyncIntervalMinutes': autoSyncIntervalMinutes,
        'autoSyncOnUnlock': autoSyncOnUnlock,
        'conflictStrategy': conflictStrategy.name,
        'syncMasterKey': syncMasterKey,
        'deviceId': deviceId,
        'lastSyncRevision': lastSyncRevision,
        'lastSyncAt': lastSyncAt?.toIso8601String(),
        'lastSyncStatus': lastSyncStatus,
        'lastSyncMessage': lastSyncMessage,
        'logs': logs.map((entry) => entry.toJson()).toList(),
      };

  static SyncSettings fromJson(Map<String, Object?> json) {
    return SyncSettings(
      providerType: _parseProvider(json['providerType']),
      webdavUrl: json['webdavUrl'] as String? ?? '',
      webdavUsername: json['webdavUsername'] as String? ?? '',
      webdavPassword: json['webdavPassword'] as String? ?? '',
      webdavPath: json['webdavPath'] as String? ?? '/vault.json',
      presignedDownloadUrl: json['presignedDownloadUrl'] as String? ?? '',
      presignedUploadUrl: json['presignedUploadUrl'] as String? ?? '',
      autoSyncEnabled: json['autoSyncEnabled'] as bool? ?? false,
      autoSyncIntervalMinutes:
          json['autoSyncIntervalMinutes'] as int? ?? 30,
      autoSyncOnUnlock: json['autoSyncOnUnlock'] as bool? ?? true,
      conflictStrategy: _parseConflict(json['conflictStrategy']),
      syncMasterKey: json['syncMasterKey'] as bool? ?? true,
      deviceId: json['deviceId'] as String? ?? '',
      lastSyncRevision: json['lastSyncRevision'] as int? ?? 0,
      lastSyncAt:
          DateTime.tryParse(json['lastSyncAt'] as String? ?? '')?.toUtc(),
      lastSyncStatus: json['lastSyncStatus'] as String?,
      lastSyncMessage: json['lastSyncMessage'] as String?,
      logs: (json['logs'] as List? ?? [])
          .whereType<Map>()
          .map((entry) => SyncLogEntry.fromJson(
                Map<String, Object?>.from(entry),
              ))
          .toList(),
    );
  }

  static SyncProviderType _parseProvider(Object? raw) {
    final value = raw as String? ?? 'none';
    return SyncProviderType.values.firstWhere(
      (entry) => entry.name == value,
      orElse: () => SyncProviderType.none,
    );
  }

  static ConflictStrategy _parseConflict(Object? raw) {
    final value = raw as String? ?? 'remoteWins';
    return ConflictStrategy.values.firstWhere(
      (entry) => entry.name == value,
      orElse: () => ConflictStrategy.remoteWins,
    );
  }

  static String generateDeviceId() {
    final random = Random.secure();
    final part = random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return '${DateTime.now().microsecondsSinceEpoch}-$part';
  }
}

class SyncSettingsRecord {
  const SyncSettingsRecord({
    required this.encryptedPayload,
    required this.kdfSalt,
    required this.kdfIterations,
  });

  final EncryptedPayload encryptedPayload;
  final List<int> kdfSalt;
  final int kdfIterations;

  Map<String, Object?> toJson() => {
        'encryptedPayload': encryptedPayload.toJson(),
        'kdfSalt': base64Encode(kdfSalt),
        'kdfIterations': kdfIterations,
      };

  static SyncSettingsRecord fromJson(Map<String, Object?> json) {
    return SyncSettingsRecord(
      encryptedPayload: EncryptedPayload.fromJson(
        Map<String, Object?>.from(json['encryptedPayload'] as Map? ?? {}),
      ),
      kdfSalt: base64Decode(json['kdfSalt'] as String? ?? ''),
      kdfIterations: json['kdfIterations'] as int? ?? 120000,
    );
  }
}
