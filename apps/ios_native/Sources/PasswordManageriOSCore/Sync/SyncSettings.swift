import Foundation

enum SyncProviderType: String, CaseIterable, Codable, Sendable {
    case none
    case webdav
    case s3Presigned
    case nasWebdav

    var title: String {
        switch self {
        case .none:
            "None"
        case .webdav:
            "WebDAV"
        case .s3Presigned:
            "S3 Presigned URL"
        case .nasWebdav:
            "NAS WebDAV"
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
            "Remote Wins"
        case .localWins:
            "Local Wins"
        case .keepBoth:
            "Keep Both"
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
            "Seconds"
        case .minutes:
            "Minutes"
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
        autoSyncIntervalValue = Swift.max(decodedIntervalValue, 1)
        let decodedIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .autoSyncIntervalMinutes)
            ?? autoSyncIntervalValue.toIntervalMinutes(unit: autoSyncIntervalUnit)
        autoSyncIntervalMinutes = Swift.max(decodedIntervalMinutes, 1)
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

    var syncSecrets: SyncSecretBundle {
        SyncSecretBundle(
            webdavPassword: webdavPassword,
            presignedDownloadUrl: presignedDownloadUrl,
            presignedUploadUrl: presignedUploadUrl
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

    static let empty = SyncSecretBundle()

    var isEmpty: Bool {
        webdavPassword.isEmpty &&
            presignedDownloadUrl.isEmpty &&
            presignedUploadUrl.isEmpty
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
        }
    }
}
