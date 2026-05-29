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

struct CustomField: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    var value: String = ""

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case value
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        value: String = ""
    ) {
        self.id = id
        self.name = name
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.uuidString.lowercased(), forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(value, forKey: .value)
    }
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
    var customFields: [CustomField] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var isDeleted: Bool = false
    var deletedAt: Date?
    var version: [String: Int] = [:]
    var updatedBy: String = "macos-native"

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case type
        case payload
        case customFields
        case createdAt
        case updatedAt
        case isDeleted
        case deletedAt
        case version
        case updatedBy
    }

    init(
        id: UUID = UUID(),
        label: String,
        type: VaultEntryType,
        payload: VaultPayload,
        customFields: [CustomField] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        version: [String: Int] = [:],
        updatedBy: String = "ios-native"
    ) {
        self.id = id
        self.label = label
        self.type = type
        self.payload = payload
        self.customFields = customFields
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.version = version
        self.updatedBy = updatedBy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try container.decode(String.self, forKey: .label)
        type = try container.decode(VaultEntryType.self, forKey: .type)
        payload = try container.decode(VaultPayload.self, forKey: .payload)
        customFields = try container.decodeIfPresent([CustomField].self, forKey: .customFields) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        version = try container.decodeIfPresent([String: Int].self, forKey: .version) ?? [:]
        updatedBy = try container.decodeIfPresent(String.self, forKey: .updatedBy) ?? "ios-native"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.uuidString.lowercased(), forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(type, forKey: .type)
        try container.encode(payload, forKey: .payload)
        try container.encode(customFields, forKey: .customFields)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(isDeleted, forKey: .isDeleted)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try container.encode(version, forKey: .version)
        try container.encode(updatedBy, forKey: .updatedBy)
    }
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

struct EntryExportField: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
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
            customFields: customFields,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isDeleted: false,
            deletedAt: nil,
            version: version,
            updatedBy: updatedBy
        )
    }

    var exportFields: [EntryExportField] {
        var fields = [
            EntryExportField(id: "label", title: "Label"),
            EntryExportField(id: "category", title: "Category"),
            EntryExportField(id: "tags", title: "Tags")
        ]

        switch payload {
        case .credential:
            fields += [
                EntryExportField(id: "credential.username", title: "Username"),
                EntryExportField(id: "credential.password", title: "Password"),
                EntryExportField(id: "credential.token", title: "Token"),
                EntryExportField(id: "credential.appId", title: "App ID"),
                EntryExportField(id: "credential.accessKey", title: "Access Key"),
                EntryExportField(id: "credential.secretKey", title: "Secret Key"),
                EntryExportField(id: "credential.notes", title: "Notes")
            ]
        case .server:
            fields += [
                EntryExportField(id: "server.name", title: "Name"),
                EntryExportField(id: "server.ipAddress", title: "IP Address"),
                EntryExportField(id: "server.port", title: "Port"),
                EntryExportField(id: "server.username", title: "Username"),
                EntryExportField(id: "server.password", title: "Password"),
                EntryExportField(id: "server.basicConfig", title: "Config"),
                EntryExportField(id: "server.operatingSystem", title: "OS"),
                EntryExportField(id: "server.location", title: "Location"),
                EntryExportField(id: "server.notes", title: "Notes")
            ]
        case .service:
            fields += [
                EntryExportField(id: "service.name", title: "Name"),
                EntryExportField(id: "service.connectionAddress", title: "Address"),
                EntryExportField(id: "service.connectionPort", title: "Port"),
                EntryExportField(id: "service.accountId", title: "Account ID"),
                EntryExportField(id: "service.serverIds", title: "Servers"),
                EntryExportField(id: "service.accounts", title: "Accounts"),
                EntryExportField(id: "service.notes", title: "Notes")
            ]
        }

        fields += customFields.map {
            EntryExportField(
                id: "custom.\($0.id.uuidString)",
                title: $0.name.isEmpty ? "Custom Field" : $0.name
            )
        }
        return fields
    }

    func keepingExportFields(_ selectedFieldIDs: Set<String>) -> VaultEntry {
        let selectedCustomIDs = Set(
            selectedFieldIDs.compactMap { id -> UUID? in
                guard id.hasPrefix("custom.") else { return nil }
                return UUID(uuidString: String(id.dropFirst("custom.".count)))
            }
        )
        return VaultEntry(
            id: id,
            label: selectedFieldIDs.contains("label") ? label : "",
            type: type,
            payload: payload.keepingExportFields(selectedFieldIDs),
            customFields: customFields.filter { selectedCustomIDs.contains($0.id) },
            createdAt: createdAt,
            updatedAt: updatedAt,
            isDeleted: isDeleted,
            deletedAt: deletedAt,
            version: version,
            updatedBy: updatedBy
        )
    }
}

private extension VaultPayload {
    func keepingExportFields(_ selectedFieldIDs: Set<String>) -> VaultPayload {
        switch self {
        case .credential(var credential):
            if !selectedFieldIDs.contains("category") { credential.category = "" }
            if !selectedFieldIDs.contains("tags") { credential.tags = [] }
            if !selectedFieldIDs.contains("credential.username") { credential.username = "" }
            if !selectedFieldIDs.contains("credential.password") { credential.password = "" }
            if !selectedFieldIDs.contains("credential.token") { credential.token = "" }
            if !selectedFieldIDs.contains("credential.appId") { credential.appId = "" }
            if !selectedFieldIDs.contains("credential.accessKey") { credential.accessKey = "" }
            if !selectedFieldIDs.contains("credential.secretKey") { credential.secretKey = "" }
            if !selectedFieldIDs.contains("credential.notes") { credential.notes = "" }
            return .credential(credential)
        case .server(var server):
            if !selectedFieldIDs.contains("category") { server.category = "" }
            if !selectedFieldIDs.contains("tags") { server.tags = [] }
            if !selectedFieldIDs.contains("server.name") { server.name = "" }
            if !selectedFieldIDs.contains("server.ipAddress") { server.ipAddress = "" }
            if !selectedFieldIDs.contains("server.port") { server.port = "" }
            if !selectedFieldIDs.contains("server.username") { server.username = "" }
            if !selectedFieldIDs.contains("server.password") { server.password = "" }
            if !selectedFieldIDs.contains("server.basicConfig") { server.basicConfig = "" }
            if !selectedFieldIDs.contains("server.operatingSystem") { server.operatingSystem = "" }
            if !selectedFieldIDs.contains("server.location") { server.location = "" }
            if !selectedFieldIDs.contains("server.notes") { server.notes = "" }
            return .server(server)
        case .service(var service):
            if !selectedFieldIDs.contains("category") { service.category = "" }
            if !selectedFieldIDs.contains("tags") { service.tags = [] }
            if !selectedFieldIDs.contains("service.name") { service.name = "" }
            if !selectedFieldIDs.contains("service.connectionAddress") { service.connectionAddress = "" }
            if !selectedFieldIDs.contains("service.connectionPort") { service.connectionPort = "" }
            if !selectedFieldIDs.contains("service.accountId") { service.accountId = nil }
            if !selectedFieldIDs.contains("service.serverIds") { service.serverIds = [] }
            if !selectedFieldIDs.contains("service.accounts") { service.accounts = [] }
            if !selectedFieldIDs.contains("service.notes") { service.notes = "" }
            return .service(service)
        }
    }
}
