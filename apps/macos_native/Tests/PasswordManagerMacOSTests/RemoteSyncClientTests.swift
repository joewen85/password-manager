import Foundation
import Testing
@testable import PasswordManagerMacOSApp

@Suite("RemoteSyncClient")
struct RemoteSyncClientTests {
    @Test("WebDAV download normalizes remote path and sends basic auth")
    func webDavDownloadNormalizesPathAndSendsBasicAuth() async {
        let transport = FakeRemoteSyncTransport(
            responses: [
                .success(httpResult(
                    url: URL(string: "https://example.com/root/folder/vault.json")!,
                    statusCode: 200,
                    body: #"{"revision":1}"#
                ))
            ]
        )
        let client = WebDavSyncClient(
            baseUrl: "https://example.com/root/",
            remotePath: "folder/vault.json",
            username: "alice",
            password: "secret",
            transport: transport
        )

        let result = await client.download()

        #expect(result == RemoteSyncResult(payload: #"{"revision":1}"#, statusCode: 200))
        #expect(transport.requests.count == 1)
        let request = transport.requests[0]
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://example.com/root/folder/vault.json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic YWxpY2U6c2VjcmV0")
    }

    @Test("WebDAV upload appends default file for trailing remote directory")
    func webDavUploadAppendsDefaultFileForTrailingDirectory() async {
        let transport = FakeRemoteSyncTransport(
            responses: [
                .success(httpResult(
                    url: URL(string: "https://example.com/root/folder/vault.json")!,
                    statusCode: 201
                ))
            ]
        )
        let client = WebDavSyncClient(
            baseUrl: "https://example.com/root",
            remotePath: "/folder/",
            transport: transport
        )

        let result = await client.upload(#"{"revision":2}"#)

        #expect(result == RemoteSyncResult(payload: nil, statusCode: 201))
        #expect(transport.requests.count == 1)
        let request = transport.requests[0]
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://example.com/root/folder/vault.json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody == Data(#"{"revision":2}"#.utf8))
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Download maps empty remote status to missing payload")
    func downloadMapsEmptyRemoteStatusToMissingPayload() async {
        let transport = FakeRemoteSyncTransport(
            responses: [
                .success(httpResult(
                    url: URL(string: "https://example.com/vault.json")!,
                    statusCode: 204
                ))
            ]
        )
        let client = WebDavSyncClient(
            baseUrl: "https://example.com",
            remotePath: "",
            transport: transport
        )

        let result = await client.download()

        #expect(result == RemoteSyncResult(payload: nil, statusCode: 404))
        #expect(transport.requests.first?.url?.absoluteString == "https://example.com/vault.json")
    }

    @Test("Transport timeout and errors map to Flutter-compatible status codes")
    func transportFailuresMapToStatusCodes() async {
        let timeoutClient = PresignedUrlSyncClient(
            downloadUrl: "https://example.com/download",
            uploadUrl: "https://example.com/upload",
            transport: FakeRemoteSyncTransport(responses: [.failure(URLError(.timedOut))])
        )
        let errorClient = PresignedUrlSyncClient(
            downloadUrl: "https://example.com/download",
            uploadUrl: "https://example.com/upload",
            transport: FakeRemoteSyncTransport(responses: [.failure(URLError(.cannotConnectToHost))])
        )

        let timeout = await timeoutClient.download()
        let error = await errorClient.download()

        #expect(timeout == RemoteSyncResult(payload: nil, statusCode: 408))
        #expect(error == RemoteSyncResult(payload: nil, statusCode: 503))
    }

    @Test("Presigned client rejects missing URL configuration")
    func presignedClientRejectsMissingURLConfiguration() async {
        let client = PresignedUrlSyncClient(downloadUrl: "", uploadUrl: "")

        let download = await client.download()
        let upload = await client.upload("{}")

        #expect(download == RemoteSyncResult(payload: nil, statusCode: 400))
        #expect(upload == RemoteSyncResult(payload: nil, statusCode: 400))
    }
}

private func httpResult(url: URL, statusCode: Int, body: String = "") -> (Data, HTTPURLResponse) {
    (
        Data(body.utf8),
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    )
}

private final class FakeRemoteSyncTransport: RemoteSyncHTTPTransport, @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    private var responses: [Result<(Data, HTTPURLResponse), Error>]

    init(responses: [Result<(Data, HTTPURLResponse), Error>]) {
        self.responses = responses
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return try responses.removeFirst().get()
    }
}
