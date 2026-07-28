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
        return try restoreBackup(at: backupURL)
    }

    func restoreBackup(named fileName: String) throws -> URL {
        let sanitizedName = URL(fileURLWithPath: fileName).lastPathComponent
        let backupURL = try backupsDirectoryURL.appendingPathComponent(sanitizedName)
        guard fileManager.fileExists(atPath: backupURL.path),
              sanitizedName.range(of: Self.backupNamePattern, options: .regularExpression) != nil else {
            throw FileVaultRepositoryError.backupMissing
        }
        return try restoreBackup(at: backupURL)
    }

    private func restoreBackup(at backupURL: URL) throws -> URL {
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
        let export = try makeSnapshotExport(snapshot, at: date)
        let exportURL = try exportsDirectoryURL.appendingPathComponent(export.fileName)
        let data = export.data
        try data.write(to: exportURL, options: [.atomic])
        return exportURL
    }

    func makeSnapshotExport(_ snapshot: VaultSnapshot, at date: Date = Date()) throws -> VaultExportFile {
        VaultExportFile(
            fileName: "vault-export-\(Self.backupTimestamp.string(from: date)).json",
            data: try encodeSnapshot(snapshot)
        )
    }

    func saveEntryExport(
        _ entry: VaultEntry,
        selectedFieldIDs: Set<String>? = nil,
        categoryTemplates: [CategoryTemplate] = [],
        at date: Date = Date()
    ) throws -> URL {
        let export = try makeEntryExport(
            entry,
            selectedFieldIDs: selectedFieldIDs,
            categoryTemplates: categoryTemplates,
            at: date
        )
        let exportURL = try exportsDirectoryURL.appendingPathComponent(export.fileName)
        try export.data.write(to: exportURL, options: [.atomic])
        return exportURL
    }

    func makeEntryExport(
        _ entry: VaultEntry,
        selectedFieldIDs: Set<String>? = nil,
        categoryTemplates: [CategoryTemplate] = [],
        at date: Date = Date()
    ) throws -> VaultExportFile {
        let exportedEntry = selectedFieldIDs.map { entry.keepingExportFields($0) } ?? entry
        let sourceTemplates = categoryTemplates.filter {
            $0.category.caseInsensitiveCompare(entry.payload.category) == .orderedSame
        }
        let export = ScopedVaultExport(
            scope: .item,
            exportedAt: date,
            item: exportedEntry,
            category: nil,
            items: nil,
            categoryTemplates: sourceTemplates
        )
        return VaultExportFile(
            fileName: "entry-export-\(entry.safeExportName)-\(Self.backupTimestamp.string(from: date)).json",
            data: try encoder.encode(export)
        )
    }

    func saveCategoryExport(
        category: String,
        entries: [VaultEntry],
        categoryTemplates: [CategoryTemplate] = [],
        at date: Date = Date()
    ) throws -> URL {
        let export = try makeCategoryExport(
            category: category,
            entries: entries,
            categoryTemplates: categoryTemplates,
            at: date
        )
        let exportURL = try exportsDirectoryURL.appendingPathComponent(export.fileName)
        try export.data.write(to: exportURL, options: [.atomic])
        return exportURL
    }

    func makeCategoryExport(
        category: String,
        entries: [VaultEntry],
        categoryTemplates: [CategoryTemplate] = [],
        at date: Date = Date()
    ) throws -> VaultExportFile {
        let sourceTemplates = categoryTemplates.filter {
            $0.category.caseInsensitiveCompare(category) == .orderedSame
        }
        let export = ScopedVaultExport(
            scope: .category,
            exportedAt: date,
            item: nil,
            category: category,
            items: entries,
            categoryTemplates: sourceTemplates
        )
        return VaultExportFile(
            fileName: "category-export-\(category.safeExportName)-\(Self.backupTimestamp.string(from: date)).json",
            data: try encoder.encode(export)
        )
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
        return try decodeScopedExport(data)
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

    func decodeScopedExport(_ data: Data) throws -> ScopedVaultExport {
        try decoder.decode(ScopedVaultExport.self, from: data)
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

struct VaultExportFile: Equatable {
    var fileName: String
    var data: Data
}
