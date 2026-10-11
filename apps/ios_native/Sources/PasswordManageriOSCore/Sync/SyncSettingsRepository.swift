import Foundation

struct SyncSettingsRepository {
    private let fileManager: FileManager
    private let settingsURL: URL
    private let secretStore: SyncSecretStore
    private let protectedWrites: Bool
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil,
        secretStore: SyncSecretStore = KeychainSyncSecretStore()
    ) throws {
        self.fileManager = fileManager
        self.secretStore = secretStore
        let directory: URL
        if let baseDirectory {
            directory = baseDirectory
            protectedWrites = false
        } else {
            directory = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("PasswordManagerNative", isDirectory: true)
            protectedWrites = true
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        settingsURL = directory.appendingPathComponent("sync_settings.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> SyncSettings {
        let redacted: SyncSettings
        if fileManager.fileExists(atPath: settingsURL.path) {
            let data = try Data(contentsOf: settingsURL)
            redacted = try decoder.decode(SyncSettings.self, from: data)
        } else {
            redacted = .defaults()
        }
        let secrets = try secretStore.load(deviceId: redacted.deviceId)
        return redacted.applyingSecrets(secrets)
    }

    func save(_ settings: SyncSettings) throws {
        let normalized = ensureDeviceId(settings)
        try secretStore.save(normalized.syncSecrets, deviceId: normalized.deviceId)
        let data = try encoder.encode(normalized.redactedForPlaintextStorage())
        let options: Data.WritingOptions = protectedWrites ? [.atomic, .completeFileProtection] : [.atomic]
        try data.write(to: settingsURL, options: options)
    }

    func delete() throws {
        let existing = try load()
        try secretStore.delete(deviceId: existing.deviceId)
        if fileManager.fileExists(atPath: settingsURL.path) {
            try fileManager.removeItem(at: settingsURL)
        }
    }

    func rawSettingsFile() throws -> String? {
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            return nil
        }
        return try String(contentsOf: settingsURL, encoding: .utf8)
    }

    private func ensureDeviceId(_ settings: SyncSettings) -> SyncSettings {
        guard settings.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return settings
        }
        var copy = settings
        copy.deviceId = SyncSettings.generateDeviceId()
        return copy
    }
}
