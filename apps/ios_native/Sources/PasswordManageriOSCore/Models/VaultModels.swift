import Foundation

enum VaultEntryType: String, CaseIterable, Codable, Identifiable, Sendable {
    case credential
    case server
    case service

    var id: String { rawValue }

    var title: String {
        switch self {
        case .credential: "Credential"
        case .server: "Server"
        case .service: "Service"
        }
    }

    var systemImage: String {
        switch self {
        case .credential: "key"
        case .server: "server.rack"
        case .service: "network"
        }
    }
}

struct CredentialPayload: Codable, Equatable, Sendable {
    var username: String = ""
    var password: String = ""
    var token: String = ""
    var appId: String = ""
    var accessKey: String = ""
    var secretKey: String = ""
    var notes: String = ""
    var tags: [String] = []
    var category: String = ""
}

struct ServerPayload: Codable, Equatable, Sendable {
    var name: String = ""
    var ipAddress: String = ""
    var port: String = ""
    var username: String = ""
    var password: String = ""
    var basicConfig: String = ""
    var operatingSystem: String = ""
    var location: String = ""
    var notes: String = ""
    var tags: [String] = []
    var accountId: String?
    var category: String = ""
}

struct ServiceAccount: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var username: String = ""
    var password: String = ""
    var note: String = ""

    private enum CodingKeys: String, CodingKey {
        case username
        case password
        case note
    }

    init(
        id: UUID = UUID(),
        username: String = "",
        password: String = "",
        note: String = ""
    ) {
        self.id = id
        self.username = username
        self.password = password
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(username, forKey: .username)
        try container.encode(password, forKey: .password)
        try container.encode(note, forKey: .note)
    }
}

struct ServicePayload: Codable, Equatable, Sendable {
    var name: String = ""
    var connectionAddress: String = ""
    var connectionPort: String = ""
    var accountId: String?
    var serverIds: [String] = []
    var accounts: [ServiceAccount] = []
    var notes: String = ""
    var tags: [String] = []
    var category: String = ""
}

enum VaultPayload: Codable, Equatable, Sendable {
    case credential(CredentialPayload)
    case server(ServerPayload)
    case service(ServicePayload)

    private enum CodingKeys: String, CodingKey {
        case credential
        case server
        case service
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let payload = try container.decodeIfPresent(CredentialPayload.self, forKey: .credential) {
            self = .credential(payload)
            return
        }
        if let payload = try container.decodeIfPresent(ServerPayload.self, forKey: .server) {
            self = .server(payload)
            return
        }
        if let payload = try container.decodeIfPresent(ServicePayload.self, forKey: .service) {
            self = .service(payload)
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected credential, server, or service payload."
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .credential(let payload):
            try container.encode(payload, forKey: .credential)
        case .server(let payload):
            try container.encode(payload, forKey: .server)
        case .service(let payload):
            try container.encode(payload, forKey: .service)
        }
    }

    var category: String {
        switch self {
        case .credential(let payload): payload.category
        case .server(let payload): payload.category
        case .service(let payload): payload.category
        }
    }

    var tags: [String] {
        switch self {
        case .credential(let payload): payload.tags
        case .server(let payload): payload.tags
        case .service(let payload): payload.tags
        }
    }
}

struct VaultEntry: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var label: String
    var type: VaultEntryType
    var payload: VaultPayload
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var isDeleted: Bool = false
    var deletedAt: Date?
    var version: [String: Int] = [:]
    var updatedBy: String = "macos-native"
}

struct MasterKeyRecord: Codable, Equatable, Sendable {
    var saltBase64: String
    var iterations: Int
    var verifierBase64: String
    var metadataSaltBase64: String?
    var metadataIterations: Int?
}

struct EncryptedPayloadRecord: Codable, Equatable, Sendable {
    var ciphertext: String
    var nonce: String
    var mac: String
    var version: Int
}

struct VaultPersistenceEnvelope: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var masterKeyRecord: MasterKeyRecord?
    var encryptedVault: EncryptedPayloadRecord?
    var updatedAt: Date = Date()
}

struct VaultSnapshot: Codable, Equatable, Sendable {
    var entries: [VaultEntry] = []
    var categories: [String] = []
    var tags: [String] = []
    var security: SecuritySettings = SecuritySettings()
    var syncStatus: String = "Not configured"
    var lastBackupStatus: String = "No backup has run"
    var updatedAt: Date = Date()
}

struct SecuritySettings: Codable, Equatable, Sendable {
    var requireTotp = false
    var totpSecret = ""
}

enum ScopedExportScope: String, Codable, Sendable {
    case item
    case category
}

struct ScopedVaultExport: Codable, Equatable, Sendable {
    var version = 1
    var scope: ScopedExportScope
    var exportedAt: Date
    var item: VaultEntry?
    var category: String?
    var items: [VaultEntry]?
}

enum ImportConflictStrategy: String, CaseIterable, Identifiable, Sendable {
    case keepCopy
    case overwrite
    case skip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepCopy: "Keep Copy"
        case .overwrite: "Overwrite"
        case .skip: "Skip"
        }
    }
}

enum VaultFilter: Hashable, Sendable {
    case all
    case type(VaultEntryType)
    case category(String)
    case tag(String)

    var title: String {
        switch self {
        case .all: "All Items"
        case .type(let type): type.title
        case .category(let category): category
        case .tag(let tag): "#\(tag)"
        }
    }
}

extension String {
    var safeExportName: String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
            .union(.whitespacesAndNewlines)
        let parts = components(separatedBy: invalid).filter { !$0.isEmpty }
        return parts.joined(separator: "_").isEmpty ? "untitled" : parts.joined(separator: "_")
    }
}

extension VaultEntry {
    var safeExportName: String {
        label.safeExportName
    }

    var importMatchKey: String {
        "\(type.rawValue)|\(label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(payload.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    func copyForImport(id: UUID, updatedAt: Date) -> VaultEntry {
        VaultEntry(
            id: id,
            label: label,
            type: type,
            payload: payload,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isDeleted: false,
            deletedAt: nil,
            version: version,
            updatedBy: updatedBy
        )
    }
}
