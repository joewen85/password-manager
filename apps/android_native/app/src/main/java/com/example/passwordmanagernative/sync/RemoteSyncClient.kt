package com.example.passwordmanagernative.sync

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.SocketTimeoutException
import java.nio.charset.StandardCharsets
import java.util.Base64

data class RemoteSyncResult(
    val payload: String?,
    val statusCode: Int,
)

data class RemoteSyncMetadata(
    val statusCode: Int,
    val eTag: String? = null,
    val lastModified: String? = null,
    val contentLength: Long? = null,
) {
    val fingerprint: String?
        get() {
            val strongParts = listOfNotNull(
                eTag?.trim()?.takeIf { it.isNotEmpty() }?.let { "etag:$it" },
                lastModified?.trim()?.takeIf { it.isNotEmpty() }?.let { "modified:$it" },
            )
            if (strongParts.isEmpty()) {
                return null
            }
            return (strongParts + listOfNotNull(contentLength?.takeIf { it >= 0 }?.let { "length:$it" }))
                .joinToString("|")
        }
}

interface RemoteSyncClient {
    fun metadata(): RemoteSyncMetadata = RemoteSyncMetadata(statusCode = 501)
    fun download(): RemoteSyncResult
    fun upload(payload: String): RemoteSyncResult
}

data class RemoteSyncRequest(
    val url: URI,
    val method: String,
    val headers: Map<String, String> = emptyMap(),
    val body: String? = null,
)

data class RemoteSyncHttpResponse(
    val statusCode: Int,
    val body: String? = null,
    val headers: Map<String, String> = emptyMap(),
)

interface RemoteSyncHttpTransport {
    @Throws(IOException::class)
    fun perform(request: RemoteSyncRequest): RemoteSyncHttpResponse
}

class UrlConnectionRemoteSyncTransport(
    private val timeoutMillis: Int = NETWORK_TIMEOUT_MILLIS,
) : RemoteSyncHttpTransport {
    override fun perform(request: RemoteSyncRequest): RemoteSyncHttpResponse {
        val connection = request.url.toURL().openConnection() as HttpURLConnection
        connection.requestMethod = request.method
        connection.connectTimeout = timeoutMillis
        connection.readTimeout = timeoutMillis
        request.headers.forEach { (name, value) ->
            connection.setRequestProperty(name, value)
        }
        request.body?.let { body ->
            connection.doOutput = true
            connection.outputStream.use { output ->
                output.write(body.toByteArray(StandardCharsets.UTF_8))
            }
        }

        val statusCode = connection.responseCode
        val stream = if (statusCode >= 400) connection.errorStream else connection.inputStream
        val body = stream?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() }
        connection.disconnect()
        return RemoteSyncHttpResponse(
            statusCode = statusCode,
            body = body,
            headers = connection.headerFields
                .orEmpty()
                .mapNotNull { (name, values) ->
                    name?.let { it to values.orEmpty().joinToString(",") }
                }
                .toMap(),
        )
    }
}

class WebDavSyncClient(
    private val baseUrl: String,
    private val remotePath: String,
    private val username: String? = null,
    private val password: String? = null,
    private val transport: RemoteSyncHttpTransport = UrlConnectionRemoteSyncTransport(),
) : RemoteSyncClient {
    override fun metadata(): RemoteSyncMetadata =
        try {
            val response = transport.perform(
                RemoteSyncRequest(
                    url = buildUri(),
                    method = "HEAD",
                    headers = authHeaders(),
                )
            )
            response.toMetadata()
        } catch (_: SocketTimeoutException) {
            RemoteSyncMetadata(statusCode = 408)
        } catch (_: Exception) {
            RemoteSyncMetadata(statusCode = 503)
        }

    override fun download(): RemoteSyncResult =
        try {
            val response = transport.perform(
                RemoteSyncRequest(
                    url = buildUri(),
                    method = "GET",
                    headers = authHeaders(),
                )
            )
            response.toDownloadResult()
        } catch (_: SocketTimeoutException) {
            RemoteSyncResult(payload = null, statusCode = 408)
        } catch (_: Exception) {
            RemoteSyncResult(payload = null, statusCode = 503)
        }

    override fun upload(payload: String): RemoteSyncResult =
        try {
            val response = transport.perform(
                RemoteSyncRequest(
                    url = buildUri(),
                    method = "PUT",
                    headers = mapOf("Content-Type" to "application/json") + authHeaders(),
                    body = payload,
                )
            )
            RemoteSyncResult(payload = null, statusCode = response.statusCode)
        } catch (_: SocketTimeoutException) {
            RemoteSyncResult(payload = null, statusCode = 408)
        } catch (_: Exception) {
            RemoteSyncResult(payload = null, statusCode = 503)
        }

    private fun buildUri(): URI {
        val base = URI(baseUrl.trim())
        val path = normalizedPath()
        val basePath = base.path.orEmpty()
        val trimmedBasePath = if (basePath.endsWith("/")) basePath.dropLast(1) else basePath
        return URI(
            base.scheme,
            base.userInfo,
            base.host,
            base.port,
            "$trimmedBasePath$path",
            base.query,
            base.fragment,
        )
    }

    private fun normalizedPath(): String {
        var path = remotePath.trim()
        if (path.isEmpty()) {
            path = "/vault.json"
        }
        if (!path.startsWith("/")) {
            path = "/$path"
        }
        if (path.endsWith("/")) {
            path += "vault.json"
        }
        return path
    }

    private fun authHeaders(): Map<String, String> {
        val resolvedUsername = username.orEmpty()
        val resolvedPassword = password.orEmpty()
        if (resolvedUsername.isEmpty() && resolvedPassword.isEmpty()) {
            return emptyMap()
        }
        val token = Base64.getEncoder()
            .encodeToString("$resolvedUsername:$resolvedPassword".toByteArray(StandardCharsets.UTF_8))
        return mapOf("Authorization" to "Basic $token")
    }
}

class PresignedUrlSyncClient(
    private val downloadUrl: String,
    private val uploadUrl: String,
    private val transport: RemoteSyncHttpTransport = UrlConnectionRemoteSyncTransport(),
) : RemoteSyncClient {
    override fun metadata(): RemoteSyncMetadata {
        val trimmedUrl = downloadUrl.trim()
        if (trimmedUrl.isEmpty()) {
            return RemoteSyncMetadata(statusCode = 400)
        }
        return try {
            val response = transport.perform(
                RemoteSyncRequest(
                    url = URI(trimmedUrl),
                    method = "HEAD",
                )
            )
            response.toMetadata()
        } catch (_: SocketTimeoutException) {
            RemoteSyncMetadata(statusCode = 408)
        } catch (_: Exception) {
            RemoteSyncMetadata(statusCode = 503)
        }
    }

    override fun download(): RemoteSyncResult {
        val trimmedUrl = downloadUrl.trim()
        if (trimmedUrl.isEmpty()) {
            return RemoteSyncResult(payload = null, statusCode = 400)
        }
        return try {
            val response = transport.perform(
                RemoteSyncRequest(
                    url = URI(trimmedUrl),
                    method = "GET",
                )
            )
            response.toDownloadResult()
        } catch (_: SocketTimeoutException) {
            RemoteSyncResult(payload = null, statusCode = 408)
        } catch (_: Exception) {
            RemoteSyncResult(payload = null, statusCode = 503)
        }
    }

    override fun upload(payload: String): RemoteSyncResult {
        val trimmedUrl = uploadUrl.trim()
        if (trimmedUrl.isEmpty()) {
            return RemoteSyncResult(payload = null, statusCode = 400)
        }
        return try {
            val response = transport.perform(
                RemoteSyncRequest(
                    url = URI(trimmedUrl),
                    method = "PUT",
                    headers = mapOf("Content-Type" to "application/json"),
                    body = payload,
                )
            )
            RemoteSyncResult(payload = null, statusCode = response.statusCode)
        } catch (_: SocketTimeoutException) {
            RemoteSyncResult(payload = null, statusCode = 408)
        } catch (_: Exception) {
            RemoteSyncResult(payload = null, statusCode = 503)
        }
    }
}

private fun RemoteSyncHttpResponse.toDownloadResult(): RemoteSyncResult {
    if (statusCode == 404 || statusCode == 204) {
        return RemoteSyncResult(payload = null, statusCode = 404)
    }
    return RemoteSyncResult(
        payload = body?.takeIf { it.isNotEmpty() },
        statusCode = statusCode,
    )
}

private fun RemoteSyncHttpResponse.toMetadata(): RemoteSyncMetadata {
    if (statusCode == 404 || statusCode == 204) {
        return RemoteSyncMetadata(statusCode = 404)
    }
    return RemoteSyncMetadata(
        statusCode = statusCode,
        eTag = headerValue("ETag"),
        lastModified = headerValue("Last-Modified"),
        contentLength = headerValue("Content-Length")?.toLongOrNull(),
    )
}

private fun RemoteSyncHttpResponse.headerValue(name: String): String? =
    headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }
        ?.value
        ?.takeIf { it.isNotBlank() }

private const val NETWORK_TIMEOUT_MILLIS = 12_000
