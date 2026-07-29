import Foundation

enum VaultEntryType: String, CaseIterable, Codable, Identifiable, Sendable {
    case credential
    case server
    case service

    var id: String { rawValue }

    var title: String {
        switch self {
        case .credential: L10n.t("Credential")
        case .server: L10n.t("Server")
        case .service: L10n.t("Service")
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
    var accounts: [ServiceAccount] = []
    var token: String = ""
    var appId: String = ""
    var accessKey: String = ""
    var secretKey: String = ""
    var notes: String = ""
    var tags: [String] = []
    var category: String = ""

    private enum CodingKeys: String, CodingKey {
        case username
        case password
        case accounts
        case token
        case appId
        case accessKey
        case accessToken
        case secretKey
        case notes
        case tags
        case category
    }

    init(
        username: String = "",
        password: String = "",
        accounts: [ServiceAccount] = [],
        token: String = "",
        appId: String = "",
        accessKey: String = "",
        secretKey: String = "",
        notes: String = "",
        tags: [String] = [],
        category: String = ""
    ) {
        self.username = username
        self.password = password
        self.accounts = accounts
        self.token = token
        self.appId = appId
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.notes = notes
        self.tags = tags
        self.category = category
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        accounts = try container.decodeIfPresent([ServiceAccount].self, forKey: .accounts) ?? []
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        appId = try container.decodeIfPresent(String.self, forKey: .appId) ?? ""
        accessKey = try container.decodeIfPresent(String.self, forKey: .accessKey)
            ?? container.decodeIfPresent(String.self, forKey: .accessToken)
            ?? ""
        secretKey = try container.decodeIfPresent(String.self, forKey: .secretKey) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(username, forKey: .username)
        try container.encode(password, forKey: .password)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(token, forKey: .token)
        try container.encode(appId, forKey: .appId)
        try container.encode(accessKey, forKey: .accessKey)
        try container.encode(secretKey, forKey: .secretKey)
        try container.encode(notes, forKey: .notes)
        try container.encode(tags, forKey: .tags)
        try container.encode(category, forKey: .category)
    }
}

struct ServerPayload: Codable, Equatable, Sendable {
    var name: String = ""
    var ipAddress: String = ""
    var port: String = ""
    var username: String = ""
    var password: String = ""
    var accounts: [ServiceAccount] = []
    var basicConfig: String = ""
    var operatingSystem: String = ""
    var location: String = ""
    var notes: String = ""
    var tags: [String] = []
    var accountId: String?
    var category: String = ""

    private enum CodingKeys: String, CodingKey {
        case name
        case ipAddress
        case port
        case username
        case password
        case accounts
        case basicConfig
        case operatingSystem
        case location
        case notes
        case tags
        case accountId
        case category
    }

    init(
        name: String = "",
        ipAddress: String = "",
        port: String = "",
        username: String = "",
        password: String = "",
        accounts: [ServiceAccount] = [],
        basicConfig: String = "",
        operatingSystem: String = "",
        location: String = "",
        notes: String = "",
        tags: [String] = [],
        accountId: String? = nil,
        category: String = ""
    ) {
        self.name = name
        self.ipAddress = ipAddress
        self.port = port
        self.username = username
        self.password = password
        self.accounts = accounts
        self.basicConfig = basicConfig
        self.operatingSystem = operatingSystem
        self.location = location
        self.notes = notes
        self.tags = tags
        self.accountId = accountId
        self.category = category
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        ipAddress = try container.decodeIfPresent(String.self, forKey: .ipAddress) ?? ""
        port = try container.decodeIfPresent(String.self, forKey: .port) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        accounts = try container.decodeIfPresent([ServiceAccount].self, forKey: .accounts) ?? []
        basicConfig = try container.decodeIfPresent(String.self, forKey: .basicConfig) ?? ""
        operatingSystem = try container.decodeIfPresent(String.self, forKey: .operatingSystem) ?? ""
        location = try container.decodeIfPresent(String.self, forKey: .location) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
    }
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
    var id: String = UUID().uuidString.lowercased()
    var templateFieldId: String = ""
    var name: String = ""
    var value: String = ""

    private enum CodingKeys: String, CodingKey {
        case id
        case templateFieldId
        case name
        case value
    }

    init(
        id: String = UUID().uuidString.lowercased(),
        templateFieldId: String = "",
        name: String = "",
        value: String = ""
    ) {
        self.id = id
        self.templateFieldId = templateFieldId
        self.name = name
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        id = decodedId.isEmpty ? UUID().uuidString.lowercased() : decodedId
        templateFieldId = try container.decodeIfPresent(String.self, forKey: .templateFieldId) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(templateFieldId, forKey: .templateFieldId)
        try container.encode(name, forKey: .name)
        try container.encode(value, forKey: .value)
    }
}

struct FieldTemplate: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: String
    var name: String
    var valueType: String
    var targetCategory: String

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case valueType
        case targetCategory
    }

    init(
        id: String? = nil,
        name: String,
        valueType: String = "text",
        targetCategory: String = ""
    ) {
        self.name = name
        self.id = id.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString.lowercased()
        self.valueType = valueType
        self.targetCategory = targetCategory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        let decodedId = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        id = decodedId.isEmpty ? Self.stableFieldId(name) : decodedId
        let decodedValueType = try container.decodeIfPresent(String.self, forKey: .valueType) ?? ""
        valueType = decodedValueType.isEmpty ? "text" : decodedValueType
        targetCategory = try container.decodeIfPresent(String.self, forKey: .targetCategory) ?? ""
    }

    static func stableFieldId(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        var previousWasSeparator = false
        for scalar in trimmed.unicodeScalars {
            let value = scalar.value
            let isASCIIAlphaNumeric = (48...57).contains(value)
                || (65...90).contains(value)
                || (97...122).contains(value)
            if isASCIIAlphaNumeric || (0x4e00...0x9fff).contains(value) {
                parts.append(String(scalar).lowercased())
                previousWasSeparator = false
            } else if !previousWasSeparator {
                parts.append("_")
                previousWasSeparator = true
            }
        }
        let normalized = parts.joined().trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if !normalized.isEmpty {
            return "template_\(normalized)"
        }
        guard !trimmed.isEmpty else {
            return "template_empty"
        }
        let hex = trimmed.utf8.map { String(format: "%02x", $0) }.joined()
        return "template_u_\(hex)"
    }
}

struct CategoryTemplate: Codable, Equatable, Hashable, Sendable {
    var category: String
    var fields: [FieldTemplate]

    init(category: String, fields: [FieldTemplate] = Self.defaultCategoryFields()) {
        self.category = category
        self.fields = Self.normalizedFields(fields.isEmpty ? Self.defaultCategoryFields() : fields)
    }

    static func defaultCategoryFields() -> [FieldTemplate] {
        [
            FieldTemplate(id: FieldTemplate.stableFieldId("名称"), name: "名称"),
            FieldTemplate(id: FieldTemplate.stableFieldId("备注"), name: "备注")
        ]
    }

    static func fields(for preset: CategoryTypePreset?, customFieldNames: [String] = []) -> [FieldTemplate] {
        guard let preset else {
            return normalizedFields(defaultCategoryFields() + customFieldNames.map { FieldTemplate(name: $0) })
        }
        return normalizedFields(
            defaultCategoryFields()
                + preset.fields.map { FieldTemplate(name: $0) }
                + customFieldNames.map { FieldTemplate(name: $0) }
        )
    }

    private static func normalizedFields(_ fields: [FieldTemplate]) -> [FieldTemplate] {
        var seen = Set<String>()
        return fields.filter { field in
            let key = field.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !key.isEmpty && seen.insert(key).inserted
        }
    }
}

enum CategoryTypePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case server
    case service
    case account

    var id: String { rawValue }

    var title: String {
        switch self {
        case .server: "服务器"
        case .service: "服务"
        case .account: "账号"
        }
    }

    var fields: [String] {
        switch self {
        case .server: ["IP地址", "端口", "关联账号"]
        case .service: ["服务入口", "关联账号", "关联服务器"]
        case .account: ["入口"]
        }
    }

    static func fromTitle(_ value: String) -> CategoryTypePreset? {
        allCases.first { $0.title == value.trimmingCharacters(in: .whitespacesAndNewlines) }
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
    var id: String = UUID().uuidString.lowercased()
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
        id: String = UUID().uuidString.lowercased(),
        label: String,
        type: VaultEntryType,
        payload: VaultPayload,
        customFields: [CustomField] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        version: [String: Int] = [:],
        updatedBy: String = "macos-native"
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
        let decodedId = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        id = decodedId.isEmpty ? UUID().uuidString.lowercased() : decodedId
        label = try container.decode(String.self, forKey: .label)
        type = try container.decode(VaultEntryType.self, forKey: .type)
        payload = try container.decode(VaultPayload.self, forKey: .payload)
        customFields = try container.decodeIfPresent([CustomField].self, forKey: .customFields) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        version = try container.decodeIfPresent([String: Int].self, forKey: .version) ?? [:]
        updatedBy = try container.decodeIfPresent(String.self, forKey: .updatedBy) ?? "macos-native"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
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

struct CategorySyncState: Codable, Equatable, Sendable {
    var name: String
    var isDeleted = false
    var updatedAt: Date = Date()
    var version: [String: Int] = [:]
    var updatedBy = ""
}

struct VaultSnapshot: Codable, Equatable, Sendable {
    var entries: [VaultEntry] = []
    var categories: [String] = []
    var categoryTemplates: [CategoryTemplate] = []
    var categoryStates: [CategorySyncState] = []
    var tags: [String] = []
    var security: SecuritySettings = SecuritySettings()
    var syncStatus: String = "Not configured"
    var lastBackupStatus: String = "No backup has run"
    var updatedAt: Date = Date()

    private enum CodingKeys: String, CodingKey {
        case entries
        case categories
        case categoryTemplates
        case categoryStates
        case tags
        case security
        case syncStatus
        case backupStatus
        case lastBackupStatus
        case updatedAt
    }

    init(
        entries: [VaultEntry] = [],
        categories: [String] = [],
        categoryTemplates: [CategoryTemplate] = [],
        categoryStates: [CategorySyncState] = [],
        tags: [String] = [],
        security: SecuritySettings = SecuritySettings(),
        syncStatus: String = "Not configured",
        lastBackupStatus: String = "No backup has run",
        updatedAt: Date = Date()
    ) {
        self.entries = entries
        self.categories = categories
        self.categoryTemplates = categoryTemplates
        self.categoryStates = categoryStates
        self.tags = tags
        self.security = security
        self.syncStatus = syncStatus
        self.lastBackupStatus = lastBackupStatus
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([VaultEntry].self, forKey: .entries) ?? []
        categories = try container.decodeIfPresent([String].self, forKey: .categories) ?? []
        let decodedTemplates = try container.decodeIfPresent([CategoryTemplate].self, forKey: .categoryTemplates) ?? []
        categoryTemplates = decodedTemplates.isEmpty
            ? categories.map { CategoryTemplate(category: $0) }
            : decodedTemplates
        categoryStates = try container.decodeIfPresent([CategorySyncState].self, forKey: .categoryStates) ?? []
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        security = try container.decodeIfPresent(SecuritySettings.self, forKey: .security) ?? SecuritySettings()
        syncStatus = try container.decodeIfPresent(String.self, forKey: .syncStatus) ?? "Not configured"
        lastBackupStatus = try container.decodeIfPresent(String.self, forKey: .lastBackupStatus)
            ?? (try container.decodeIfPresent(String.self, forKey: .backupStatus))
            ?? "No backup has run"
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encode(categories, forKey: .categories)
        try container.encode(categoryTemplates, forKey: .categoryTemplates)
        try container.encode(categoryStates, forKey: .categoryStates)
        try container.encode(tags, forKey: .tags)
        try container.encode(security, forKey: .security)
        try container.encode(syncStatus, forKey: .syncStatus)
        try container.encode(lastBackupStatus, forKey: .backupStatus)
        try container.encode(lastBackupStatus, forKey: .lastBackupStatus)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
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
    var version: Int
    var scope: ScopedExportScope
    var exportedAt: Date
    var item: VaultEntry?
    var category: String?
    var items: [VaultEntry]?
    var categoryTemplates: [CategoryTemplate]

    private enum CodingKeys: String, CodingKey {
        case version
        case scope
        case exportedAt
        case item
        case category
        case items
        case categoryTemplates
    }

    init(
        version: Int = 2,
        scope: ScopedExportScope,
        exportedAt: Date,
        item: VaultEntry?,
        category: String?,
        items: [VaultEntry]?,
        categoryTemplates: [CategoryTemplate] = []
    ) {
        self.version = version
        self.scope = scope
        self.exportedAt = exportedAt
        self.item = item
        self.category = category
        self.items = items
        self.categoryTemplates = categoryTemplates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        scope = try container.decode(ScopedExportScope.self, forKey: .scope)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        item = try container.decodeIfPresent(VaultEntry.self, forKey: .item)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        items = try container.decodeIfPresent([VaultEntry].self, forKey: .items)
        categoryTemplates = try container.decodeIfPresent([CategoryTemplate].self, forKey: .categoryTemplates) ?? []
    }
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
        case .keepCopy: L10n.t("Keep Copy")
        case .overwrite: L10n.t("Overwrite")
        case .skip: L10n.t("Skip")
        }
    }
}

enum VaultFilter: Hashable, Sendable {
    case all
    case category(String)
    case tag(String)

    var title: String {
        switch self {
        case .all: L10n.t("All Items")
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
        "\(label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(payload.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    func copyForImport(id: String, updatedAt: Date) -> VaultEntry {
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
            EntryExportField(id: "label", title: L10n.t("Label")),
            EntryExportField(id: "category", title: L10n.t("Category")),
            EntryExportField(id: "tags", title: L10n.t("Tags"))
        ]

        switch payload {
        case .credential:
            fields += [
                EntryExportField(id: "credential.username", title: L10n.t("Username")),
                EntryExportField(id: "credential.password", title: L10n.t("Password")),
                EntryExportField(id: "credential.accounts", title: L10n.t("Accounts")),
                EntryExportField(id: "credential.token", title: L10n.t("Token")),
                EntryExportField(id: "credential.appId", title: L10n.t("App ID")),
                EntryExportField(id: "credential.accessKey", title: L10n.t("Access Key")),
                EntryExportField(id: "credential.secretKey", title: L10n.t("Secret Key")),
                EntryExportField(id: "credential.notes", title: L10n.t("Notes"))
            ]
        case .server:
            fields += [
                EntryExportField(id: "server.name", title: L10n.t("Name")),
                EntryExportField(id: "server.ipAddress", title: L10n.t("IP Address")),
                EntryExportField(id: "server.port", title: L10n.t("Port")),
                EntryExportField(id: "server.username", title: L10n.t("Username")),
                EntryExportField(id: "server.password", title: L10n.t("Password")),
                EntryExportField(id: "server.accounts", title: L10n.t("Accounts")),
                EntryExportField(id: "server.basicConfig", title: L10n.t("Config")),
                EntryExportField(id: "server.operatingSystem", title: L10n.t("OS")),
                EntryExportField(id: "server.location", title: L10n.t("Location")),
                EntryExportField(id: "server.notes", title: L10n.t("Notes"))
            ]
        case .service:
            fields += [
                EntryExportField(id: "service.name", title: L10n.t("Name")),
                EntryExportField(id: "service.connectionAddress", title: L10n.t("Address")),
                EntryExportField(id: "service.connectionPort", title: L10n.t("Port")),
                EntryExportField(id: "service.accountId", title: L10n.t("Account ID")),
                EntryExportField(id: "service.serverIds", title: L10n.t("Servers")),
                EntryExportField(id: "service.accounts", title: L10n.t("Accounts")),
                EntryExportField(id: "service.notes", title: L10n.t("Notes"))
            ]
        }

        fields += customFields.map {
            EntryExportField(id: "custom.\($0.id)", title: $0.name.isEmpty ? L10n.t("Custom Field") : $0.name)
        }
        return fields
    }

    func keepingExportFields(_ selectedFieldIDs: Set<String>) -> VaultEntry {
        let selectedCustomIDs = Set(
            selectedFieldIDs.compactMap { id -> String? in
                guard id.hasPrefix("custom.") else { return nil }
                return String(id.dropFirst("custom.".count))
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
            if !selectedFieldIDs.contains("credential.accounts") { credential.accounts = [] }
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
            if !selectedFieldIDs.contains("server.accounts") { server.accounts = [] }
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
