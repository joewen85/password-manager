import Foundation

struct FileVaultRepository {
    private let fileManager: FileManager
    private let baseDirectory: URL?
    private let protectedWrites: Bool
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, baseDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
        protectedWrites = baseDirectory == nil
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    var vaultURL: URL {
        get throws {
            try baseDirectoryURL().appendingPathComponent("vault.json")
        }
    }

    var backupsDirectoryURL: URL {
        get throws {
            try directory(named: "backups")
        }
    }

    var exportsDirectoryURL: URL {
        get throws {
            try directory(named: "exports")
        }
    }

    var importsDirectoryURL: URL {
        get throws {
            try directory(named: "imports")
        }
    }

    private func baseDirectoryURL() throws -> URL {
        let directory: URL
        if let baseDirectory {
            directory = baseDirectory
        } else {
            directory = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("PasswordManagerNative", isDirectory: true)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func directory(named name: String) throws -> URL {
        let directory = try baseDirectoryURL().appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func createBackup(at date: Date = Date()) throws -> URL {
        let sourceURL = try vaultURL
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw FileVaultRepositoryError.vaultMissing
        }
        let backupURL = try backupsDirectoryURL
            .appendingPathComponent("vault-\(Self.backupTimestamp.string(from: date)).json")
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.copyItem(at: sourceURL, to: backupURL)
        try pruneBackups()
        return backupURL
    }

    func restoreLatestBackup() throws -> URL {
        guard let backupURL = try listBackups().first else {
            throw FileVaultRepositoryError.backupMissing
        }
        let destinationURL = try vaultURL
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: backupURL, to: destinationURL)
        return backupURL
    }

    func listBackups() throws -> [URL] {
        let directoryURL = try backupsDirectoryURL
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        return urls
            .filter { $0.lastPathComponent.range(of: Self.backupNamePattern, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func saveSnapshotExport(_ snapshot: VaultSnapshot, at date: Date = Date()) throws -> URL {
        let exportURL = try exportsDirectoryURL
            .appendingPathComponent("vault-export-\(Self.backupTimestamp.string(from: date)).json")
        let data = try encodeSnapshot(snapshot)
        try data.write(to: exportURL, options: [.atomic])
        return exportURL
    }

    func saveEntryExport(
        _ entry: VaultEntry,
        selectedFieldIDs: Set<String>? = nil,
        at date: Date = Date()
    ) throws -> URL {
        let exportedEntry = selectedFieldIDs.map { entry.keepingExportFields($0) } ?? entry
        let export = ScopedVaultExport(
            scope: .item,
            exportedAt: date,
            item: exportedEntry,
            category: nil,
            items: nil
        )
        let exportURL = try exportsDirectoryURL
            .appendingPathComponent("entry-export-\(entry.safeExportName)-\(Self.backupTimestamp.string(from: date)).json")
        try encoder.encode(export).write(to: exportURL, options: [.atomic])
        return exportURL
    }

    func saveCategoryExport(category: String, entries: [VaultEntry], at date: Date = Date()) throws -> URL {
        let export = ScopedVaultExport(
            scope: .category,
            exportedAt: date,
            item: nil,
            category: category,
            items: entries
        )
        let exportURL = try exportsDirectoryURL
            .appendingPathComponent("category-export-\(category.safeExportName)-\(Self.backupTimestamp.string(from: date)).json")
        try encoder.encode(export).write(to: exportURL, options: [.atomic])
        return exportURL
    }

    func loadSnapshotImport(named fileName: String) throws -> VaultSnapshot {
        let sanitizedName = URL(fileURLWithPath: fileName).lastPathComponent
        let importURL = try importsDirectoryURL.appendingPathComponent(sanitizedName)
        let data = try Data(contentsOf: importURL)
        return try decodeSnapshot(data)
    }

    func loadScopedImport(named fileName: String) throws -> ScopedVaultExport {
        let sanitizedName = URL(fileURLWithPath: fileName).lastPathComponent
        let importURL = try importsDirectoryURL.appendingPathComponent(sanitizedName)
        let data = try Data(contentsOf: importURL)
        return try decoder.decode(ScopedVaultExport.self, from: data)
    }

    private static let backupTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static let backupRetentionCount = 5
    private static let backupNamePattern = #"^vault-\d{8}-\d{6}\.json$"#

    func loadEnvelope() throws -> VaultPersistenceEnvelope? {
        let url = try vaultURL
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(VaultPersistenceEnvelope.self, from: data)
    }

    func saveEnvelope(_ envelope: VaultPersistenceEnvelope) throws {
        let url = try vaultURL
        let data = try encoder.encode(envelope)
        let options: Data.WritingOptions = protectedWrites ? [.atomic, .completeFileProtection] : [.atomic]
        try data.write(to: url, options: options)
    }

    func encodeSnapshot(_ snapshot: VaultSnapshot) throws -> Data {
        try encoder.encode(snapshot)
    }

    func decodeSnapshot(_ data: Data) throws -> VaultSnapshot {
        try decoder.decode(VaultSnapshot.self, from: data)
    }

    private func pruneBackups() throws {
        let backups = try listBackups()
        for backupURL in backups.dropFirst(Self.backupRetentionCount) {
            try fileManager.removeItem(at: backupURL)
        }
    }
}

enum FileVaultRepositoryError: Error {
    case vaultMissing
    case backupMissing
}
