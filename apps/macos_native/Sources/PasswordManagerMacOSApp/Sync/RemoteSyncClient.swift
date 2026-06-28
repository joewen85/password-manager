import CryptoKit
import Foundation

struct RemoteSyncResult: Equatable, Sendable {
    var payload: String?
    var statusCode: Int
}

struct RemoteSyncMetadata: Equatable, Sendable {
    var statusCode: Int
    var eTag: String?
    var lastModified: String?
    var contentLength: Int64?

    var fingerprint: String? {
        let strongParts = [
            eTag?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty.map { "etag:\($0)" },
            lastModified?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty.map { "modified:\($0)" }
        ].compactMap { $0 }
        guard !strongParts.isEmpty else {
            return nil
        }
        let parts = strongParts + [contentLength.map { "length:\($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "|")
    }
}

protocol RemoteSyncClient: Sendable {
    func metadata() async -> RemoteSyncMetadata
    func download() async -> RemoteSyncResult
    func upload(_ payload: String) async -> RemoteSyncResult
}

extension RemoteSyncClient {
    func metadata() async -> RemoteSyncMetadata {
        RemoteSyncMetadata(statusCode: 501)
    }
}

private let remoteSyncTimeout: TimeInterval = 12

protocol RemoteSyncHTTPTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionRemoteSyncTransport: RemoteSyncHTTPTransport {
    private let session: URLSession

    init(timeout: TimeInterval = remoteSyncTimeout) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        session = URLSession(configuration: configuration)
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteSyncClientError.nonHTTPResponse
        }
        return (data, httpResponse)
    }
}

private enum RemoteSyncClientError: Error, Sendable {
    case invalidURL
    case nonHTTPResponse
}

struct WebDavSyncClient: RemoteSyncClient {
    var baseUrl: String
    var remotePath: String
    var username: String?
    var password: String?

    private let transport: RemoteSyncHTTPTransport

    init(
        baseUrl: String,
        remotePath: String,
        username: String? = nil,
        password: String? = nil,
        transport: RemoteSyncHTTPTransport = URLSessionRemoteSyncTransport()
    ) {
        self.baseUrl = baseUrl
        self.remotePath = remotePath
        self.username = username
        self.password = password
        self.transport = transport
    }

    func metadata() async -> RemoteSyncMetadata {
        do {
            let url = try buildURL()
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            applyAuthHeader(to: &request)
            let (_, response) = try await transport.perform(request)
            return Self.metadata(from: response)
        } catch let error as URLError where error.code == .timedOut {
            return RemoteSyncMetadata(statusCode: 408)
        } catch {
            return RemoteSyncMetadata(statusCode: 503)
        }
    }

    func download() async -> RemoteSyncResult {
        do {
            let url = try buildURL()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            applyAuthHeader(to: &request)
            let (data, response) = try await transport.perform(request)
            return Self.result(payloadData: data, statusCode: response.statusCode)
        } catch let error as URLError where error.code == .timedOut {
            return RemoteSyncResult(payload: nil, statusCode: 408)
        } catch {
            return RemoteSyncResult(payload: nil, statusCode: 503)
        }
    }

    func upload(_ payload: String) async -> RemoteSyncResult {
        do {
            let url = try buildURL()
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.httpBody = Data(payload.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyAuthHeader(to: &request)
            let (_, response) = try await transport.perform(request)
            return RemoteSyncResult(payload: nil, statusCode: response.statusCode)
        } catch let error as URLError where error.code == .timedOut {
            return RemoteSyncResult(payload: nil, statusCode: 408)
        } catch {
            return RemoteSyncResult(payload: nil, statusCode: 503)
        }
    }

    private func buildURL() throws -> URL {
        guard let base = URL(string: baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw RemoteSyncClientError.invalidURL
        }
        let path = normalizedPath()
        let basePath = components.path
        let trimmedBasePath = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        components.path = "\(trimmedBasePath)\(path)"
        guard let url = components.url else {
            throw RemoteSyncClientError.invalidURL
        }
        return url
    }

    private func normalizedPath() -> String {
        var path = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            path = "/vault.json"
        }
        if !path.hasPrefix("/") {
            path = "/\(path)"
        }
        if path.hasSuffix("/") {
            path += "vault.json"
        }
        return path
    }

    private func applyAuthHeader(to request: inout URLRequest) {
        let resolvedUsername = username ?? ""
        let resolvedPassword = password ?? ""
        guard !resolvedUsername.isEmpty || !resolvedPassword.isEmpty else {
            return
        }
        let token = Data("\(resolvedUsername):\(resolvedPassword)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }

    private static func result(payloadData: Data, statusCode: Int) -> RemoteSyncResult {
        if statusCode == 404 || statusCode == 204 {
            return RemoteSyncResult(payload: nil, statusCode: 404)
        }
        let payload = payloadData.isEmpty ? nil : String(data: payloadData, encoding: .utf8)
        return RemoteSyncResult(payload: payload, statusCode: statusCode)
    }

    private static func metadata(from response: HTTPURLResponse) -> RemoteSyncMetadata {
        if response.statusCode == 404 || response.statusCode == 204 {
            return RemoteSyncMetadata(statusCode: 404)
        }
        return RemoteSyncMetadata(
            statusCode: response.statusCode,
            eTag: response.headerValue("ETag"),
            lastModified: response.headerValue("Last-Modified"),
            contentLength: response.headerValue("Content-Length").flatMap(Int64.init)
        )
    }
}

struct PresignedUrlSyncClient: RemoteSyncClient {
    var downloadUrl: String
    var uploadUrl: String

    private let transport: RemoteSyncHTTPTransport

    init(
        downloadUrl: String,
        uploadUrl: String,
        transport: RemoteSyncHTTPTransport = URLSessionRemoteSyncTransport()
    ) {
        self.downloadUrl = downloadUrl
        self.uploadUrl = uploadUrl
        self.transport = transport
    }

    func metadata() async -> RemoteSyncMetadata {
        guard let url = URL(string: downloadUrl.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return RemoteSyncMetadata(statusCode: 400)
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            let (_, response) = try await transport.perform(request)
            return metadata(from: response)
        } catch let error as URLError where error.code == .timedOut {
            return RemoteSyncMetadata(statusCode: 408)
        } catch {
            return RemoteSyncMetadata(statusCode: 503)
        }
    }

    func download() async -> RemoteSyncResult {
        guard let url = URL(string: downloadUrl.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return RemoteSyncResult(payload: nil, statusCode: 400)
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            let (data, response) = try await transport.perform(request)
            return result(payloadData: data, statusCode: response.statusCode)
        } catch let error as URLError where error.code == .timedOut {
            return RemoteSyncResult(payload: nil, statusCode: 408)
        } catch {
            return RemoteSyncResult(payload: nil, statusCode: 503)
        }
    }

    func upload(_ payload: String) async -> RemoteSyncResult {
        guard let url = URL(string: uploadUrl.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return RemoteSyncResult(payload: nil, statusCode: 400)
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.httpBody = Data(payload.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await transport.perform(request)
            return RemoteSyncResult(payload: nil, statusCode: response.statusCode)
        } catch let error as URLError where error.code == .timedOut {
            return RemoteSyncResult(payload: nil, statusCode: 408)
        } catch {
            return RemoteSyncResult(payload: nil, statusCode: 503)
        }
    }

    private func result(payloadData: Data, statusCode: Int) -> RemoteSyncResult {
        if statusCode == 404 || statusCode == 204 {
            return RemoteSyncResult(payload: nil, statusCode: 404)
        }
        let payload = payloadData.isEmpty ? nil : String(data: payloadData, encoding: .utf8)
        return RemoteSyncResult(payload: payload, statusCode: statusCode)
    }

    private func metadata(from response: HTTPURLResponse) -> RemoteSyncMetadata {
        if response.statusCode == 404 || response.statusCode == 204 {
            return RemoteSyncMetadata(statusCode: 404)
        }
        return RemoteSyncMetadata(
            statusCode: response.statusCode,
            eTag: response.headerValue("ETag"),
            lastModified: response.headerValue("Last-Modified"),
            contentLength: response.headerValue("Content-Length").flatMap(Int64.init)
        )
    }
}

enum ObjectStorageProvider: Sendable {
    case tencentCos
    case aliyunOss
}

struct ObjectStorageSyncClientConfiguration: Equatable, Sendable {
    var provider: ObjectStorageProvider
    var accessKey: String
    var secretKey: String
    var bucket: String
    var endpoint: String
    var appId: String
    var customUrl: String
    var objectKey: String

    static func tencentCos(settings: SyncSettings) -> ObjectStorageSyncClientConfiguration? {
        make(provider: .tencentCos, settings: settings)
    }

    static func aliyunOss(settings: SyncSettings) -> ObjectStorageSyncClientConfiguration? {
        make(provider: .aliyunOss, settings: settings)
    }

    private static func make(
        provider: ObjectStorageProvider,
        settings: SyncSettings
    ) -> ObjectStorageSyncClientConfiguration? {
        let accessKey = settings.objectStorageAccessKey.trimmed
        let secretKey = settings.objectStorageSecretKey.trimmed
        let bucket = settings.objectStorageBucket.trimmed
        let endpoint = settings.objectStorageEndpoint.trimmed
        let customUrl = settings.objectStorageCustomUrl.trimmed
        guard !accessKey.isEmpty,
              !secretKey.isEmpty,
              !bucket.isEmpty,
              (!endpoint.isEmpty || !customUrl.isEmpty) else {
            return nil
        }
        return ObjectStorageSyncClientConfiguration(
            provider: provider,
            accessKey: accessKey,
            secretKey: secretKey,
            bucket: bucket,
            endpoint: endpoint,
            appId: settings.objectStorageAppId.trimmed,
            customUrl: customUrl,
            objectKey: settings.objectStorageObjectKey.trimmed.isEmpty ? "vault.sync.json" : settings.objectStorageObjectKey.trimmed
        )
    }
}

struct ObjectStorageSyncClient: RemoteSyncClient {
    var configuration: ObjectStorageSyncClientConfiguration

    private let transport: RemoteSyncHTTPTransport
    private let now: @Sendable () -> Date

    init(
        configuration: ObjectStorageSyncClientConfiguration,
        transport: RemoteSyncHTTPTransport = URLSessionRemoteSyncTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.transport = transport
        self.now = now
    }

    func metadata() async -> RemoteSyncMetadata {
        await perform(method: "HEAD", payload: nil).metadata
    }

    func download() async -> RemoteSyncResult {
        await perform(method: "GET", payload: nil).result
    }

    func upload(_ payload: String) async -> RemoteSyncResult {
        await perform(method: "PUT", payload: payload).result
    }

    private func perform(method: String, payload: String?) async -> (result: RemoteSyncResult, metadata: RemoteSyncMetadata) {
        do {
            let url = try buildURL()
            var request = URLRequest(url: url)
            request.httpMethod = method
            if let payload {
                request.httpBody = Data(payload.utf8)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            try applyAuthorization(to: &request, method: method, url: url)
            let (data, response) = try await transport.perform(request)
            return (
                Self.result(payloadData: data, statusCode: response.statusCode),
                Self.metadata(from: response)
            )
        } catch let error as URLError where error.code == .timedOut {
            return (
                RemoteSyncResult(payload: nil, statusCode: 408),
                RemoteSyncMetadata(statusCode: 408)
            )
        } catch {
            return (
                RemoteSyncResult(payload: nil, statusCode: 503),
                RemoteSyncMetadata(statusCode: 503)
            )
        }
    }

    private func buildURL() throws -> URL {
        let base: URL?
        if !configuration.customUrl.isEmpty {
            base = URL(string: configuration.customUrl)
        } else {
            let endpoint = configuration.endpoint
            guard !endpoint.isEmpty else {
                throw RemoteSyncClientError.invalidURL
            }
            let schemeEndpoint = endpoint.hasPrefix("http://") || endpoint.hasPrefix("https://")
                ? endpoint
                : "https://\(endpoint)"
            guard let endpointURL = URL(string: schemeEndpoint),
                  var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
                throw RemoteSyncClientError.invalidURL
            }
            let bucket = resolvedBucketName()
            if let host = components.host, !host.hasPrefix("\(bucket).") {
                components.host = "\(bucket).\(host)"
            }
            base = components.url
        }
        guard let base,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw RemoteSyncClientError.invalidURL
        }
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = "\(basePath)/\(configuration.objectKey.pathEncodedSegments)"
        guard let url = components.url else {
            throw RemoteSyncClientError.invalidURL
        }
        return url
    }

    private func resolvedBucketName() -> String {
        guard configuration.provider == .tencentCos,
              !configuration.appId.isEmpty,
              !configuration.bucket.hasSuffix("-\(configuration.appId)") else {
            return configuration.bucket
        }
        return "\(configuration.bucket)-\(configuration.appId)"
    }

    private func applyAuthorization(to request: inout URLRequest, method: String, url: URL) throws {
        switch configuration.provider {
        case .tencentCos:
            applyTencentCosAuthorization(to: &request, method: method, url: url)
        case .aliyunOss:
            applyAliyunOssAuthorization(to: &request, method: method, url: url)
        }
    }

    private func applyTencentCosAuthorization(to request: inout URLRequest, method: String, url: URL) {
        let timestamp = Int(now().timeIntervalSince1970)
        let keyTime = "\(timestamp);\(timestamp + 600)"
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let path = encodedPath.isEmpty ? "/" : encodedPath
        let host = url.host?.lowercased() ?? ""
        var signedHeaders = [("host", host)]
        if let contentType = request.value(forHTTPHeaderField: "Content-Type"), !contentType.isEmpty {
            signedHeaders.append(("content-type", contentType))
        }
        signedHeaders.sort { $0.0 < $1.0 }
        let headerString = signedHeaders
            .map { "\($0.0)=\($0.1.tencentCosPercentEncoded)" }
            .joined(separator: "&")
        let headerList = signedHeaders
            .map(\.0)
            .joined(separator: ";")
        let httpString = [
            method.lowercased(),
            path,
            url.query?.lowercased() ?? "",
            headerString
        ].joined(separator: "\n")
            + "\n"
        let stringToSign = [
            "sha1",
            keyTime,
            httpString.sha1Hex
        ].joined(separator: "\n")
            + "\n"
        let signKey = hmacSHA1Hex(key: configuration.secretKey, message: keyTime)
        let signature = hmacSHA1Hex(key: signKey, message: stringToSign)
        let authorization = [
            "q-sign-algorithm=sha1",
            "q-ak=\(configuration.accessKey)",
            "q-sign-time=\(keyTime)",
            "q-key-time=\(keyTime)",
            "q-header-list=\(headerList)",
            "q-url-param-list=",
            "q-signature=\(signature)"
        ].joined(separator: "&")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    private func applyAliyunOssAuthorization(to request: inout URLRequest, method: String, url: URL) {
        let payload = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let payloadHash = payload.sha256Hex
        let timestamp = Self.ossV4DateFormatter.string(from: now())
        request.setValue(timestamp, forHTTPHeaderField: "x-oss-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-oss-content-sha256")
        let host = url.host?.lowercased() ?? ""
        let headers = [
            "host": host,
            "x-oss-content-sha256": payloadHash,
            "x-oss-date": timestamp
        ].sorted { $0.key < $1.key }
        let canonicalHeaders = headers.map { "\($0.key):\($0.value)\n" }.joined()
        let additionalHeaders = headers.map(\.key).joined(separator: ";")
        let canonicalRequest = [
            method.uppercased(),
            url.path.isEmpty ? "/" : url.path,
            url.canonicalQuery,
            canonicalHeaders,
            additionalHeaders,
            payloadHash
        ].joined(separator: "\n")
        let region = Self.region(from: configuration.endpoint, customUrl: configuration.customUrl, host: host)
        let date = String(timestamp.prefix(8))
        let scope = "\(date)/\(region)/oss/aliyun_v4_request"
        let stringToSign = [
            "OSS4-HMAC-SHA256",
            timestamp,
            scope,
            canonicalRequest.sha256Hex
        ].joined(separator: "\n")
        let signature = hmacSHA256Hex(key: Self.signingKey(secret: configuration.secretKey, date: date, region: region), message: stringToSign)
        request.setValue("OSS4-HMAC-SHA256 Credential=\(configuration.accessKey)/\(scope),AdditionalHeaders=\(additionalHeaders),Signature=\(signature)", forHTTPHeaderField: "Authorization")
    }

    private static func result(payloadData: Data, statusCode: Int) -> RemoteSyncResult {
        if statusCode == 404 || statusCode == 204 {
            return RemoteSyncResult(payload: nil, statusCode: 404)
        }
        let payload = payloadData.isEmpty ? nil : String(data: payloadData, encoding: .utf8)
        return RemoteSyncResult(payload: payload, statusCode: statusCode)
    }

    private static func metadata(from response: HTTPURLResponse) -> RemoteSyncMetadata {
        if response.statusCode == 404 || response.statusCode == 204 {
            return RemoteSyncMetadata(statusCode: 404)
        }
        return RemoteSyncMetadata(
            statusCode: response.statusCode,
            eTag: response.headerValue("ETag"),
            lastModified: response.headerValue("Last-Modified"),
            contentLength: response.headerValue("Content-Length").flatMap(Int64.init)
        )
    }

    private static func region(from endpoint: String, customUrl: String, host: String) -> String {
        for candidate in [endpoint, customUrl, host] {
            if let range = candidate.range(of: #"oss[-.]([a-z0-9-]+)\.aliyuncs\.com"#, options: [.regularExpression, .caseInsensitive]) {
                let matched = String(candidate[range])
                let prefix = matched.hasPrefix("oss-") ? "oss-" : "oss."
                return matched
                    .dropFirst(prefix.count)
                    .replacingOccurrences(of: ".aliyuncs.com", with: "")
            }
        }
        return "cn-hangzhou"
    }

    private static func signingKey(secret: String, date: String, region: String) -> Data {
        let dateKey = hmacSHA256(key: Data("aliyun_v4\(secret)".utf8), message: date)
        let regionKey = hmacSHA256(key: dateKey, message: region)
        let serviceKey = hmacSHA256(key: regionKey, message: "oss")
        return hmacSHA256(key: serviceKey, message: "aliyun_v4_request")
    }

    private static let ossV4DateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var pathEncodedSegments: String {
        split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                String(segment).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(segment)
            }
            .joined(separator: "/")
    }

    var sha1Hex: String {
        Insecure.SHA1.hash(data: Data(utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var sha256Hex: String {
        SHA256.hash(data: Data(utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var tencentCosPercentEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .tencentCosAllowed) ?? self
    }
}

private extension CharacterSet {
    static let tencentCosAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
}

private extension URL {
    var canonicalQuery: String {
        guard let query else { return "" }
        return query
            .split(separator: "&")
            .map { part -> (String, String) in
                let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(pieces.first ?? ""), pieces.count > 1 ? String(pieces[1]) : "")
            }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }
}

private func hmacSHA1Hex(key: String, message: String) -> String {
    let key = SymmetricKey(data: Data(key.utf8))
    return HMAC<Insecure.SHA1>.authenticationCode(for: Data(message.utf8), using: key)
        .map { String(format: "%02x", $0) }
        .joined()
}

private func hmacSHA256(key: Data, message: String) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
}

private func hmacSHA256Hex(key: Data, message: String) -> String {
    hmacSHA256(key: key, message: message)
        .map { String(format: "%02x", $0) }
        .joined()
}

private extension HTTPURLResponse {
    func headerValue(_ name: String) -> String? {
        allHeaderFields.first { key, _ in
            String(describing: key).caseInsensitiveCompare(name) == .orderedSame
        }.map { String(describing: $0.value) }
    }
}
