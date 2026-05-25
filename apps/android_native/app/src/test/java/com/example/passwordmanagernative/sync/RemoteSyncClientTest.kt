package com.example.passwordmanagernative.sync

import java.net.SocketTimeoutException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class RemoteSyncClientTest {
    @Test
    fun webDavDownloadNormalizesPathAndSendsBasicAuth() {
        val transport = FakeRemoteSyncTransport(
            responses = ArrayDeque(
                listOf(
                    Result.success(
                        RemoteSyncHttpResponse(
                            statusCode = 200,
                            body = """{"revision":1}""",
                        )
                    )
                )
            )
        )
        val client = WebDavSyncClient(
            baseUrl = "https://example.com/root/",
            remotePath = "folder/vault.json",
            username = "alice",
            password = "secret",
            transport = transport,
        )

        val result = client.download()

        assertEquals(RemoteSyncResult(payload = """{"revision":1}""", statusCode = 200), result)
        assertEquals(1, transport.requests.size)
        val request = transport.requests.single()
        assertEquals("GET", request.method)
        assertEquals("https://example.com/root/folder/vault.json", request.url.toString())
        assertEquals("Basic YWxpY2U6c2VjcmV0", request.headers["Authorization"])
    }

    @Test
    fun webDavUploadAppendsDefaultFileForTrailingDirectory() {
        val transport = FakeRemoteSyncTransport(
            responses = ArrayDeque(
                listOf(
                    Result.success(RemoteSyncHttpResponse(statusCode = 201))
                )
            )
        )
        val client = WebDavSyncClient(
            baseUrl = "https://example.com/root",
            remotePath = "/folder/",
            transport = transport,
        )

        val result = client.upload("""{"revision":2}""")

        assertEquals(RemoteSyncResult(payload = null, statusCode = 201), result)
        assertEquals(1, transport.requests.size)
        val request = transport.requests.single()
        assertEquals("PUT", request.method)
        assertEquals("https://example.com/root/folder/vault.json", request.url.toString())
        assertEquals("application/json", request.headers["Content-Type"])
        assertEquals("""{"revision":2}""", request.body)
        assertNull(request.headers["Authorization"])
    }

    @Test
    fun downloadMapsEmptyRemoteStatusToMissingPayload() {
        val transport = FakeRemoteSyncTransport(
            responses = ArrayDeque(
                listOf(
                    Result.success(RemoteSyncHttpResponse(statusCode = 204))
                )
            )
        )
        val client = WebDavSyncClient(
            baseUrl = "https://example.com",
            remotePath = "",
            transport = transport,
        )

        val result = client.download()

        assertEquals(RemoteSyncResult(payload = null, statusCode = 404), result)
        assertEquals("https://example.com/vault.json", transport.requests.single().url.toString())
    }

    @Test
    fun transportFailuresMapToFlutterCompatibleStatusCodes() {
        val timeoutClient = PresignedUrlSyncClient(
            downloadUrl = "https://example.com/download",
            uploadUrl = "https://example.com/upload",
            transport = FakeRemoteSyncTransport(
                responses = ArrayDeque(listOf(Result.failure(SocketTimeoutException())))
            ),
        )
        val errorClient = PresignedUrlSyncClient(
            downloadUrl = "https://example.com/download",
            uploadUrl = "https://example.com/upload",
            transport = FakeRemoteSyncTransport(
                responses = ArrayDeque(listOf(Result.failure(IllegalStateException("offline"))))
            ),
        )

        val timeout = timeoutClient.download()
        val error = errorClient.download()

        assertEquals(RemoteSyncResult(payload = null, statusCode = 408), timeout)
        assertEquals(RemoteSyncResult(payload = null, statusCode = 503), error)
    }

    @Test
    fun presignedClientRejectsMissingUrlConfiguration() {
        val client = PresignedUrlSyncClient(downloadUrl = "", uploadUrl = "")

        val download = client.download()
        val upload = client.upload("{}")

        assertEquals(RemoteSyncResult(payload = null, statusCode = 400), download)
        assertEquals(RemoteSyncResult(payload = null, statusCode = 400), upload)
    }
}

private class FakeRemoteSyncTransport(
    private val responses: ArrayDeque<Result<RemoteSyncHttpResponse>>,
) : RemoteSyncHttpTransport {
    val requests = mutableListOf<RemoteSyncRequest>()

    override fun perform(request: RemoteSyncRequest): RemoteSyncHttpResponse {
        requests += request
        if (responses.isEmpty()) {
            throw IllegalStateException("No fake response configured.")
        }
        return responses.removeFirst().getOrThrow()
    }
}
