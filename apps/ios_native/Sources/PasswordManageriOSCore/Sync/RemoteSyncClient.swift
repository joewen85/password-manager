import Foundation
import CryptoKit

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

struct TencentCosSyncClient: RemoteSyncClient {
    private let ak: String
    private let sk: String
    private let bucket: String
    private let endpoint: String
    private let appid: String
    private let customUrl: String
    private let objectKey: String
    private let transport: RemoteSyncHTTPTransport
    private let now: @Sendable () -> Date

    init(
        settings: SyncSettings,
        transport: RemoteSyncHTTPTransport = URLSessionRemoteSyncTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        ak = settings.ak.trimmingCharacters(in: .whitespacesAndNewlines)
        sk = settings.sk.trimmingCharacters(in: .whitespacesAndNewlines)
        bucket = settings.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        endpoint = settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        appid = settings.appid.trimmingCharacters(in: .whitespacesAndNewlines)
        customUrl = settings.customUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        objectKey = settings.objectKey.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func perform(method: String, payload: String?) async -> ObjectStorageResponse {
        do {
            let url = try objectURL()
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = payload.map { Data($0.utf8) }
            if payload != nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if let host = url.host?.lowercased() {
                request.setValue(host, forHTTPHeaderField: "Host")
            }
            request.setValue(authorization(method: method, url: url, request: request), forHTTPHeaderField: "Authorization")
            let (data, response) = try await transport.perform(request)
            return ObjectStorageResponse(data: data, response: response)
        } catch let error as URLError where error.code == .timedOut {
            return ObjectStorageResponse(statusCode: 408)
        } catch {
            return ObjectStorageResponse(statusCode: 503)
        }
    }

    private func objectURL() throws -> URL {
        if !customUrl.isEmpty {
            return try ObjectStorageURLBuilder.url(base: customUrl, objectKey: objectKey)
        }
        let hostBucket = appid.isEmpty || bucket.hasSuffix("-\(appid)") ? bucket : "\(bucket)-\(appid)"
        guard !endpoint.isEmpty else {
            throw RemoteSyncClientError.invalidURL
        }
        return try ObjectStorageURLBuilder.url(base: endpoint, objectKey: objectKey, hostPrefix: hostBucket)
    }

    private func authorization(method: String, url: URL, request: URLRequest) -> String {
        let start = Int(now().timeIntervalSince1970)
        let end = start + 600
        let keyTime = "\(start);\(end)"
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
            url.objectStorageCanonicalPath,
            "",
            headerString
        ].joined(separator: "\n")
            + "\n"
        let stringToSign = [
            "sha1",
            keyTime,
            Insecure.SHA1.hash(data: Data(httpString.utf8)).hexString,
        ].joined(separator: "\n")
            + "\n"
        let signKey = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(keyTime.utf8),
            using: SymmetricKey(data: Data(sk.utf8))
        ).hexString
        let signature = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: SymmetricKey(data: Data(signKey.utf8))
        ).hexString
        return "q-sign-algorithm=sha1&q-ak=\(ak)&q-sign-time=\(keyTime)&q-key-time=\(keyTime)&q-header-list=\(headerList)&q-url-param-list=&q-signature=\(signature)"
    }
}

struct AliyunOssSyncClient: RemoteSyncClient {
    private let ak: String
    private let sk: String
    private let bucket: String
    private let endpoint: String
    private let customUrl: String
    private let objectKey: String
    private let transport: RemoteSyncHTTPTransport
    private let now: @Sendable () -> Date

    init(
        settings: SyncSettings,
        transport: RemoteSyncHTTPTransport = URLSessionRemoteSyncTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        ak = settings.ak.trimmingCharacters(in: .whitespacesAndNewlines)
        sk = settings.sk.trimmingCharacters(in: .whitespacesAndNewlines)
        bucket = settings.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        endpoint = settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        customUrl = settings.customUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        objectKey = settings.objectKey.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func perform(method: String, payload: String?) async -> ObjectStorageResponse {
        do {
            let url = try objectURL()
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = payload.map { Data($0.utf8) }
            let payloadBody = payload ?? ""
            let payloadHash = payloadBody.sha256Hex
            let timestamp = Self.ossV4DateFormatter.string(from: now())
            request.setValue(timestamp, forHTTPHeaderField: "x-oss-date")
            request.setValue(payloadHash, forHTTPHeaderField: "x-oss-content-sha256")
            if payload != nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            request.setValue(authorization(method: method, url: url, timestamp: timestamp, payloadHash: payloadHash), forHTTPHeaderField: "Authorization")
            let (data, response) = try await transport.perform(request)
            return ObjectStorageResponse(data: data, response: response)
        } catch let error as URLError where error.code == .timedOut {
            return ObjectStorageResponse(statusCode: 408)
        } catch {
            return ObjectStorageResponse(statusCode: 503)
        }
    }

    private func objectURL() throws -> URL {
        if !customUrl.isEmpty {
            return try ObjectStorageURLBuilder.url(base: customUrl, objectKey: objectKey)
        }
        guard !endpoint.isEmpty else {
            throw RemoteSyncClientError.invalidURL
        }
        return try ObjectStorageURLBuilder.url(base: endpoint, objectKey: objectKey, hostPrefix: bucket)
    }

    private func authorization(method: String, url: URL, timestamp: String, payloadHash: String) -> String {
        let region = Self.region(from: endpoint, customUrl: customUrl, host: url.host ?? "")
        let date = String(timestamp.prefix(8))
        let headers = canonicalHeaders(url: url, payloadHash: payloadHash, timestamp: timestamp)
        let canonicalRequest = [
            method.uppercased(),
            url.objectStorageCanonicalPath,
            url.canonicalQuery,
            headers.canonicalHeaders,
            headers.additionalHeaders,
            payloadHash
        ].joined(separator: "\n")
        let scope = "\(date)/\(region)/oss/aliyun_v4_request"
        let stringToSign = [
            "OSS4-HMAC-SHA256",
            timestamp,
            scope,
            canonicalRequest.sha256Hex
        ].joined(separator: "\n")
        let signature = hmacSHA256Hex(key: Self.signingKey(secret: sk, date: date, region: region), message: stringToSign)
        return "OSS4-HMAC-SHA256 Credential=\(ak)/\(scope),AdditionalHeaders=\(headers.additionalHeaders),Signature=\(signature)"
    }

    private func canonicalHeaders(url: URL, payloadHash: String, timestamp: String) -> (canonicalHeaders: String, additionalHeaders: String) {
        let headers = [
            "host": (url.host ?? "").lowercased(),
            "x-oss-content-sha256": payloadHash,
            "x-oss-date": timestamp
        ].sorted { $0.key < $1.key }
        return (
            headers.map { "\($0.key):\($0.value)\n" }.joined(),
            headers.map(\.key).joined(separator: ";")
        )
    }

    private static func region(from endpoint: String, customUrl: String, host: String) -> String {
        for candidate in [endpoint, customUrl, host] {
            if let match = candidate.range(of: #"oss[-.]([a-z0-9-]+)\.aliyuncs\.com"#, options: [.regularExpression, .caseInsensitive]) {
                let matched = String(candidate[match])
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

private struct ObjectStorageURLBuilder {
    static func url(base: String, objectKey: String, hostPrefix: String? = nil) throws -> URL {
        let resolvedBase = base.hasPrefix("http://") || base.hasPrefix("https://")
            ? base
            : "https://\(base)"
        guard let baseURL = URL(string: resolvedBase),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw RemoteSyncClientError.invalidURL
        }
        if let hostPrefix, !hostPrefix.isEmpty, let host = components.host, !host.hasPrefix("\(hostPrefix).") {
            components.host = "\(hostPrefix).\(host)"
        }
        let keyPath = normalizedObjectPath(objectKey)
        let basePath = components.path
        let trimmedBasePath = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        components.path = "\(trimmedBasePath)\(keyPath)"
        guard let url = components.url else {
            throw RemoteSyncClientError.invalidURL
        }
        return url
    }

    private static func normalizedObjectPath(_ objectKey: String) -> String {
        var path = objectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            path = "vault.sync.json"
        }
        if !path.hasPrefix("/") {
            path = "/\(path)"
        }
        return path
    }
}

private struct ObjectStorageResponse {
    var data: Data = Data()
    var response: HTTPURLResponse?
    var statusCode: Int = 503

    init(data: Data, response: HTTPURLResponse) {
        self.data = data
        self.response = response
        statusCode = response.statusCode
    }

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    var result: RemoteSyncResult {
        if statusCode == 404 || statusCode == 204 {
            return RemoteSyncResult(payload: nil, statusCode: 404)
        }
        let payload = data.isEmpty ? nil : String(data: data, encoding: .utf8)
        return RemoteSyncResult(payload: payload, statusCode: statusCode)
    }

    var metadata: RemoteSyncMetadata {
        guard let response else {
            return RemoteSyncMetadata(statusCode: statusCode)
        }
        if statusCode == 404 || statusCode == 204 {
            return RemoteSyncMetadata(statusCode: 404)
        }
        return RemoteSyncMetadata(
            statusCode: statusCode,
            eTag: response.headerValue("ETag"),
            lastModified: response.headerValue("Last-Modified"),
            contentLength: response.headerValue("Content-Length").flatMap(Int64.init)
        )
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension URL {
    var objectStorageCanonicalPath: String {
        let encodedPath = URLComponents(url: self, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? path
        return encodedPath.isEmpty ? "/" : encodedPath
    }

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

private extension Sequence where Element == UInt8 {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    var base64String: String {
        Data(self).base64EncodedString()
    }
}

private extension String {
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

private func hmacSHA256(key: Data, message: String) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
}

private func hmacSHA256Hex(key: Data, message: String) -> String {
    hmacSHA256(key: key, message: message).map { String(format: "%02x", $0) }.joined()
}

private extension HTTPURLResponse {
    func headerValue(_ name: String) -> String? {
        allHeaderFields.first { key, _ in
            String(describing: key).caseInsensitiveCompare(name) == .orderedSame
        }.map { String(describing: $0.value) }
    }
}
