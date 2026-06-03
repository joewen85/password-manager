import Foundation

struct VaultSearchQuery {
    private let terms: [VaultSearchTerm]

    var isEmpty: Bool { terms.isEmpty }

    func matches(_ entry: VaultEntry) -> Bool {
        terms.allSatisfy { term in entry.matchesSearchTerm(term) }
    }

    static func parse(_ raw: String) -> VaultSearchQuery {
        let terms = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split { character in
                character.isWhitespace || character == ","
            }
            .compactMap { rawPart -> VaultSearchTerm? in
                let part = String(rawPart).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !part.isEmpty else { return nil }
                if part.hasPrefix("#"), part.count > 1 {
                    return VaultSearchTerm(field: "tag", value: String(part.dropFirst()).lowercased())
                }
                let pieces = part.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                if pieces.count == 2 {
                    let key = String(pieces[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty, !value.isEmpty else { return nil }
                    if key.caseInsensitiveCompare("http") == .orderedSame ||
                        key.caseInsensitiveCompare("https") == .orderedSame {
                        return VaultSearchTerm(field: nil, value: part.lowercased())
                    }
                    return VaultSearchTerm(field: canonicalSearchField(key), value: value.lowercased())
                }
                return VaultSearchTerm(field: nil, value: part.lowercased())
            }
        return VaultSearchQuery(terms: terms)
    }
}

private struct VaultSearchTerm {
    var field: String?
    var value: String
}

extension VaultEntry {
    func matchesSearchQuery(_ query: VaultSearchQuery) -> Bool {
        query.matches(self)
    }
}

private extension VaultEntry {
    func matchesSearchTerm(_ term: VaultSearchTerm) -> Bool {
        searchValues(for: term.field).containsSearchValue(term.value)
    }

    func searchValues(for field: String?) -> [String] {
        switch field {
        case nil:
            searchableValues(includeSecrets: false)
        case "label":
            [label]
        case "name":
            [label] + payload.nameValues + customFieldValues(for: "name")
        case "type":
            [type.rawValue, type.title]
        case "category":
            [payload.category]
        case "tag":
            payload.tags
        case "username":
            payload.usernameValues + customFieldValues(for: "username")
        case "ip":
            payload.ipValues + customFieldValues(for: "ip")
        case "port":
            payload.portValues + customFieldValues(for: "port")
        case "address":
            payload.addressValues + customFieldValues(for: "address")
        case "app":
            payload.appValues + customFieldValues(for: "app")
        case "account":
            payload.accountValues + customFieldValues(for: "account")
        case "server":
            serverValues + customFieldValues(for: "server")
        case "service":
            serviceValues + customFieldValues(for: "service")
        case "notes":
            payload.noteValues + customFieldValues(for: "notes")
        case "password":
            payload.passwordValues + customFieldValues(for: "password")
        case "token":
            payload.tokenValues + customFieldValues(for: "token")
        case "accesskey":
            payload.accessKeyValues + customFieldValues(for: "accesskey")
        case "secret":
            payload.secretValues + customFieldValues(for: "secret")
        case "custom":
            customFields.flatMap { [$0.name, $0.value] }
        case .some(let field):
            customFieldValues(for: field)
        }
    }

    func searchableValues(includeSecrets: Bool) -> [String] {
        var values = [label, type.rawValue, type.title, payload.category]
        values += payload.tags
        values += payload.searchableValues(includeSecrets: includeSecrets)
        values += customFields.flatMap { [$0.name, $0.value] }
        return values
    }

    var serverValues: [String] {
        var values: [String] = []
        if type == .server { values.append(label) }
        values += payload.serverValues
        return values
    }

    var serviceValues: [String] {
        var values: [String] = []
        if type == .service { values.append(label) }
        values += payload.serviceValues
        return values
    }

    func customFieldValues(for field: String) -> [String] {
        let key = canonicalSearchField(field)
        return customFields
            .filter { customField in
                let customKey = canonicalSearchField(customField.name)
                return !customKey.isEmpty && (customKey == key || customKey.contains(key) || key.contains(customKey))
            }
            .flatMap { [$0.name, $0.value] }
    }
}

private extension VaultPayload {
    func searchableValues(includeSecrets: Bool) -> [String] {
        switch self {
        case .credential(let payload):
            var values = [payload.username, payload.appId, payload.notes]
            if includeSecrets {
                values += [payload.password, payload.token, payload.accessKey, payload.secretKey]
            }
            return values
        case .server(let payload):
            var values = [
                payload.name,
                payload.ipAddress,
                payload.port,
                payload.username,
                payload.basicConfig,
                payload.operatingSystem,
                payload.location,
                payload.notes,
                payload.accountId ?? ""
            ]
            if includeSecrets { values.append(payload.password) }
            return values
        case .service(let payload):
            var values = [
                payload.name,
                payload.connectionAddress,
                payload.connectionPort,
                payload.accountId ?? ""
            ]
            values += payload.serverIds
            values.append(payload.notes)
            values += payload.accounts.flatMap { [$0.username, $0.note] }
            if includeSecrets { values += payload.accounts.map(\.password) }
            return values
        }
    }

    var nameValues: [String] {
        switch self {
        case .credential:
            []
        case .server(let payload):
            [payload.name]
        case .service(let payload):
            [payload.name]
        }
    }

    var usernameValues: [String] {
        switch self {
        case .credential(let payload):
            [payload.username]
        case .server(let payload):
            [payload.username]
        case .service(let payload):
            payload.accounts.map(\.username)
        }
    }

    var ipValues: [String] {
        switch self {
        case .credential:
            []
        case .server(let payload):
            [payload.ipAddress]
        case .service(let payload):
            [payload.connectionAddress]
        }
    }

    var portValues: [String] {
        switch self {
        case .credential:
            []
        case .server(let payload):
            [payload.port]
        case .service(let payload):
            [payload.connectionPort]
        }
    }

    var addressValues: [String] {
        switch self {
        case .credential:
            []
        case .server(let payload):
            [payload.ipAddress, payload.location]
        case .service(let payload):
            [payload.connectionAddress]
        }
    }

    var appValues: [String] {
        switch self {
        case .credential(let payload):
            [payload.appId]
        case .server, .service:
            []
        }
    }

    var accountValues: [String] {
        switch self {
        case .credential:
            []
        case .server(let payload):
            [payload.accountId ?? ""]
        case .service(let payload):
            [payload.accountId ?? ""] + payload.accounts.flatMap { [$0.username, $0.note] }
        }
    }

    var serverValues: [String] {
        switch self {
        case .credential:
            []
        case .server(let payload):
            [payload.name, payload.ipAddress]
        case .service(let payload):
            payload.serverIds
        }
    }

    var serviceValues: [String] {
        switch self {
        case .credential, .server:
            []
        case .service(let payload):
            [payload.name, payload.connectionAddress]
        }
    }

    var noteValues: [String] {
        switch self {
        case .credential(let payload):
            [payload.notes]
        case .server(let payload):
            [payload.notes]
        case .service(let payload):
            [payload.notes] + payload.accounts.map(\.note)
        }
    }

    var passwordValues: [String] {
        switch self {
        case .credential(let payload):
            [payload.password]
        case .server(let payload):
            [payload.password]
        case .service(let payload):
            payload.accounts.map(\.password)
        }
    }

    var tokenValues: [String] {
        switch self {
        case .credential(let payload):
            [payload.token]
        case .server, .service:
            []
        }
    }

    var accessKeyValues: [String] {
        switch self {
        case .credential(let payload):
            [payload.accessKey]
        case .server, .service:
            []
        }
    }

    var secretValues: [String] {
        switch self {
        case .credential(let payload):
            [payload.secretKey]
        case .server, .service:
            []
        }
    }
}

private extension Array where Element == String {
    func containsSearchValue(_ value: String) -> Bool {
        contains { candidate in
            candidate.range(of: value, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

private func canonicalSearchField(_ raw: String) -> String {
    let key = raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .unicodeScalars
        .filter { CharacterSet.alphanumerics.contains($0) }
        .map(String.init)
        .joined()
    switch key {
    case "title", "label":
        return "label"
    case "name":
        return "name"
    case "type", "kind":
        return "type"
    case "category", "cat":
        return "category"
    case "tag", "tags":
        return "tag"
    case "user", "username", "login":
        return "username"
    case "ip", "ipaddress":
        return "ip"
    case "port":
        return "port"
    case "address", "addr", "host", "url", "connection", "connectionaddress":
        return "address"
    case "app", "appid", "application":
        return "app"
    case "account", "accountid":
        return "account"
    case "server", "servers", "serverid", "serverids", "srv":
        return "server"
    case "service", "svc":
        return "service"
    case "note", "notes":
        return "notes"
    case "password", "pass", "pwd":
        return "password"
    case "token":
        return "token"
    case "access", "accesskey", "ak":
        return "accesskey"
    case "secret", "secretkey", "sk":
        return "secret"
    case "field", "custom":
        return "custom"
    default:
        return key
    }
}
