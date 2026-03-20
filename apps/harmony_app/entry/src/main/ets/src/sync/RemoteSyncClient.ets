import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

export interface RemoteSyncResult {
  payload: string;
  statusCode: number;
}

export interface RemoteSyncClient {
  download(): Promise<RemoteSyncResult>;
  upload(payload: string): Promise<RemoteSyncResult>;
}

interface HttpHeaderMap {
  Authorization?: string;
  'Content-Type'?: string;
}

interface HttpTextResponse {
  statusCode: number;
  body: string;
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

function encodeBasicAuth(username: string, password: string): string {
  const raw = `${username}:${password}`;
  const helper = new util.Base64Helper();
  return helper.encodeToStringSync(encodeUtf8(raw));
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
