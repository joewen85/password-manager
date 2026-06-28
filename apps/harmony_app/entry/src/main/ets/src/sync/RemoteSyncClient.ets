import { Context } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import AliyunOssClient, {
  ESignVersion,
  IGetObjectReq,
  IHeadObjectReq,
  IHarmonyClientInitOpts,
  IPutObjectReq,
} from '@aliyun/oss';
import {
  CosServiceError,
  CosXmlBaseService,
  CosXmlServiceConfig,
  GetObjectArrayBufferRequest,
  HeadObjectRequest,
  PutObjectRequest,
  QCloudCredential,
} from '@tencentcloud/cos';
import { SyncProviderType } from './SyncTypes';

export interface RemoteSyncResult {
  payload: string;
  statusCode: number;
}

export interface RemoteSyncMetadata {
  statusCode: number;
  eTag: string;
  lastModified: string;
  contentLength: number;
  fingerprint: string;
}

export interface RemoteSyncClient {
  metadata(): Promise<RemoteSyncMetadata>;
  download(): Promise<RemoteSyncResult>;
  upload(payload: string): Promise<RemoteSyncResult>;
}

interface HttpHeaderMap {
  Authorization?: string;
  Host?: string;
  'Content-Type'?: string;
  'x-oss-date'?: string;
  'x-oss-content-sha256'?: string;
}

interface HttpTextResponse {
  statusCode: number;
  body: string;
  headers: Record<string, string>;
}

interface ParsedObjectUri {
  scheme: string;
  authority: string;
  path: string;
  query: string;
}

interface SignedHeaderValue {
  name: string;
  value: string;
}

interface QueryParameter {
  name: string;
  value: string;
}

interface AliyunSdkClient {
  getObject(request: IGetObjectReq): Promise<AliyunSdkResponse>;
  headObject(request: IHeadObjectReq): Promise<AliyunSdkResponse>;
  putObject(request: IPutObjectReq): Promise<AliyunSdkResponse>;
}

interface AliyunSdkResponse {
  origRes?: AliyunOrigResponse;
  data?: ArrayBuffer;
}

interface AliyunOrigResponse {
  status?: number;
  headers?: Record<string, string>;
  data?: ArrayBuffer;
}

interface RequestStatusCarrier {
  status?: number;
  httpCode?: number;
  headers?: Record<string, string>;
}

export class WebDavSyncClient implements RemoteSyncClient {
  private readonly baseUrl: string;
  private readonly remotePath: string;
  private readonly username: string;
  private readonly password: string;

  constructor(
    baseUrl: string,
    remotePath: string,
    username: string = '',
    password: string = '',
  ) {
    this.baseUrl = baseUrl.trim();
    this.remotePath = remotePath.trim();
    this.username = username;
    this.password = password;
  }

  async download(): Promise<RemoteSyncResult> {
    const response = await requestText(
      this.buildUri(),
      http.RequestMethod.GET,
      this.headers(),
      '',
    );
    if (response.statusCode === 404 || response.statusCode === 204) {
      return { payload: '', statusCode: 404 };
    }
    return {
      payload: response.body,
      statusCode: response.statusCode,
    };
  }

  async metadata(): Promise<RemoteSyncMetadata> {
    const response = await requestText(
      this.buildUri(),
      http.RequestMethod.HEAD,
      this.headers(),
      '',
    );
    return metadataFromResponse(response);
  }

  async upload(payload: string): Promise<RemoteSyncResult> {
    const headers = mergeContentType(this.headers());

    const response = await requestText(
      this.buildUri(),
      http.RequestMethod.PUT,
      headers,
      payload,
    );

    return {
      payload: '',
      statusCode: response.statusCode,
    };
  }

  private buildUri(): string {
    const base = this.baseUrl.endsWith('/')
      ? this.baseUrl.slice(0, this.baseUrl.length - 1)
      : this.baseUrl;
    const path = normalizePath(this.remotePath);
    return `${base}${path}`;
  }

  private headers(): HttpHeaderMap {
    const headers = createHeaderMap();
    if (this.username.length === 0 && this.password.length === 0) {
      return headers;
    }

    const token = encodeBasicAuth(this.username, this.password);
    headers.Authorization = `Basic ${token}`;
    return headers;
  }
}

export class PresignedUrlSyncClient implements RemoteSyncClient {
  private readonly downloadUrl: string;
  private readonly uploadUrl: string;

  constructor(downloadUrl: string, uploadUrl: string) {
    this.downloadUrl = downloadUrl.trim();
    this.uploadUrl = uploadUrl.trim();
  }

  async download(): Promise<RemoteSyncResult> {
    if (this.downloadUrl.length === 0) {
      return { payload: '', statusCode: 400 };
    }

    const response = await requestText(
      this.downloadUrl,
      http.RequestMethod.GET,
      createHeaderMap(),
      '',
    );

    if (response.statusCode === 404 || response.statusCode === 204) {
      return { payload: '', statusCode: 404 };
    }

    return {
      payload: response.body,
      statusCode: response.statusCode,
    };
  }

  async metadata(): Promise<RemoteSyncMetadata> {
    if (this.downloadUrl.length === 0) {
      return emptyMetadata(400);
    }

    const response = await requestText(
      this.downloadUrl,
      http.RequestMethod.HEAD,
      createHeaderMap(),
      '',
    );
    return metadataFromResponse(response);
  }

  async upload(payload: string): Promise<RemoteSyncResult> {
    if (this.uploadUrl.length === 0) {
      return { payload: '', statusCode: 400 };
    }

    const headers = mergeContentType(createHeaderMap());

    const response = await requestText(
      this.uploadUrl,
      http.RequestMethod.PUT,
      headers,
      payload,
    );

    return {
      payload: '',
      statusCode: response.statusCode,
    };
  }
}

export class ObjectStorageSyncClient implements RemoteSyncClient {
  private readonly context: Context | null;
  private readonly providerType: SyncProviderType;
  private readonly accessKeyId: string;
  private readonly secretAccessKey: string;
  private readonly bucket: string;
  private readonly endpoint: string;
  private readonly appId: string;
  private readonly customUrl: string;
  private readonly objectKey: string;

  constructor(
    context: Context | null,
    providerType: SyncProviderType,
    accessKeyId: string,
    secretAccessKey: string,
    bucket: string,
    endpoint: string,
    appId: string = '',
    customUrl: string = '',
    objectKey: string = 'vault.sync.json',
  ) {
    this.context = context;
    this.providerType = providerType;
    this.accessKeyId = accessKeyId.trim();
    this.secretAccessKey = secretAccessKey.trim();
    this.bucket = bucket.trim();
    this.endpoint = endpoint.trim().length > 0
      ? endpoint.trim()
      : defaultObjectStorageEndpoint(providerType);
    this.appId = appId.trim();
    this.customUrl = customUrl.trim();
    this.objectKey = objectKey.trim().length > 0 ? objectKey.trim() : 'vault.sync.json';
  }

  async download(): Promise<RemoteSyncResult> {
    const sdkResponse = await this.trySdkDownload();
    if (sdkResponse !== null) {
      return sdkResponse;
    }
    const response = await this.performSigned(http.RequestMethod.GET, 'GET', '', '');
    if (response.statusCode === 404 || response.statusCode === 204) {
      return { payload: '', statusCode: 404 };
    }
    return {
      payload: response.body,
      statusCode: response.statusCode,
    };
  }

  async metadata(): Promise<RemoteSyncMetadata> {
    const sdkMetadata = await this.trySdkMetadata();
    if (sdkMetadata !== null) {
      return sdkMetadata;
    }
    const response = await this.performSigned(http.RequestMethod.HEAD, 'HEAD', '', '');
    return metadataFromResponse(response);
  }

  async upload(payload: string): Promise<RemoteSyncResult> {
    const sdkResponse = await this.trySdkUpload(payload);
    if (sdkResponse !== null) {
      return sdkResponse;
    }
    const response = await this.performSigned(
      http.RequestMethod.PUT,
      'PUT',
      payload,
      'application/json',
    );
    return {
      payload: '',
      statusCode: response.statusCode,
    };
  }

  private async trySdkDownload(): Promise<RemoteSyncResult | null> {
    if (this.providerType === SyncProviderType.TENCENT_COS) {
      if (!this.canUseTencentSdk()) {
        return null;
      }
      try {
        const buffer = await this.tencentCosService().getObjectToArrayBuffer(
          new GetObjectArrayBufferRequest(this.resolvedBucket(), this.objectKey),
        );
        return {
          payload: buffer === undefined ? '' : decodeUtf8(new Uint8Array(buffer)),
          statusCode: 200,
        };
      } catch (error) {
        const statusCode = objectStorageErrorStatus(error);
        if (statusCode === 404 || statusCode === 204) {
          return { payload: '', statusCode: 404 };
        }
        throw objectStorageError(error);
      }
    }
    if (this.providerType === SyncProviderType.ALIYUN_OSS) {
      if (!this.canUseAliyunSdk()) {
        return null;
      }
      try {
        const response = await this.aliyunOssClient().getObject(this.aliyunObjectRequest());
        const statusCode = response.origRes?.status ?? 200;
        if (statusCode === 404 || statusCode === 204) {
          return { payload: '', statusCode: 404 };
        }
        const body = response.data ?? response.origRes?.data;
        return {
          payload: body === undefined ? '' : decodeUtf8(new Uint8Array(body)),
          statusCode,
        };
      } catch (error) {
        const statusCode = objectStorageErrorStatus(error);
        if (statusCode === 404 || statusCode === 204) {
          return { payload: '', statusCode: 404 };
        }
        throw objectStorageError(error);
      }
    }
    return null;
  }

  private async trySdkMetadata(): Promise<RemoteSyncMetadata | null> {
    if (this.providerType === SyncProviderType.TENCENT_COS) {
      if (!this.canUseTencentSdk()) {
        return null;
      }
      try {
        const response = await this.tencentCosService().headObject(
          new HeadObjectRequest(this.resolvedBucket(), this.objectKey),
        );
        return metadataFromResponse({
          statusCode: response.httpCode ?? 200,
          body: '',
          headers: response.headers ?? {},
        });
      } catch (error) {
        const statusCode = objectStorageErrorStatus(error);
        if (statusCode === 404 || statusCode === 204) {
          return emptyMetadata(404);
        }
        throw objectStorageError(error);
      }
    }
    if (this.providerType === SyncProviderType.ALIYUN_OSS) {
      if (!this.canUseAliyunSdk()) {
        return null;
      }
      try {
        const response = await this.aliyunOssClient().headObject(this.aliyunHeadObjectRequest());
        return metadataFromResponse({
          statusCode: response.origRes?.status ?? 200,
          body: '',
          headers: response.origRes?.headers ?? {},
        });
      } catch (error) {
        const statusCode = objectStorageErrorStatus(error);
        if (statusCode === 404 || statusCode === 204) {
          return emptyMetadata(404);
        }
        throw objectStorageError(error);
      }
    }
    return null;
  }

  private async trySdkUpload(payload: string): Promise<RemoteSyncResult | null> {
    if (this.providerType === SyncProviderType.TENCENT_COS) {
      if (!this.canUseTencentSdk()) {
        return null;
      }
      const request = new PutObjectRequest(
        this.resolvedBucket(),
        this.objectKey,
        stringToArrayBuffer(payload),
      );
      await this.tencentCosService().putObject(request);
      return {
        payload: '',
        statusCode: 200,
      };
    }
    if (this.providerType === SyncProviderType.ALIYUN_OSS) {
      if (!this.canUseAliyunSdk()) {
        return null;
      }
      const request = this.aliyunPutObjectRequest(payload);
      const response = await this.aliyunOssClient().putObject(request);
      return {
        payload: '',
        statusCode: response.origRes?.status ?? 200,
      };
    }
    return null;
  }

  private canUseTencentSdk(): boolean {
    return this.context !== null && this.customUrl.length === 0;
  }

  private canUseAliyunSdk(): boolean {
    return this.customUrl.length === 0;
  }

  private tencentCosService(): CosXmlBaseService {
    if (this.context === null) {
      throw new Error('Tencent COS SDK requires Harmony Context');
    }
    const config = new CosXmlServiceConfig(tencentRegion(this.endpoint));
    const endpointHost = endpointHostOnly(this.endpoint);
    if (endpointHost.length > 0) {
      config.host = endpointHost.startsWith('${bucket}.')
        ? endpointHost
        : `\${bucket}.${endpointHost}`;
    }
    config.maxRetryCount = 2;
    const callback = () => {
      const credential = new QCloudCredential();
      credential.secretID = this.accessKeyId;
      credential.secretKey = this.secretAccessKey;
      return Promise.resolve(credential);
    };
    return new CosXmlBaseService(this.context.getApplicationContext(), config, callback);
  }

  private aliyunOssClient(): AliyunSdkClient {
    const endpoint = normalizedEndpointUrl(this.endpoint);
    const options: IHarmonyClientInitOpts = {
      accessKeyId: this.accessKeyId,
      accessKeySecret: this.secretAccessKey,
      endpoint,
      region: aliyunRegion(this.endpoint, this.customUrl, endpoint),
      secure: endpoint.toLowerCase().startsWith('https://'),
      signVersion: ESignVersion.V4,
      retryMax: 2,
      timeout: 15000,
    };
    const client = new AliyunOssClient(options) as AliyunSdkClient;
    return client;
  }

  private aliyunObjectRequest(): IGetObjectReq {
    return {
      bucket: this.bucket,
      key: this.objectKey,
    };
  }

  private aliyunHeadObjectRequest(): IHeadObjectReq {
    return {
      bucket: this.bucket,
      key: this.objectKey,
    };
  }

  private aliyunPutObjectRequest(payload: string): IPutObjectReq {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
    };
    return {
      bucket: this.bucket,
      key: this.objectKey,
      data: payload,
      headers,
    };
  }

  private async performSigned(
    requestMethod: http.RequestMethod,
    methodName: string,
    payload: string,
    contentType: string,
  ): Promise<HttpTextResponse> {
    const url = this.buildObjectUrl();
    const uri = parseObjectUri(url);
    let headers: HttpHeaderMap;
    if (this.providerType === SyncProviderType.TENCENT_COS) {
      headers = await this.tencentCosHeaders(uri, methodName, contentType);
    } else if (this.providerType === SyncProviderType.ALIYUN_OSS) {
      headers = await this.aliyunOssHeaders(uri, methodName, payload, contentType);
    } else {
      throw new Error('Object storage sync requires Tencent COS or Alibaba Cloud OSS');
    }
    return await requestText(url, requestMethod, headers, payload);
  }

  private buildObjectUrl(): string {
    const base = this.customUrl.length > 0
      ? normalizedEndpointUrl(this.customUrl)
      : endpointWithBucketHost(
        normalizedEndpointUrl(this.endpoint),
        this.resolvedBucket(),
      );
    const uri = parseObjectUri(base);
    const basePath = trimTrailingSlash(uri.path);
    const keyPath = trimLeadingSlash(this.objectKey.length > 0 ? this.objectKey : 'vault.sync.json');
    const objectPath = basePath.length === 0 ? `/${keyPath}` : `${basePath}/${keyPath}`;
    const query = uri.query.length > 0 ? `?${uri.query}` : '';
    return `${uri.scheme}://${uri.authority}${objectPath}${query}`;
  }

  private resolvedBucket(): string {
    if (this.providerType !== SyncProviderType.TENCENT_COS || this.appId.length === 0) {
      return this.bucket;
    }
    return this.bucket.endsWith(`-${this.appId}`) ? this.bucket : `${this.bucket}-${this.appId}`;
  }

  private async tencentCosHeaders(
    uri: ParsedObjectUri,
    methodName: string,
    contentType: string,
  ): Promise<HttpHeaderMap> {
    const epochSeconds = Math.floor(Date.now() / 1000);
    const signTime = `${epochSeconds};${epochSeconds + 15 * 60}`;
    const signedHeaders: SignedHeaderValue[] = [
      { name: 'host', value: uri.authority.toLowerCase() },
    ];
    if (contentType.length > 0) {
      signedHeaders.push({ name: 'content-type', value: contentType });
    }
    const sortedHeaders = sortSignedHeaders(signedHeaders);
    const headerList = sortedHeaders.map((header: SignedHeaderValue) => header.name).join(';');
    const headerString = sortedHeaders
      .map((header: SignedHeaderValue) =>
        `${percentEncode(header.name)}=${percentEncode(header.value.trim())}`)
      .join('&');
    const queryParams = sortQueryParameters(parseQuery(uri.query));
    const urlParamList = queryParams.map((parameter: QueryParameter) => parameter.name).join(';');
    const urlParamString = queryParams
      .map((parameter: QueryParameter) =>
        `${percentEncode(parameter.name)}=${percentEncode(parameter.value)}`)
      .join('&');
    const httpString = [
      methodName.toLowerCase(),
      uri.path.length > 0 ? uri.path : '/',
      urlParamString,
      headerString,
      '',
    ].join('\n');
    const stringToSign = [
      'sha1',
      signTime,
      await sha1Hex(httpString),
      '',
    ].join('\n');
    const signKey = await hmacSha1(encodeUtf8(this.secretAccessKey), signTime);
    const signature = await hmacSha1Hex(signKey, stringToSign);
    const authorization = [
      'q-sign-algorithm=sha1',
      `q-ak=${percentEncode(this.accessKeyId)}`,
      `q-sign-time=${signTime}`,
      `q-key-time=${signTime}`,
      `q-header-list=${headerList}`,
      `q-url-param-list=${urlParamList}`,
      `q-signature=${signature}`,
    ].join('&');

    if (contentType.length > 0) {
      return {
        Host: uri.authority.toLowerCase(),
        Authorization: authorization,
        'Content-Type': contentType,
      };
    }
    return {
      Host: uri.authority.toLowerCase(),
      Authorization: authorization,
    };
  }

  private async aliyunOssHeaders(
    uri: ParsedObjectUri,
    methodName: string,
    payload: string,
    contentType: string,
  ): Promise<HttpHeaderMap> {
    const timestamp = aliyunTimestamp(new Date());
    const date = timestamp.substring(0, 8);
    const region = aliyunRegion(this.endpoint, this.customUrl, uri.authority);
    const payloadHash = await sha256Hex(payload);
    const signedHeaders: SignedHeaderValue[] = [
      { name: 'host', value: uri.authority.toLowerCase() },
      { name: 'x-oss-content-sha256', value: payloadHash },
      { name: 'x-oss-date', value: timestamp },
    ];
    if (contentType.length > 0) {
      signedHeaders.push({ name: 'content-type', value: contentType });
    }
    const sortedHeaders = sortSignedHeaders(signedHeaders);
    const additionalHeaders = sortedHeaders.map((header: SignedHeaderValue) => header.name).join(';');
    const canonicalHeaders = sortedHeaders
      .map((header: SignedHeaderValue) => `${header.name}:${header.value.trim()}\n`)
      .join('');
    const canonicalRequest = [
      methodName.toUpperCase(),
      uri.path.length > 0 ? uri.path : '/',
      canonicalQuery(uri.query),
      canonicalHeaders,
      additionalHeaders,
      payloadHash,
    ].join('\n');
    const scope = `${date}/${region}/oss/aliyun_v4_request`;
    const stringToSign = [
      'OSS4-HMAC-SHA256',
      timestamp,
      scope,
      await sha256Hex(canonicalRequest),
    ].join('\n');
    const signingKey = await aliyunSigningKey(this.secretAccessKey, date, region);
    const signature = await hmacSha256Hex(signingKey, stringToSign);
    const authorization =
      `OSS4-HMAC-SHA256 Credential=${percentEncode(this.accessKeyId)}/${scope},AdditionalHeaders=${additionalHeaders},Signature=${signature}`;

    if (contentType.length > 0) {
      return {
        Host: uri.authority.toLowerCase(),
        Authorization: authorization,
        'Content-Type': contentType,
        'x-oss-content-sha256': payloadHash,
        'x-oss-date': timestamp,
      };
    }
    return {
      Host: uri.authority.toLowerCase(),
      Authorization: authorization,
      'x-oss-content-sha256': payloadHash,
      'x-oss-date': timestamp,
    };
  }
}

async function requestText(
  url: string,
  method: http.RequestMethod,
  headers: HttpHeaderMap,
  body: string,
): Promise<HttpTextResponse> {
  const httpRequest = http.createHttp();
  try {
    const options: http.HttpRequestOptions = {
      method,
      header: headers,
      readTimeout: 15000,
      connectTimeout: 15000,
      expectDataType: http.HttpDataType.STRING,
    };

    if (body.length > 0) {
      options.extraData = body;
    }

    const response = await httpRequest.request(url, options);
    return {
      statusCode: Number(response.responseCode),
      body: responseResultToText(response.result),
      headers: normalizeResponseHeaders(response.header),
    };
  } catch (error) {
    throw new Error(`HTTP request failed: ${error}`);
  } finally {
    try {
      httpRequest.destroy();
    } catch (error) {
      console.error(`Destroy http request failed: ${error}`);
    }
  }
}

function metadataFromResponse(response: HttpTextResponse): RemoteSyncMetadata {
  if (response.statusCode === 404 || response.statusCode === 204) {
    return emptyMetadata(404);
  }
  const eTag = headerValue(response.headers, 'ETag');
  const lastModified = headerValue(response.headers, 'Last-Modified');
  const contentLength = Number(headerValue(response.headers, 'Content-Length'));
  const safeLength = Number.isFinite(contentLength) && contentLength >= 0 ? contentLength : -1;
  return {
    statusCode: response.statusCode,
    eTag,
    lastModified,
    contentLength: safeLength,
    fingerprint: buildFingerprint(eTag, lastModified, safeLength),
  };
}

function emptyMetadata(statusCode: number): RemoteSyncMetadata {
  return {
    statusCode,
    eTag: '',
    lastModified: '',
    contentLength: -1,
    fingerprint: '',
  };
}

function buildFingerprint(eTag: string, lastModified: string, contentLength: number): string {
  const strongParts: string[] = [];
  if (eTag.trim().length > 0) {
    strongParts.push(`etag:${eTag.trim()}`);
  }
  if (lastModified.trim().length > 0) {
    strongParts.push(`modified:${lastModified.trim()}`);
  }
  if (strongParts.length === 0) {
    return '';
  }
  if (contentLength >= 0) {
    strongParts.push(`length:${contentLength}`);
  }
  return strongParts.join('|');
}

function normalizeResponseHeaders(rawHeaders: Object | undefined): Record<string, string> {
  const output: Record<string, string> = {};
  if (rawHeaders === undefined || rawHeaders === null) {
    return output;
  }
  const record = rawHeaders as Record<string, string | string[] | number | undefined>;
  Object.keys(record).forEach((name: string) => {
    const value = record[name];
    if (Array.isArray(value)) {
      output[name] = value.join(',');
    } else if (value !== undefined) {
      output[name] = `${value}`;
    }
  });
  return output;
}

function headerValue(headers: Record<string, string>, name: string): string {
  const match = Object.keys(headers).find((key: string) => key.toLowerCase() === name.toLowerCase());
  if (match === undefined) {
    return '';
  }
  return headers[match] ?? '';
}

function responseResultToText(result: string | Object | ArrayBuffer): string {
  if (typeof result === 'string') {
    return result;
  }
  if (result instanceof ArrayBuffer) {
    return decodeUtf8(new Uint8Array(result));
  }
  return JSON.stringify(result);
}

function createHeaderMap(): HttpHeaderMap {
  const headers: HttpHeaderMap = {};
  return headers;
}

function mergeContentType(headers: HttpHeaderMap): HttpHeaderMap {
  const auth = headers.Authorization;
  if (auth !== undefined && auth.length > 0) {
    const output: HttpHeaderMap = {
      Authorization: auth,
      'Content-Type': 'application/json',
    };
    return output;
  }
  const output: HttpHeaderMap = {
    'Content-Type': 'application/json',
  };
  return output;
}

function normalizePath(path: string): string {
  let output = path.trim();
  if (output.length === 0) {
    output = '/vault.json';
  }
  if (!output.startsWith('/')) {
    output = `/${output}`;
  }
  if (output.endsWith('/')) {
    output = `${output}vault.json`;
  }
  return output;
}

function defaultObjectStorageEndpoint(providerType: SyncProviderType): string {
  if (providerType === SyncProviderType.TENCENT_COS) {
    return 'cos.ap-guangzhou.myqcloud.com';
  }
  if (providerType === SyncProviderType.ALIYUN_OSS) {
    return 'oss-cn-hangzhou.aliyuncs.com';
  }
  return '';
}

function normalizedEndpointUrl(value: string): string {
  const trimmed = value.trim();
  if (
    trimmed.toLowerCase().startsWith('http://') ||
    trimmed.toLowerCase().startsWith('https://')
  ) {
    return trimmed;
  }
  return `https://${trimmed}`;
}

function endpointHostOnly(value: string): string {
  const trimmed = value.trim();
  if (trimmed.length === 0) {
    return '';
  }
  return parseObjectUri(normalizedEndpointUrl(trimmed)).authority;
}

function endpointWithBucketHost(endpoint: string, bucket: string): string {
  const uri = parseObjectUri(endpoint);
  const host = uri.authority;
  const lowerHost = host.toLowerCase();
  const lowerBucketPrefix = `${bucket.toLowerCase()}.`;
  const resolvedHost = lowerHost.startsWith(lowerBucketPrefix)
    ? host
    : `${bucket}.${host}`;
  const path = uri.path.length > 0 ? trimTrailingSlash(uri.path) : '';
  const query = uri.query.length > 0 ? `?${uri.query}` : '';
  return `${uri.scheme}://${resolvedHost}${path}${query}`;
}

function tencentRegion(endpoint: string): string {
  const lower = endpoint.toLowerCase();
  const cosMarker = '.cos.';
  const cosIndex = lower.indexOf(cosMarker);
  if (cosIndex >= 0) {
    const start = cosIndex + cosMarker.length;
    const end = lower.indexOf('.', start);
    if (end > start) {
      return lower.substring(start, end);
    }
  }
  const directMarker = 'cos.';
  const directIndex = lower.indexOf(directMarker);
  if (directIndex >= 0) {
    const start = directIndex + directMarker.length;
    const end = lower.indexOf('.', start);
    if (end > start) {
      return lower.substring(start, end);
    }
  }
  return 'ap-guangzhou';
}

function parseObjectUri(url: string): ParsedObjectUri {
  const trimmed = normalizedEndpointUrl(url);
  const schemeMarker = '://';
  const schemeIndex = trimmed.indexOf(schemeMarker);
  if (schemeIndex <= 0) {
    throw new Error('Object storage endpoint is invalid');
  }
  const scheme = trimmed.substring(0, schemeIndex).toLowerCase();
  const afterScheme = trimmed.substring(schemeIndex + schemeMarker.length);
  const pathIndex = afterScheme.indexOf('/');
  const authority = pathIndex < 0 ? afterScheme : afterScheme.substring(0, pathIndex);
  if (authority.trim().length === 0) {
    throw new Error('Object storage endpoint host is empty');
  }
  const pathAndQuery = pathIndex < 0 ? '' : afterScheme.substring(pathIndex);
  const queryIndex = pathAndQuery.indexOf('?');
  const path = queryIndex < 0 ? pathAndQuery : pathAndQuery.substring(0, queryIndex);
  const query = queryIndex < 0 ? '' : pathAndQuery.substring(queryIndex + 1);
  return {
    scheme,
    authority,
    path: path.length > 0 ? path : '/',
    query,
  };
}

function parseQuery(rawQuery: string): QueryParameter[] {
  if (rawQuery.trim().length === 0) {
    return [];
  }
  const params: QueryParameter[] = [];
  rawQuery.split('&')
    .filter((part: string) => part.trim().length > 0)
    .forEach((part: string) => {
      const index = part.indexOf('=');
      const name = index >= 0 ? part.substring(0, index) : part;
      const value = index >= 0 ? part.substring(index + 1) : '';
      params.push({
        name: name.toLowerCase(),
        value,
      });
    });
  return params;
}

function canonicalQuery(rawQuery: string): string {
  return sortQueryParameters(parseQuery(rawQuery))
    .map((parameter: QueryParameter) =>
      `${percentEncode(parameter.name)}=${percentEncode(parameter.value)}`)
    .join('&');
}

function sortSignedHeaders(headers: SignedHeaderValue[]): SignedHeaderValue[] {
  const output = headers.map((header: SignedHeaderValue) => {
    const normalized: SignedHeaderValue = {
      name: header.name.toLowerCase(),
      value: header.value,
    };
    return normalized;
  });
  output.sort((left: SignedHeaderValue, right: SignedHeaderValue) =>
    left.name.localeCompare(right.name));
  return output;
}

function sortQueryParameters(params: QueryParameter[]): QueryParameter[] {
  const output = params.map((param: QueryParameter) => {
    const normalized: QueryParameter = {
      name: param.name.toLowerCase(),
      value: param.value,
    };
    return normalized;
  });
  output.sort((left: QueryParameter, right: QueryParameter) =>
    left.name.localeCompare(right.name));
  return output;
}

function trimLeadingSlash(value: string): string {
  let output = value.trim();
  while (output.startsWith('/')) {
    output = output.substring(1);
  }
  return output;
}

function trimTrailingSlash(value: string): string {
  let output = value.trim();
  while (output.endsWith('/')) {
    output = output.substring(0, output.length - 1);
  }
  return output;
}

function percentEncode(value: string): string {
  const bytes = encodeUtf8(value);
  let output = '';
  for (let index = 0; index < bytes.length; index++) {
    const byte = bytes[index];
    const char = String.fromCharCode(byte);
    if (
      (char >= 'A' && char <= 'Z') ||
      (char >= 'a' && char <= 'z') ||
      (char >= '0' && char <= '9') ||
      char === '-' ||
      char === '_' ||
      char === '.' ||
      char === '~'
    ) {
      output += char;
    } else {
      output += `%${byte.toString(16).toUpperCase().padStart(2, '0')}`;
    }
  }
  return output;
}

async function sha1Hex(value: string): Promise<string> {
  return await digestHex('SHA1', encodeUtf8(value));
}

async function sha256Hex(value: string): Promise<string> {
  return await digestHex('SHA256', encodeUtf8(value));
}

async function digestHex(algorithm: string, bytes: Uint8Array): Promise<string> {
  const md = cryptoFramework.createMd(algorithm);
  await md.update({ data: bytes });
  const output = await md.digest();
  return bytesToHex(output.data);
}

async function hmacSha1(key: Uint8Array, value: string): Promise<Uint8Array> {
  return await hmac('SHA1', key, value);
}

async function hmacSha1Hex(key: Uint8Array, value: string): Promise<string> {
  return bytesToHex(await hmacSha1(key, value));
}

async function hmacSha256(key: Uint8Array, value: string): Promise<Uint8Array> {
  return await hmac('SHA256', key, value);
}

async function hmacSha256Hex(key: Uint8Array, value: string): Promise<string> {
  return bytesToHex(await hmacSha256(key, value));
}

async function hmac(
  algorithm: string,
  keyBytes: Uint8Array,
  value: string,
): Promise<Uint8Array> {
  const key = await cryptoFramework
    .createSymKeyGenerator('HMAC')
    .convertKey({ data: keyBytes });
  const mac = cryptoFramework.createMac(algorithm);
  await mac.init(key);
  await mac.update({ data: encodeUtf8(value) });
  const output = await mac.doFinal();
  return output.data;
}

async function aliyunSigningKey(
  secret: string,
  date: string,
  region: string,
): Promise<Uint8Array> {
  const dateKey = await hmacSha256(encodeUtf8(`aliyun_v4${secret}`), date);
  const regionKey = await hmacSha256(dateKey, region);
  const serviceKey = await hmacSha256(regionKey, 'oss');
  return await hmacSha256(serviceKey, 'aliyun_v4_request');
}

function aliyunTimestamp(date: Date): string {
  const year = date.getUTCFullYear().toString().padStart(4, '0');
  const month = (date.getUTCMonth() + 1).toString().padStart(2, '0');
  const day = date.getUTCDate().toString().padStart(2, '0');
  const hour = date.getUTCHours().toString().padStart(2, '0');
  const minute = date.getUTCMinutes().toString().padStart(2, '0');
  const second = date.getUTCSeconds().toString().padStart(2, '0');
  return `${year}${month}${day}T${hour}${minute}${second}Z`;
}

function aliyunRegion(endpoint: string, customUrl: string, authority: string): string {
  const candidates = [endpoint, customUrl, authority];
  for (let index = 0; index < candidates.length; index++) {
    const match = ossRegionFromText(candidates[index]);
    if (match.length > 0) {
      return match;
    }
  }
  throw new Error('Alibaba Cloud OSS endpoint must include a region for V4 signing');
}

function ossRegionFromText(value: string): string {
  const lower = value.toLowerCase();
  const marker = 'oss-';
  let markerIndex = lower.indexOf(marker);
  if (markerIndex < 0) {
    markerIndex = lower.indexOf('oss.');
    if (markerIndex < 0) {
      return '';
    }
  }
  const start = markerIndex + marker.length;
  const end = lower.indexOf('.aliyuncs.com', start);
  if (end <= start) {
    return '';
  }
  return lower.substring(start, end);
}

function bytesToHex(bytes: Uint8Array): string {
  let output = '';
  for (let i = 0; i < bytes.length; i++) {
    output += bytes[i].toString(16).padStart(2, '0');
  }
  return output;
}

function objectStorageErrorStatus(error: Error | object): number {
  if (error instanceof CosServiceError) {
    return error.httpCode;
  }
  const carrier = error as RequestStatusCarrier;
  if (typeof carrier.status === 'number') {
    return carrier.status;
  }
  if (typeof carrier.httpCode === 'number') {
    return carrier.httpCode;
  }
  return 0;
}

function objectStorageError(error: Error | object): Error {
  if (error instanceof Error) {
    return error;
  }
  return new Error(`Object storage SDK request failed: ${JSON.stringify(error)}`);
}

function encodeBasicAuth(username: string, password: string): string {
  const raw = `${username}:${password}`;
  const helper = new util.Base64Helper();
  return helper.encodeToStringSync(encodeUtf8(raw));
}

function stringToArrayBuffer(text: string): ArrayBuffer {
  const bytes = encodeUtf8(text);
  const buffer = new ArrayBuffer(bytes.length);
  new Uint8Array(buffer).set(bytes);
  return buffer;
}

function encodeUtf8(text: string): Uint8Array {
  const normalized = unescape(encodeURIComponent(text));
  const bytes = new Uint8Array(normalized.length);
  for (let i = 0; i < normalized.length; i++) {
    bytes[i] = normalized.charCodeAt(i);
  }
  return bytes;
}

function decodeUtf8(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return decodeURIComponent(escape(binary));
}
