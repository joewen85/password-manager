package com.example.passwordmanagernative.sync

import java.net.SocketTimeoutException
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

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
    fun webDavMetadataUsesHeadAndBuildsFingerprint() {
        val transport = FakeRemoteSyncTransport(
            responses = ArrayDeque(
                listOf(
                    Result.success(
                        RemoteSyncHttpResponse(
                            statusCode = 200,
                            headers = mapOf(
                                "ETag" to "\"abc123\"",
                                "Last-Modified" to "Wed, 28 May 2026 10:00:00 GMT",
                                "Content-Length" to "42",
                            ),
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

        val metadata = client.metadata()

        assertEquals(200, metadata.statusCode)
        assertEquals("\"abc123\"", metadata.eTag)
        assertEquals("Wed, 28 May 2026 10:00:00 GMT", metadata.lastModified)
        assertEquals(42, metadata.contentLength)
        assertEquals("etag:\"abc123\"|modified:Wed, 28 May 2026 10:00:00 GMT|length:42", assertNotNull(metadata.fingerprint))
        assertEquals("HEAD", transport.requests.single().method)
        assertEquals("Basic YWxpY2U6c2VjcmV0", transport.requests.single().headers["Authorization"])
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

    @Test
    fun tencentCosClientSignsHeadGetAndPutRequests() {
        val transport = FakeRemoteSyncTransport(
            responses = ArrayDeque(
                listOf(
                    Result.success(RemoteSyncHttpResponse(statusCode = 200, headers = mapOf("ETag" to "\"v1\""))),
                    Result.success(RemoteSyncHttpResponse(statusCode = 200, body = """{"revision":1}""")),
                    Result.success(RemoteSyncHttpResponse(statusCode = 200)),
                )
            )
        )
        val client = ObjectStorageSyncClient(
            providerType = SyncProviderType.TENCENT_COS,
            accessKeyId = "secret-id",
            secretAccessKey = "secret-key",
            bucket = "vault",
            endpoint = "cos.ap-shanghai.myqcloud.com",
            appId = "1250000000",
            objectKey = "sync/vault.json",
            transport = transport,
            now = { Instant.parse("2026-06-28T00:00:00Z") },
        )

        val metadata = client.metadata()
        val download = client.download()
        val upload = client.upload("""{"revision":2}""")

        assertEquals(200, metadata.statusCode)
        assertEquals(RemoteSyncResult(payload = """{"revision":1}""", statusCode = 200), download)
        assertEquals(RemoteSyncResult(payload = null, statusCode = 200), upload)
        assertEquals(listOf("HEAD", "GET", "PUT"), transport.requests.map { it.method })
        transport.requests.forEach { request ->
            assertEquals("https://vault-1250000000.cos.ap-shanghai.myqcloud.com/sync/vault.json", request.url.toString())
            val authorization = assertNotNull(request.headers["Authorization"])
            assertTrue(authorization.contains("q-sign-algorithm=sha1"))
            assertTrue(authorization.contains("q-ak=secret-id"))
            assertTrue(authorization.contains("q-signature="))
        }
        assertEquals("application/json", transport.requests.last().headers["Content-Type"])
    }

    @Test
    fun aliyunOssClientUsesOssV4SigningHeaders() {
        val transport = FakeRemoteSyncTransport(
            responses = ArrayDeque(
                listOf(
                    Result.success(RemoteSyncHttpResponse(statusCode = 200, body = """{"revision":1}"""))
                )
            )
        )
        val client = ObjectStorageSyncClient(
            providerType = SyncProviderType.ALIYUN_OSS,
            accessKeyId = "ak",
            secretAccessKey = "sk",
            bucket = "vault",
            endpoint = "oss-cn-hangzhou.aliyuncs.com",
            objectKey = "sync/vault.json",
            transport = transport,
            now = { Instant.parse("2026-06-28T00:00:00Z") },
        )

        val result = client.download()

        assertEquals(RemoteSyncResult(payload = """{"revision":1}""", statusCode = 200), result)
        val request = transport.requests.single()
        assertEquals("https://vault.oss-cn-hangzhou.aliyuncs.com/sync/vault.json", request.url.toString())
        assertEquals("20260628T000000Z", request.headers["x-oss-date"])
        assertNotNull(request.headers["x-oss-content-sha256"])
        val authorization = assertNotNull(request.headers["Authorization"])
        assertTrue(authorization.startsWith("OSS4-HMAC-SHA256 Credential=ak/20260628/cn-hangzhou/oss/aliyun_v4_request"))
        assertTrue(authorization.contains("AdditionalHeaders=host;x-oss-content-sha256;x-oss-date"))
        assertTrue(authorization.contains("Signature="))
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
