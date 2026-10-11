import Foundation

enum SyncProviderType: String, CaseIterable, Codable, Sendable {
    case none
    case webdav
    case s3Presigned
    case nasWebdav
    case tencentCos
    case aliyunOss

    var title: String {
        switch self {
        case .none:
            L10n.t("None")
        case .webdav:
            "WebDAV"
        case .s3Presigned:
            "S3 Presigned URL"
        case .nasWebdav:
            "NAS WebDAV"
        case .tencentCos:
            "Tencent COS"
        case .aliyunOss:
            "Aliyun OSS"
        }
    }
}

enum SyncSettingsConflictStrategy: String, CaseIterable, Codable, Sendable {
    case remoteWins
    case localWins
    case keepBoth

    var title: String {
        switch self {
        case .remoteWins:
            L10n.t("Remote Wins")
        case .localWins:
            L10n.t("Local Wins")
        case .keepBoth:
            L10n.t("Keep Both")
        }
    }

    var mergeStrategy: SyncConflictStrategy {
        switch self {
        case .remoteWins:
            .remoteWins
        case .localWins:
            .localWins
        case .keepBoth:
            .keepBoth
        }
    }
}

enum SyncIntervalUnit: String, CaseIterable, Codable, Sendable {
    case seconds
    case minutes

    var title: String {
        switch self {
        case .seconds:
            L10n.t("Seconds")
        case .minutes:
            L10n.t("Minutes")
        }
    }
}

struct SyncLogEntry: Codable, Equatable, Sendable {
    var timestamp: Date
    var message: String
    var level: String
}

struct SyncSettings: Codable, Equatable, Sendable {
    var providerType: SyncProviderType
    var webdavUrl: String
    var webdavUsername: String
    var webdavPassword: String
    var webdavPath: String
    var presignedDownloadUrl: String
    var presignedUploadUrl: String
    var objectStorageAccessKey: String
    var objectStorageSecretKey: String
    var objectStorageBucket: String
    var objectStorageEndpoint: String
    var objectStorageAppId: String
    var objectStorageCustomUrl: String
    var objectStorageObjectKey: String
    var autoSyncEnabled: Bool
    var autoSyncIntervalMinutes: Int
    var autoSyncIntervalValue: Int
    var autoSyncIntervalUnit: SyncIntervalUnit
    var autoSyncOnUnlock: Bool
    var conflictStrategy: SyncSettingsConflictStrategy
    var syncMasterKey: Bool
    var deviceId: String
    var lastSyncRevision: Int
    var lastSyncAt: Date?
    var lastSyncStatus: String?
    var lastSyncMessage: String?
    var lastRemoteFingerprint: String?
    var hasLocalChanges: Bool
    var logs: [SyncLogEntry]

    private enum CodingKeys: String, CodingKey {
        case providerType
        case webdavUrl
        case webdavUsername
        case webdavPassword
        case webdavPath
        case presignedDownloadUrl
        case presignedUploadUrl
        case objectStorageAccessKey
        case ak
        case accessKey
        case objectStorageSecretKey
        case sk
        case secretKey
        case objectStorageBucket
        case bucket
        case objectStorageEndpoint
        case endpoint
        case objectStorageAppId
        case appid
        case appId
        case objectStorageCustomUrl
        case customUrl
        case objectStorageObjectKey
        case objectKey
        case autoSyncEnabled
        case autoSyncIntervalMinutes
        case autoSyncIntervalValue
        case autoSyncIntervalUnit
        case autoSyncOnUnlock
        case conflictStrategy
        case syncMasterKey
        case deviceId
        case lastSyncRevision
        case lastSyncAt
        case lastSyncStatus
        case lastSyncMessage
        case lastRemoteFingerprint
        case hasLocalChanges
        case logs
    }

    static func defaults(deviceId: String = generateDeviceId()) -> SyncSettings {
        SyncSettings(
            providerType: .none,
            webdavUrl: "",
            webdavUsername: "",
            webdavPassword: "",
            webdavPath: "/vault.json",
            presignedDownloadUrl: "",
            presignedUploadUrl: "",
            objectStorageAccessKey: "",
            objectStorageSecretKey: "",
            objectStorageBucket: "",
            objectStorageEndpoint: "",
            objectStorageAppId: "",
            objectStorageCustomUrl: "",
            objectStorageObjectKey: "vault.sync.json",
            autoSyncEnabled: false,
            autoSyncIntervalMinutes: 30,
            autoSyncIntervalValue: 30,
            autoSyncIntervalUnit: .minutes,
            autoSyncOnUnlock: true,
            conflictStrategy: .remoteWins,
            syncMasterKey: true,
            deviceId: deviceId,
            lastSyncRevision: 0,
            lastSyncAt: nil,
            lastSyncStatus: nil,
            lastSyncMessage: nil,
            lastRemoteFingerprint: nil,
            hasLocalChanges: false,
            logs: []
        )
    }

    static func generateDeviceId() -> String {
        "\(Int(Date().timeIntervalSince1970 * 1_000_000))-\(UUID().uuidString.prefix(8).lowercased())"
    }

    init(
        providerType: SyncProviderType,
        webdavUrl: String,
        webdavUsername: String,
        webdavPassword: String,
        webdavPath: String,
        presignedDownloadUrl: String,
        presignedUploadUrl: String,
        objectStorageAccessKey: String,
        objectStorageSecretKey: String,
        objectStorageBucket: String,
        objectStorageEndpoint: String,
        objectStorageAppId: String,
        objectStorageCustomUrl: String,
        objectStorageObjectKey: String,
        autoSyncEnabled: Bool,
        autoSyncIntervalMinutes: Int,
        autoSyncIntervalValue: Int,
        autoSyncIntervalUnit: SyncIntervalUnit,
        autoSyncOnUnlock: Bool,
        conflictStrategy: SyncSettingsConflictStrategy,
        syncMasterKey: Bool,
        deviceId: String,
        lastSyncRevision: Int,
        lastSyncAt: Date?,
        lastSyncStatus: String?,
        lastSyncMessage: String?,
        lastRemoteFingerprint: String?,
        hasLocalChanges: Bool,
        logs: [SyncLogEntry]
    ) {
        self.providerType = providerType
        self.webdavUrl = webdavUrl
        self.webdavUsername = webdavUsername
        self.webdavPassword = webdavPassword
        self.webdavPath = webdavPath
        self.presignedDownloadUrl = presignedDownloadUrl
        self.presignedUploadUrl = presignedUploadUrl
        self.objectStorageAccessKey = objectStorageAccessKey
        self.objectStorageSecretKey = objectStorageSecretKey
        self.objectStorageBucket = objectStorageBucket
        self.objectStorageEndpoint = objectStorageEndpoint
        self.objectStorageAppId = objectStorageAppId
        self.objectStorageCustomUrl = objectStorageCustomUrl
        self.objectStorageObjectKey = objectStorageObjectKey
        self.autoSyncEnabled = autoSyncEnabled
        self.autoSyncIntervalMinutes = autoSyncIntervalMinutes
        self.autoSyncIntervalValue = autoSyncIntervalValue
        self.autoSyncIntervalUnit = autoSyncIntervalUnit
        self.autoSyncOnUnlock = autoSyncOnUnlock
        self.conflictStrategy = conflictStrategy
        self.syncMasterKey = syncMasterKey
        self.deviceId = deviceId
        self.lastSyncRevision = lastSyncRevision
        self.lastSyncAt = lastSyncAt
        self.lastSyncStatus = lastSyncStatus
        self.lastSyncMessage = lastSyncMessage
        self.lastRemoteFingerprint = lastRemoteFingerprint
        self.hasLocalChanges = hasLocalChanges
        self.logs = logs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults(deviceId: "")
        providerType = Self.decodeEnum(
            SyncProviderType.self,
            from: container,
            forKey: .providerType,
            defaultValue: defaults.providerType
        )
        webdavUrl = try container.decodeIfPresent(String.self, forKey: .webdavUrl) ?? defaults.webdavUrl
        webdavUsername = try container.decodeIfPresent(String.self, forKey: .webdavUsername) ?? defaults.webdavUsername
        webdavPassword = try container.decodeIfPresent(String.self, forKey: .webdavPassword) ?? defaults.webdavPassword
        webdavPath = try container.decodeIfPresent(String.self, forKey: .webdavPath) ?? defaults.webdavPath
        presignedDownloadUrl = try container.decodeIfPresent(String.self, forKey: .presignedDownloadUrl) ?? defaults.presignedDownloadUrl
        presignedUploadUrl = try container.decodeIfPresent(String.self, forKey: .presignedUploadUrl) ?? defaults.presignedUploadUrl
        objectStorageAccessKey = try Self.decodeFirstPresentString(
            from: container,
            keys: [.objectStorageAccessKey, .ak, .accessKey],
            defaultValue: defaults.objectStorageAccessKey
        )
        objectStorageSecretKey = try Self.decodeFirstPresentString(
            from: container,
            keys: [.objectStorageSecretKey, .sk, .secretKey],
            defaultValue: defaults.objectStorageSecretKey
        )
        objectStorageBucket = try Self.decodeFirstPresentString(
            from: container,
            keys: [.objectStorageBucket, .bucket],
            defaultValue: defaults.objectStorageBucket
        )
        objectStorageEndpoint = try Self.decodeFirstPresentString(
            from: container,
            keys: [.objectStorageEndpoint, .endpoint],
            defaultValue: defaults.objectStorageEndpoint
        )
        objectStorageAppId = try Self.decodeFirstPresentString(
            from: container,
            keys: [.objectStorageAppId, .appid, .appId],
            defaultValue: defaults.objectStorageAppId
        )
        objectStorageCustomUrl = try Self.decodeFirstPresentString(
            from: container,
            keys: [.objectStorageCustomUrl, .customUrl],
            defaultValue: defaults.objectStorageCustomUrl
        )
        objectStorageObjectKey = try Self.decodeFirstPresentString(
            from: container,
            keys: [.objectStorageObjectKey, .objectKey],
            defaultValue: defaults.objectStorageObjectKey
        )
        autoSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoSyncEnabled) ?? defaults.autoSyncEnabled
        autoSyncIntervalUnit = Self.decodeEnum(
            SyncIntervalUnit.self,
            from: container,
            forKey: .autoSyncIntervalUnit,
            defaultValue: defaults.autoSyncIntervalUnit
        )
        let decodedIntervalValue = try container.decodeIfPresent(Int.self, forKey: .autoSyncIntervalValue)
            ?? container.decodeIfPresent(Int.self, forKey: .autoSyncIntervalMinutes)
            ?? defaults.autoSyncIntervalValue
        autoSyncIntervalValue = max(decodedIntervalValue, 1)
        let decodedIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .autoSyncIntervalMinutes)
            ?? autoSyncIntervalValue.toIntervalMinutes(unit: autoSyncIntervalUnit)
        autoSyncIntervalMinutes = max(decodedIntervalMinutes, 1)
        autoSyncOnUnlock = try container.decodeIfPresent(Bool.self, forKey: .autoSyncOnUnlock) ?? defaults.autoSyncOnUnlock
        conflictStrategy = Self.decodeEnum(
            SyncSettingsConflictStrategy.self,
            from: container,
            forKey: .conflictStrategy,
            defaultValue: defaults.conflictStrategy
        )
        syncMasterKey = try container.decodeIfPresent(Bool.self, forKey: .syncMasterKey) ?? defaults.syncMasterKey
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
        lastSyncRevision = try container.decodeIfPresent(Int.self, forKey: .lastSyncRevision) ?? defaults.lastSyncRevision
        lastSyncAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        lastSyncStatus = try container.decodeIfPresent(String.self, forKey: .lastSyncStatus)
        lastSyncMessage = try container.decodeIfPresent(String.self, forKey: .lastSyncMessage)
        lastRemoteFingerprint = try container.decodeIfPresent(String.self, forKey: .lastRemoteFingerprint)
        hasLocalChanges = try container.decodeIfPresent(Bool.self, forKey: .hasLocalChanges) ?? defaults.hasLocalChanges
        logs = try container.decodeIfPresent([SyncLogEntry].self, forKey: .logs) ?? defaults.logs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerType, forKey: .providerType)
        try container.encode(webdavUrl, forKey: .webdavUrl)
        try container.encode(webdavUsername, forKey: .webdavUsername)
        try container.encode(webdavPassword, forKey: .webdavPassword)
        try container.encode(webdavPath, forKey: .webdavPath)
        try container.encode(presignedDownloadUrl, forKey: .presignedDownloadUrl)
        try container.encode(presignedUploadUrl, forKey: .presignedUploadUrl)
        try container.encode(objectStorageAccessKey, forKey: .objectStorageAccessKey)
        try container.encode(objectStorageSecretKey, forKey: .objectStorageSecretKey)
        try container.encode(objectStorageBucket, forKey: .objectStorageBucket)
        try container.encode(objectStorageEndpoint, forKey: .objectStorageEndpoint)
        try container.encode(objectStorageAppId, forKey: .objectStorageAppId)
        try container.encode(objectStorageCustomUrl, forKey: .objectStorageCustomUrl)
        try container.encode(objectStorageObjectKey, forKey: .objectStorageObjectKey)
        try container.encode(autoSyncEnabled, forKey: .autoSyncEnabled)
        try container.encode(autoSyncIntervalMinutes, forKey: .autoSyncIntervalMinutes)
        try container.encode(autoSyncIntervalValue, forKey: .autoSyncIntervalValue)
        try container.encode(autoSyncIntervalUnit, forKey: .autoSyncIntervalUnit)
        try container.encode(autoSyncOnUnlock, forKey: .autoSyncOnUnlock)
        try container.encode(conflictStrategy, forKey: .conflictStrategy)
        try container.encode(syncMasterKey, forKey: .syncMasterKey)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(lastSyncRevision, forKey: .lastSyncRevision)
        try container.encodeIfPresent(lastSyncAt, forKey: .lastSyncAt)
        try container.encodeIfPresent(lastSyncStatus, forKey: .lastSyncStatus)
        try container.encodeIfPresent(lastSyncMessage, forKey: .lastSyncMessage)
        try container.encodeIfPresent(lastRemoteFingerprint, forKey: .lastRemoteFingerprint)
        try container.encode(hasLocalChanges, forKey: .hasLocalChanges)
        try container.encode(logs, forKey: .logs)
    }

    private static func decodeEnum<T: RawRepresentable>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        defaultValue: T
    ) -> T where T.RawValue == String {
        guard let rawValue = try? container.decodeIfPresent(String.self, forKey: key),
              let decoded = T(rawValue: rawValue) else {
            return defaultValue
        }
        return decoded
    }

    private static func decodeFirstPresentString(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys],
        defaultValue: String
    ) throws -> String {
        for key in keys {
            if let value = try container.decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }
        return defaultValue
    }

    var syncSecrets: SyncSecretBundle {
        SyncSecretBundle(
            webdavPassword: webdavPassword,
            presignedDownloadUrl: presignedDownloadUrl,
            presignedUploadUrl: presignedUploadUrl,
            objectStorageAccessKey: objectStorageAccessKey,
            objectStorageSecretKey: objectStorageSecretKey
        )
    }

    func redactedForPlaintextStorage() -> SyncSettings {
        applyingSecrets(.empty)
    }

    func applyingSecrets(_ secrets: SyncSecretBundle) -> SyncSettings {
        var copy = self
        copy.webdavPassword = secrets.webdavPassword
        copy.presignedDownloadUrl = secrets.presignedDownloadUrl
        copy.presignedUploadUrl = secrets.presignedUploadUrl
        copy.objectStorageAccessKey = secrets.objectStorageAccessKey
        copy.objectStorageSecretKey = secrets.objectStorageSecretKey
        return copy
    }
}

extension Int {
    func toIntervalMinutes(unit: SyncIntervalUnit) -> Int {
        switch unit {
        case .seconds:
            Swift.max((Swift.max(self, 1) + 59) / 60, 1)
        case .minutes:
            Swift.max(self, 1)
        }
    }
}

struct SyncSecretBundle: Codable, Equatable, Sendable {
    var webdavPassword: String = ""
    var presignedDownloadUrl: String = ""
    var presignedUploadUrl: String = ""
    var objectStorageAccessKey: String = ""
    var objectStorageSecretKey: String = ""

    static let empty = SyncSecretBundle()

    var isEmpty: Bool {
        webdavPassword.isEmpty &&
            presignedDownloadUrl.isEmpty &&
            presignedUploadUrl.isEmpty &&
            objectStorageAccessKey.isEmpty &&
            objectStorageSecretKey.isEmpty
    }
}

struct SyncClientFactory: Sendable {
    func makeClient(
        settings: SyncSettings,
        transport: RemoteSyncHTTPTransport = URLSessionRemoteSyncTransport()
    ) -> RemoteSyncClient? {
        switch settings.providerType {
        case .none:
            return nil
        case .webdav, .nasWebdav:
            guard !settings.webdavUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !settings.webdavPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return WebDavSyncClient(
                baseUrl: settings.webdavUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                remotePath: settings.webdavPath.trimmingCharacters(in: .whitespacesAndNewlines),
                username: settings.webdavUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                password: settings.webdavPassword.trimmingCharacters(in: .whitespacesAndNewlines),
                transport: transport
            )
        case .s3Presigned:
            guard !settings.presignedUploadUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return PresignedUrlSyncClient(
                downloadUrl: settings.presignedDownloadUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                uploadUrl: settings.presignedUploadUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                transport: transport
            )
        case .tencentCos:
            guard let config = ObjectStorageSyncClientConfiguration.tencentCos(settings: settings) else {
                return nil
            }
            return ObjectStorageSyncClient(configuration: config, transport: transport)
        case .aliyunOss:
            guard let config = ObjectStorageSyncClientConfiguration.aliyunOss(settings: settings) else {
                return nil
            }
            return ObjectStorageSyncClient(configuration: config, transport: transport)
        }
    }
}
