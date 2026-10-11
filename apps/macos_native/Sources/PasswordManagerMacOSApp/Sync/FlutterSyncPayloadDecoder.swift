import Foundation

struct FlutterSyncPayloadDecoder: Sendable {
    private let masterPassword: String
    private let crypto: VaultCryptoService

    init(masterPassword: String, crypto: VaultCryptoService = VaultCryptoService()) {
        self.masterPassword = masterPassword
        self.crypto = crypto
    }

    func decode(_ rawPayload: String?) throws -> VaultSyncPayload? {
        guard let rawPayload, !rawPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let data = rawPayload.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["version"] as? Int) == 2,
              json["items"] is [Any] else {
            return nil
        }

        let sessionMetadataKey = try resolveSessionMetadataKey(from: json["masterKey"] as? [String: Any])
        let remoteMetadata = try decodeVaultMetadata(
            from: json["metadataRecord"] as? [String: Any],
            sessionMetadataKey: sessionMetadataKey
        )
        let records = (json["items"] as? [[String: Any]]) ?? []
        let entries = try records.map { try decodeEntry($0, sessionMetadataKey: sessionMetadataKey) }
        let payloadCategories = entries.map(\.payload.category).filter { !$0.isEmpty }
        let payloadTags = entries.flatMap(\.payload.tags).filter { !$0.isEmpty }
        let exportedAt = Self.parseDate(json["exportedAt"] as? String) ?? Date()

        let snapshot = VaultSnapshot(
            entries: entries.sorted { $0.updatedAt > $1.updatedAt },
            categories: (remoteMetadata?.categories ?? payloadCategories).removingDuplicateValues().sorted(),
            categoryTemplates: (remoteMetadata?.categoryTemplates ?? []).sorted { $0.category < $1.category },
            tags: (remoteMetadata?.tags ?? payloadTags).removingDuplicateValues().sorted(),
            syncStatus: "Imported from Flutter sync",
            updatedAt: exportedAt
        )
        return VaultSyncPayload(
            exportedAt: exportedAt,
            deviceId: json["deviceId"] as? String ?? "",
            revision: Self.intValue(json["revision"]),
            snapshot: snapshot
        )
    }

    private func resolveSessionMetadataKey(from rawMasterKey: [String: Any]?) throws -> Data? {
        guard let rawMasterKey else {
            return nil
        }
        let salt = try Self.base64Data(rawMasterKey["salt"])
        let iterations = Self.intValue(rawMasterKey["iterations"], defaultValue: 120_000)
        let verifier = try Self.base64Data(rawMasterKey["verifier"])
        let derived = try crypto.deriveKeyForTesting(
            password: masterPassword,
            salt: salt,
            iterations: iterations
        )
        guard derived == verifier else {
            return nil
        }

        let metadataSalt = try Self.optionalBase64Data(rawMasterKey["metadataSalt"]) ?? salt
        let metadataIterations = Self.intValue(rawMasterKey["metadataIterations"], defaultValue: iterations)
        return try crypto.deriveKeyForTesting(
            password: masterPassword,
            salt: metadataSalt,
            iterations: metadataIterations
        )
    }

    private func decodeVaultMetadata(
        from rawMetadataRecord: [String: Any]?,
        sessionMetadataKey: Data?
    ) throws -> FlutterVaultMetadata? {
        guard let rawMetadataRecord,
              let encryptedPayload = try Self.encryptedPayload(rawMetadataRecord["encryptedPayload"]) else {
            return nil
        }
        let recordKey = try deriveKey(
            salt: rawMetadataRecord["kdfSalt"],
            iterations: Self.intValue(rawMetadataRecord["kdfIterations"], defaultValue: 120_000)
        )
        let plaintext = try decryptWithFallback(encryptedPayload, keys: [sessionMetadataKey, recordKey])
        guard let json = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            return nil
        }
        return FlutterVaultMetadata(
            categories: Self.stringArray(json["categories"]),
            categoryTemplates: Self.categoryTemplates(json["categoryTemplates"]),
            tags: Self.stringArray(json["tags"])
        )
    }

    private func decodeEntry(_ rawRecord: [String: Any], sessionMetadataKey: Data?) throws -> VaultEntry {
        let recordKey = try deriveKey(
            salt: rawRecord["kdfSalt"],
            iterations: Self.intValue(rawRecord["kdfIterations"], defaultValue: 120_000)
        )
        let metadata = try decodeEntryMetadata(
            from: rawRecord,
            recordKey: recordKey,
            sessionMetadataKey: sessionMetadataKey
        )
        let encryptedPayload = try Self.requiredEncryptedPayload(rawRecord["encryptedPayload"])
        let payloadData = try crypto.decrypt(encryptedPayload, key: recordKey)
        guard let payloadJson = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw VaultSyncEngineError.invalidRemotePayload
        }
        let payload = try Self.makePayload(type: metadata.type, json: payloadJson)
        let normalizedPayload = Self.replaceTaxonomy(
            in: payload,
            category: metadata.category,
            tags: metadata.tags
        )
        let customFields = payloadJson.keys.contains("customFields")
            ? Self.customFields(payloadJson["customFields"])
            : metadata.customFields
        let rawId = Self.stringValue(rawRecord["id"])

        return VaultEntry(
            id: rawId.isEmpty ? UUID().uuidString.lowercased() : rawId,
            label: metadata.label,
            type: metadata.type,
            payload: normalizedPayload,
            customFields: customFields,
            createdAt: metadata.createdAt,
            updatedAt: metadata.updatedAt,
            isDeleted: metadata.isDeleted,
            deletedAt: metadata.deletedAt,
            version: metadata.version,
            updatedBy: metadata.updatedBy
        )
    }

    private func decodeEntryMetadata(
        from rawRecord: [String: Any],
        recordKey: Data,
        sessionMetadataKey: Data?
    ) throws -> FlutterEntryMetadata {
        if let encryptedMetadata = try Self.encryptedPayload(rawRecord["encryptedMetadata"]) {
            let plaintext = try decryptWithFallback(encryptedMetadata, keys: [sessionMetadataKey, recordKey])
            guard let json = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
                throw VaultSyncEngineError.invalidRemotePayload
            }
            return FlutterEntryMetadata(json: json)
        }
        return FlutterEntryMetadata(json: rawRecord)
    }

    private func deriveKey(salt rawSalt: Any?, iterations: Int) throws -> Data {
        let salt = try Self.base64Data(rawSalt)
        return try crypto.deriveKeyForTesting(
            password: masterPassword,
            salt: salt,
            iterations: iterations
        )
    }

    private func decryptWithFallback(_ payload: EncryptedPayloadRecord, keys: [Data?]) throws -> Data {
        var lastError: Error?
        for key in keys.compactMap(\.self) {
            do {
                return try crypto.decrypt(payload, key: key)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? VaultSyncEngineError.invalidRemotePayload
    }

    private static func encryptedPayload(_ raw: Any?) throws -> EncryptedPayloadRecord? {
        guard let raw = raw as? [String: Any] else {
            return nil
        }
        return try requiredEncryptedPayload(raw)
    }

    private static func requiredEncryptedPayload(_ raw: Any?) throws -> EncryptedPayloadRecord {
        guard let raw = raw as? [String: Any],
              let ciphertext = raw["ciphertext"] as? String,
              let nonce = raw["nonce"] as? String,
              let mac = raw["mac"] as? String else {
            throw VaultSyncEngineError.invalidRemotePayload
        }
        return EncryptedPayloadRecord(
            ciphertext: ciphertext,
            nonce: nonce,
            mac: mac,
            version: intValue(raw["version"], defaultValue: 1)
        )
    }

    private static func makePayload(type: VaultEntryType, json: [String: Any]) throws -> VaultPayload {
        switch type {
        case .credential:
            return .credential(CredentialPayload(
                username: stringValue(json["username"]),
                password: stringValue(json["password"]),
                accounts: serviceAccounts(json["accounts"]),
                token: stringValue(json["token"]),
                appId: stringValue(json["appId"]),
                accessKey: stringValue(json["accessKey"] ?? json["accessToken"]),
                secretKey: stringValue(json["secretKey"]),
                notes: stringValue(json["notes"]),
                tags: stringArray(json["tags"]),
                category: stringValue(json["category"])
            ))
        case .server:
            return .server(ServerPayload(
                name: stringValue(json["name"]),
                ipAddress: stringValue(json["ipAddress"]),
                port: stringValue(json["port"]),
                username: stringValue(json["username"]),
                password: stringValue(json["password"]),
                accounts: serviceAccounts(json["accounts"]),
                basicConfig: stringValue(json["basicConfig"]),
                operatingSystem: stringValue(json["operatingSystem"]),
                location: stringValue(json["location"]),
                notes: stringValue(json["notes"]),
                tags: stringArray(json["tags"]),
                accountId: optionalStringValue(json["accountId"]),
                category: stringValue(json["category"])
            ))
        case .service:
            return .service(ServicePayload(
                name: stringValue(json["name"]),
                connectionAddress: stringValue(json["connectionAddress"]),
                connectionPort: stringValue(json["connectionPort"]),
                accountId: optionalStringValue(json["accountId"]),
                serverIds: stringArray(json["serverIds"]),
                accounts: serviceAccounts(json["accounts"]),
                notes: stringValue(json["notes"]),
                tags: stringArray(json["tags"]),
                category: stringValue(json["category"])
            ))
        }
    }

    private static func replaceTaxonomy(in payload: VaultPayload, category: String, tags: [String]) -> VaultPayload {
        switch payload {
        case .credential(var credential):
            credential.category = category
            credential.tags = tags
            return .credential(credential)
        case .server(var server):
            server.category = category
            server.tags = tags
            return .server(server)
        case .service(var service):
            service.category = category
            service.tags = tags
            return .service(service)
        }
    }

    private static func serviceAccounts(_ raw: Any?) -> [ServiceAccount] {
        guard let rawAccounts = raw as? [[String: Any]] else {
            return []
        }
        return rawAccounts.map {
            ServiceAccount(
                username: stringValue($0["username"]),
                password: stringValue($0["password"]),
                note: stringValue($0["note"])
            )
        }
    }

    private static func categoryTemplates(_ raw: Any?) -> [CategoryTemplate] {
        guard let rawTemplates = raw as? [[String: Any]] else {
            return []
        }
        return rawTemplates.compactMap { template in
            let category = stringValue(template["category"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.isEmpty else { return nil }
            let fields = (template["fields"] as? [[String: Any]] ?? []).compactMap { field -> FieldTemplate? in
                let name = stringValue(field["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                let decodedId = stringValue(field["id"])
                let decodedValueType = stringValue(field["valueType"])
                return FieldTemplate(
                    id: decodedId.isEmpty ? FieldTemplate.stableFieldId(name) : decodedId,
                    name: name,
                    valueType: decodedValueType.isEmpty ? "text" : decodedValueType,
                    targetCategory: stringValue(field["targetCategory"])
                )
            }
            return CategoryTemplate(category: category, fields: fields)
        }
    }

    private static func customFields(_ raw: Any?) -> [CustomField] {
        guard let rawFields = raw as? [[String: Any]] else {
            return []
        }
        return rawFields.map { field in
            let decodedId = stringValue(field["id"])
            return CustomField(
                id: decodedId.isEmpty ? UUID().uuidString.lowercased() : decodedId,
                templateFieldId: stringValue(field["templateFieldId"]),
                name: stringValue(field["name"]),
                value: stringValue(field["value"])
            )
        }
    }

    private static func base64Data(_ raw: Any?) throws -> Data {
        guard let value = raw as? String,
              let data = Data(base64Encoded: value) else {
            throw VaultSyncEngineError.invalidRemotePayload
        }
        return data
    }

    private static func optionalBase64Data(_ raw: Any?) throws -> Data? {
        guard let value = raw as? String, !value.isEmpty else {
            return nil
        }
        guard let data = Data(base64Encoded: value) else {
            throw VaultSyncEngineError.invalidRemotePayload
        }
        return data
    }

    private static func stringArray(_ raw: Any?) -> [String] {
        (raw as? [Any] ?? [])
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func stringValue(_ raw: Any?) -> String {
        raw as? String ?? ""
    }

    private static func optionalStringValue(_ raw: Any?) -> String? {
        guard let value = raw as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func intValue(_ raw: Any?, defaultValue: Int = 0) -> Int {
        if let value = raw as? Int {
            return value
        }
        if let value = raw as? NSNumber {
            return value.intValue
        }
        if let value = raw as? String {
            return Int(value) ?? defaultValue
        }
        return defaultValue
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let raw = raw as? String, !raw.isEmpty else {
            return nil
        }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: raw) {
            return date
        }
        return ISO8601DateFormatter().date(from: raw)
    }

    private struct FlutterVaultMetadata {
        var categories: [String]
        var categoryTemplates: [CategoryTemplate]
        var tags: [String]
    }

    private struct FlutterEntryMetadata {
        var label: String
        var type: VaultEntryType
        var createdAt: Date
        var updatedAt: Date
        var version: [String: Int]
        var updatedBy: String
        var isDeleted: Bool
        var deletedAt: Date?
        var category: String
        var tags: [String]
        var customFields: [CustomField]

        init(json: [String: Any]) {
            label = stringValue(json["label"])
            type = VaultEntryType(rawValue: stringValue(json["type"])) ?? .credential
            createdAt = parseDate(json["createdAt"]) ?? Date(timeIntervalSince1970: 0)
            updatedAt = parseDate(json["updatedAt"]) ?? Date(timeIntervalSince1970: 0)
            version = Self.versionMap(json["version"])
            updatedBy = stringValue(json["updatedBy"]).isEmpty ? "flutter-sync" : stringValue(json["updatedBy"])
            isDeleted = json["isDeleted"] as? Bool ?? false
            deletedAt = parseDate(json["deletedAt"])
            category = stringValue(json["category"])
            tags = stringArray(json["tags"])
            customFields = FlutterSyncPayloadDecoder.customFields(json["customFields"])
        }

        private static func versionMap(_ raw: Any?) -> [String: Int] {
            guard let raw = raw as? [String: Any] else {
                return [:]
            }
            return raw.reduce(into: [:]) { result, entry in
                result[entry.key] = intValue(entry.value)
            }
        }
    }
}

private extension Array where Element: Hashable {
    func removingDuplicateValues() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
