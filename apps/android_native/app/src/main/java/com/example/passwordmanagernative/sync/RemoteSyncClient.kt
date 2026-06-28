package com.example.passwordmanagernative.sync

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.SocketTimeoutException
import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.nio.charset.StandardCharsets
import java.util.Base64
import java.util.Locale
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

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

class ObjectStorageSyncClient(
    private val providerType: SyncProviderType,
    private val accessKeyId: String,
    private val secretAccessKey: String,
    private val bucket: String,
    private val endpoint: String,
    private val appId: String = "",
    private val customUrl: String = "",
    private val objectKey: String = "vault.sync.json",
    private val transport: RemoteSyncHttpTransport = UrlConnectionRemoteSyncTransport(),
    private val now: () -> Instant = { Instant.now() },
) : RemoteSyncClient {
    override fun metadata(): RemoteSyncMetadata =
        performSigned(method = "HEAD", payload = null, contentType = null).toMetadataResult()

    override fun download(): RemoteSyncResult =
        performSigned(method = "GET", payload = null, contentType = null).toDownloadSyncResult()

    override fun upload(payload: String): RemoteSyncResult =
        performSigned(method = "PUT", payload = payload, contentType = "application/json").toUploadSyncResult()

    private fun performSigned(method: String, payload: String?, contentType: String?): Result<RemoteSyncHttpResponse> =
        runCatching {
            val body = payload.orEmpty()
            val uri = buildObjectUri()
            val headers = when (providerType) {
                SyncProviderType.TENCENT_COS -> tencentCosHeaders(uri, method, contentType)
                SyncProviderType.ALIYUN_OSS -> aliyunOssHeaders(uri, method, body, contentType)
                else -> throw IllegalArgumentException("Object storage sync requires Tencent COS or Alibaba Cloud OSS.")
            }
            transport.perform(
                RemoteSyncRequest(
                    url = uri,
                    method = method,
                    headers = headers,
                    body = payload,
                )
            )
        }

    private fun Result<RemoteSyncHttpResponse>.toMetadataResult(): RemoteSyncMetadata =
        fold(
            onSuccess = { it.toMetadata() },
            onFailure = { error ->
                RemoteSyncMetadata(statusCode = if (error is SocketTimeoutException) 408 else 503)
            },
        )

    private fun Result<RemoteSyncHttpResponse>.toDownloadSyncResult(): RemoteSyncResult =
        fold(
            onSuccess = { it.toDownloadResult() },
            onFailure = { error ->
                RemoteSyncResult(payload = null, statusCode = if (error is SocketTimeoutException) 408 else 503)
            },
        )

    private fun Result<RemoteSyncHttpResponse>.toUploadSyncResult(): RemoteSyncResult =
        fold(
            onSuccess = { RemoteSyncResult(payload = null, statusCode = it.statusCode) },
            onFailure = { error ->
                RemoteSyncResult(payload = null, statusCode = if (error is SocketTimeoutException) 408 else 503)
            },
        )

    private fun buildObjectUri(): URI {
        val base = if (customUrl.isNotBlank()) {
            customUrl
        } else {
            endpointWithBucketHost(normalizedEndpoint(), resolvedBucket())
        }
        val baseUri = URI(normalizedEndpointUrl(base))
        val basePath = baseUri.path.orEmpty().trimEnd('/')
        val keyPath = objectKey.trim().ifBlank { "vault.sync.json" }.trimStart('/')
        val objectPath = if (basePath.isBlank()) {
            "/$keyPath"
        } else {
            "${basePath.removeSuffix("/")}/$keyPath"
        }
        return URI(
            baseUri.scheme,
            baseUri.userInfo,
            baseUri.host,
            baseUri.port,
            objectPath,
            baseUri.query,
            baseUri.fragment,
        )
    }

    private fun normalizedEndpoint(): String =
        normalizedEndpointUrl(endpoint.trim().trimEnd('/'))

    private fun endpointWithBucketHost(endpoint: String, bucket: String): String {
        val uri = URI(normalizedEndpointUrl(endpoint.trim().trimEnd('/')))
        val host = uri.host.orEmpty()
        if (host.isBlank()) {
            throw IllegalArgumentException("Object storage endpoint is invalid.")
        }
        val resolvedHost = if (host.startsWith("$bucket.", ignoreCase = true)) host else "$bucket.$host"
        return URI(
            uri.scheme,
            uri.userInfo,
            resolvedHost,
            uri.port,
            uri.path.orEmpty().trimEnd('/'),
            uri.query,
            uri.fragment,
        ).toString().trimEnd('/')
    }

    private fun resolvedBucket(): String {
        val trimmedBucket = bucket.trim()
        val trimmedAppId = appId.trim()
        if (providerType != SyncProviderType.TENCENT_COS || trimmedAppId.isBlank()) {
            return trimmedBucket
        }
        return if (trimmedBucket.endsWith("-$trimmedAppId")) trimmedBucket else "$trimmedBucket-$trimmedAppId"
    }

    private fun tencentCosHeaders(uri: URI, method: String, contentType: String?): Map<String, String> {
        val epochSeconds = now().epochSecond
        val signTime = "$epochSeconds;${epochSeconds + SIGNATURE_TTL_SECONDS}"
        val signedHeaders = linkedMapOf("host" to uri.authority.lowercase(Locale.US))
        if (!contentType.isNullOrBlank()) {
            signedHeaders["content-type"] = contentType
        }
        val headerList = signedHeaders.keys.sorted().joinToString(";")
        val headerString = signedHeaders.toSortedMap().entries.joinToString("&") { (name, value) ->
            "${percentEncode(name)}=${percentEncode(value.trim())}"
        }
        val urlParams = parseQuery(uri.rawQuery).toSortedMap()
        val urlParamList = urlParams.keys.joinToString(";")
        val urlParamString = urlParams.entries.joinToString("&") { (name, value) ->
            "${percentEncode(name.lowercase(Locale.US))}=${percentEncode(value)}"
        }
        val httpString = listOf(
            method.lowercase(Locale.US),
            uri.rawPath.ifBlank { "/" },
            urlParamString,
            headerString,
            "",
        ).joinToString("\n")
        val stringToSign = listOf(
            "sha1",
            signTime,
            sha1Hex(httpString),
            "",
        ).joinToString("\n")
        val signKey = hmacSha1Hex(secretAccessKey.toByteArray(StandardCharsets.UTF_8), signTime)
        val signature = hmacSha1Hex(signKey.toByteArray(StandardCharsets.UTF_8), stringToSign)
        val authorization = listOf(
            "q-sign-algorithm=sha1",
            "q-ak=${percentEncode(accessKeyId)}",
            "q-sign-time=$signTime",
            "q-key-time=$signTime",
            "q-header-list=$headerList",
            "q-url-param-list=$urlParamList",
            "q-signature=$signature",
        ).joinToString("&")
        return buildMap {
            put("Host", uri.authority.lowercase(Locale.US))
            contentType?.takeIf { it.isNotBlank() }?.let { put("Content-Type", it) }
            put("Authorization", authorization)
        }
    }

    private fun aliyunOssHeaders(uri: URI, method: String, body: String, contentType: String?): Map<String, String> {
        val timestamp = ALIYUN_DATE_TIME_FORMAT.format(now())
        val date = timestamp.take(8)
        val region = aliyunRegion(uri)
        val payloadHash = sha256Hex(body)
        val signedHeaders = linkedMapOf(
            "host" to uri.authority.lowercase(Locale.US),
            "x-oss-content-sha256" to payloadHash,
            "x-oss-date" to timestamp,
        )
        if (!contentType.isNullOrBlank()) {
            signedHeaders["content-type"] = contentType
        }
        val sortedHeaders = signedHeaders.toSortedMap()
        val additionalHeaders = sortedHeaders.keys.joinToString(";")
        val canonicalHeaders = sortedHeaders.entries.joinToString("") { (name, value) ->
            "$name:${value.trim()}\n"
        }
        val canonicalRequest = listOf(
            method.uppercase(Locale.US),
            uri.rawPath.ifBlank { "/" },
            canonicalQuery(uri.rawQuery),
            canonicalHeaders,
            additionalHeaders,
            payloadHash,
        ).joinToString("\n")
        val scope = "$date/$region/oss/aliyun_v4_request"
        val stringToSign = listOf(
            "OSS4-HMAC-SHA256",
            timestamp,
            scope,
            sha256Hex(canonicalRequest),
        ).joinToString("\n")
        val signingKey = aliyunSigningKey(secretAccessKey, date, region)
        val signature = hmacSha256Hex(signingKey, stringToSign)
        val authorization = "OSS4-HMAC-SHA256 Credential=${percentEncode(accessKeyId)}/$scope,AdditionalHeaders=$additionalHeaders,Signature=$signature"
        return buildMap {
            put("Host", uri.authority.lowercase(Locale.US))
            contentType?.takeIf { it.isNotBlank() }?.let { put("Content-Type", it) }
            put("x-oss-content-sha256", payloadHash)
            put("x-oss-date", timestamp)
            put("Authorization", authorization)
        }
    }

    private fun aliyunRegion(uri: URI): String {
        val candidates = listOf(endpoint, customUrl, uri.host.orEmpty())
        candidates.forEach { candidate ->
            ALIYUN_REGION_REGEX.find(candidate)?.groupValues?.getOrNull(1)?.let { return it }
        }
        throw IllegalArgumentException("Alibaba Cloud OSS endpoint must include a region for OSS V2 signing.")
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

private fun normalizedEndpointUrl(value: String): String {
    val trimmed = value.trim()
    if (trimmed.startsWith("http://", ignoreCase = true) || trimmed.startsWith("https://", ignoreCase = true)) {
        return trimmed
    }
    return "https://$trimmed"
}

private fun parseQuery(rawQuery: String?): Map<String, String> {
    if (rawQuery.isNullOrBlank()) return emptyMap()
    return rawQuery.split("&")
        .filter { it.isNotBlank() }
        .associate { part ->
            val index = part.indexOf("=")
            val name = if (index >= 0) part.substring(0, index) else part
            val value = if (index >= 0) part.substring(index + 1) else ""
            name.lowercase(Locale.US) to value
        }
}

private fun canonicalQuery(rawQuery: String?): String =
    parseQuery(rawQuery).toSortedMap().entries.joinToString("&") { (name, value) ->
        "${percentEncode(name)}=${percentEncode(value)}"
    }

private fun percentEncode(value: String): String {
    val builder = StringBuilder()
    value.toByteArray(StandardCharsets.UTF_8).forEach { raw ->
        val byte = raw.toInt() and 0xff
        val char = byte.toChar()
        if (char in 'A'..'Z' || char in 'a'..'z' || char in '0'..'9' || char == '-' || char == '_' || char == '.' || char == '~') {
            builder.append(char)
        } else {
            builder.append('%')
            builder.append(byte.toString(16).uppercase(Locale.US).padStart(2, '0'))
        }
    }
    return builder.toString()
}

private fun sha1Hex(value: String): String =
    MessageDigest.getInstance("SHA-1")
        .digest(value.toByteArray(StandardCharsets.UTF_8))
        .toHex()

private fun sha256Hex(value: String): String =
    MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(StandardCharsets.UTF_8))
        .toHex()

private fun hmacSha1(key: ByteArray, value: String): ByteArray =
    hmac("HmacSHA1", key, value)

private fun hmacSha1Hex(key: ByteArray, value: String): String =
    hmacSha1(key, value).toHex()

private fun hmacSha256(key: ByteArray, value: String): ByteArray =
    hmac("HmacSHA256", key, value)

private fun hmacSha256Hex(key: ByteArray, value: String): String =
    hmacSha256(key, value).toHex()

private fun hmac(algorithm: String, key: ByteArray, value: String): ByteArray {
    val mac = Mac.getInstance(algorithm)
    mac.init(SecretKeySpec(key, algorithm))
    return mac.doFinal(value.toByteArray(StandardCharsets.UTF_8))
}

private fun aliyunSigningKey(secret: String, date: String, region: String): ByteArray {
    val dateKey = hmacSha256("aliyun_v4$secret".toByteArray(StandardCharsets.UTF_8), date)
    val regionKey = hmacSha256(dateKey, region)
    val serviceKey = hmacSha256(regionKey, "oss")
    return hmacSha256(serviceKey, "aliyun_v4_request")
}

private fun ByteArray.toHex(): String =
    joinToString("") { byte -> (byte.toInt() and 0xff).toString(16).padStart(2, '0') }

private const val NETWORK_TIMEOUT_MILLIS = 12_000
private const val SIGNATURE_TTL_SECONDS = 15 * 60L
private val ALIYUN_DATE_TIME_FORMAT: DateTimeFormatter =
    DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'").withZone(ZoneOffset.UTC)
private val ALIYUN_REGION_REGEX = Regex("""oss[-.]([a-z0-9-]+)\.aliyuncs\.com""", RegexOption.IGNORE_CASE)
