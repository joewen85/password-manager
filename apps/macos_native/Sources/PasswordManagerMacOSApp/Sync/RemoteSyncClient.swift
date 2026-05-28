import Foundation

struct RemoteSyncResult: Equatable, Sendable {
    var payload: String?
    var statusCode: Int
}

protocol RemoteSyncClient: Sendable {
    func download() async -> RemoteSyncResult
    func upload(_ payload: String) async -> RemoteSyncResult
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
}
