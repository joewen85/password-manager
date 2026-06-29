export const DEFAULT_ITERATIONS = 600_000;
export const VAULT_STORAGE_KEY = "password-manager-web-native:vault";
export const BACKUP_STORAGE_KEY = "password-manager-web-native:backups";
export const SYNC_SETTINGS_KEY = "password-manager-web-native:sync-settings";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function defaultSnapshot(now = new Date()) {
  return {
    entries: [],
    categories: [],
    tags: [],
    security: { requireTotp: false, totpSecret: "" },
    syncStatus: "Not configured",
    lastBackupStatus: "No backup has run",
    updatedAt: now.toISOString()
  };
}

export function defaultSyncSettings(deviceId = generateDeviceId()) {
  return {
    providerType: "none",
    webdavUrl: "",
    webdavUsername: "",
    webdavPassword: "",
    webdavPath: "/vault.json",
    presignedDownloadUrl: "",
    presignedUploadUrl: "",
    autoSyncEnabled: false,
    autoSyncIntervalMinutes: 30,
    autoSyncOnUnlock: true,
    conflictStrategy: "remoteWins",
    syncMasterKey: true,
    deviceId,
    lastSyncRevision: 0,
    lastSyncAt: null,
    lastSyncStatus: null,
    lastSyncMessage: null,
    logs: []
  };
}

export function generateDeviceId(now = Date.now(), random = crypto.randomUUID()) {
  return `${now * 1000}-${random.slice(0, 8).toLowerCase()}`;
}

export function redactedSyncSettings(settings) {
  return {
    ...settings,
    webdavPassword: "",
    presignedDownloadUrl: "",
    presignedUploadUrl: ""
  };
}

export function syncSecrets(settings) {
  return {
    webdavPassword: settings.webdavPassword ?? "",
    presignedDownloadUrl: settings.presignedDownloadUrl ?? "",
    presignedUploadUrl: settings.presignedUploadUrl ?? ""
  };
}

export function applySyncSecrets(settings, secrets) {
  return {
    ...settings,
    webdavPassword: secrets.webdavPassword ?? "",
    presignedDownloadUrl: secrets.presignedDownloadUrl ?? "",
    presignedUploadUrl: secrets.presignedUploadUrl ?? ""
  };
}

export async function createVaultEnvelope(password, snapshot, options = {}) {
  const salt = options.salt ?? randomBytes(16);
  const metadataSalt = options.metadataSalt ?? randomBytes(16);
  const iterations = options.iterations ?? DEFAULT_ITERATIONS;
  const key = await deriveAesKey(password, salt, iterations);
  const verifier = await exportRawKey(key);
  const encryptedVault = await encryptBytes(encoder.encode(JSON.stringify(snapshot)), key, options.nonce);
  return {
    schemaVersion: 1,
    masterKeyRecord: {
      saltBase64: bytesToBase64(salt),
      iterations,
      verifierBase64: bytesToBase64(verifier),
      metadataSaltBase64: bytesToBase64(metadataSalt),
      metadataIterations: iterations
    },
    encryptedVault,
    updatedAt: (options.now ?? new Date()).toISOString()
  };
}

export async function decryptVaultEnvelope(password, envelope) {
  const record = envelope.masterKeyRecord;
  if (!record || !envelope.encryptedVault) {
    return defaultSnapshot();
  }
  const key = await verifyPassword(password, record);
  const decrypted = await decryptBytes(envelope.encryptedVault, key);
  return JSON.parse(decoder.decode(decrypted));
}

export async function verifyPassword(password, record) {
  const salt = base64ToBytes(record.saltBase64);
  const expected = base64ToBytes(record.verifierBase64);
  const key = await deriveAesKey(password, salt, record.iterations);
  const actual = await exportRawKey(key);
  if (!constantTimeEqual(actual, expected)) {
    throw new Error("Vault authentication failed.");
  }
  return key;
}

export async function encryptBytes(bytes, key, nonce = randomBytes(12)) {
  const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, tagLength: 128 }, key, bytes));
  const ciphertext = sealed.slice(0, sealed.length - 16);
  const mac = sealed.slice(sealed.length - 16);
  return {
    ciphertext: bytesToBase64(ciphertext),
    nonce: bytesToBase64(nonce),
    mac: bytesToBase64(mac),
    version: 1
  };
}

export async function decryptBytes(payload, key) {
  const ciphertext = base64ToBytes(payload.ciphertext);
  const mac = base64ToBytes(payload.mac);
  const sealed = concatBytes(ciphertext, mac);
  return new Uint8Array(
    await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: base64ToBytes(payload.nonce), tagLength: 128 },
      key,
      sealed
    )
  );
}

export async function generateTotp(secret, at = new Date(), stepSeconds = 30) {
  const keyBytes = decodeBase32(secret);
  const key = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA-1" }, false, ["sign"]);
  const counter = Math.floor(at.getTime() / 1000 / stepSeconds);
  const counterBytes = new ArrayBuffer(8);
  const view = new DataView(counterBytes);
  view.setUint32(4, counter, false);
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, counterBytes));
  const offset = digest[digest.length - 1] & 0x0f;
  const code =
    (((digest[offset] & 0x7f) << 24) |
      ((digest[offset + 1] & 0xff) << 16) |
      ((digest[offset + 2] & 0xff) << 8) |
      (digest[offset + 3] & 0xff)) % 1_000_000;
  return code.toString().padStart(6, "0");
}

export async function verifyTotp(secret, code, at = new Date()) {
  const normalized = String(code).trim();
  for (const skew of [-1, 0, 1]) {
    const candidate = await generateTotp(secret, new Date(at.getTime() + skew * 30_000));
    if (candidate === normalized) {
      return true;
    }
  }
  return false;
}

export function makeEntry(draft, now = new Date(), id = crypto.randomUUID()) {
  const tags = normalizeTags(draft.tags);
  const category = (draft.category ?? "").trim();
  return {
    id,
    label: draft.label.trim(),
    type: draft.type,
    payload: payloadForDraft(draft, category, tags),
    createdAt: now.toISOString(),
    updatedAt: now.toISOString(),
    isDeleted: false,
    deletedAt: null,
    version: {},
    updatedBy: "web-native"
  };
}

export function updateEntry(entry, draft, now = new Date()) {
  const tags = normalizeTags(draft.tags);
  const category = (draft.category ?? "").trim();
  return {
    ...entry,
    label: draft.label.trim(),
    type: draft.type,
    payload: payloadForDraft(draft, category, tags),
    updatedAt: now.toISOString(),
    isDeleted: false,
    deletedAt: null
  };
}

export function deleteEntry(entry, now = new Date()) {
  return {
    ...entry,
    isDeleted: true,
    deletedAt: now.toISOString(),
    updatedAt: now.toISOString()
  };
}

export function rebuildCollections(entries) {
  const active = entries.filter((entry) => !entry.isDeleted);
  return {
    categories: [...new Set(active.map((entry) => entry.payload.category).filter(Boolean))].sort(),
    tags: [...new Set(active.flatMap((entry) => entry.payload.tags ?? []))].sort()
  };
}

export function filterEntries(entries, query = "", filter = "all") {
  const normalized = query.trim().toLowerCase();
  return entries
    .filter((entry) => !entry.isDeleted)
    .filter((entry) => filter === "all" || entry.type === filter)
    .filter((entry) => !normalized || searchIndex(entry).includes(normalized))
    .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
}

export function exportSnapshot(snapshot) {
  return JSON.stringify({ ...snapshot, exportedAt: new Date().toISOString() }, null, 2);
}

export function importSnapshot(raw) {
  const parsed = JSON.parse(raw);
  return {
    ...defaultSnapshot(),
    ...parsed,
    entries: Array.isArray(parsed.entries) ? parsed.entries : [],
    categories: Array.isArray(parsed.categories) ? parsed.categories : [],
    tags: Array.isArray(parsed.tags) ? parsed.tags : []
  };
}

export function compareVersion(local, remote) {
  let localGreater = false;
  let remoteGreater = false;
  for (const key of new Set([...Object.keys(local), ...Object.keys(remote)])) {
    const localValue = local[key] ?? 0;
    const remoteValue = remote[key] ?? 0;
    if (localValue > remoteValue) localGreater = true;
    if (remoteValue > localValue) remoteGreater = true;
    if (localGreater && remoteGreater) return "concurrent";
  }
  if (!localGreater && !remoteGreater) return "equal";
  return localGreater ? "localDominates" : "remoteDominates";
}

export function mergeEntries(localEntries, remoteEntries, strategy = "keepBoth", now = new Date()) {
  const merged = [];
  let conflicts = 0;
  const remoteById = new Map(remoteEntries.map((entry) => [entry.id, entry]));
  for (const local of localEntries) {
    const remote = remoteById.get(local.id);
    if (!remote) {
      merged.push(local);
      continue;
    }
    remoteById.delete(local.id);
    const comparison = compareVersion(effectiveVersion(local), effectiveVersion(remote));
    if (comparison === "equal") {
      merged.push(pickLatest(local, remote));
    } else if (comparison === "localDominates") {
      merged.push(local);
    } else if (comparison === "remoteDominates") {
      merged.push(remote);
    } else {
      conflicts += 1;
      const primary = choosePrimary(local, remote, strategy);
      const secondary = primary === local ? remote : local;
      merged.push(primary, conflictCopy(secondary, now));
    }
  }
  merged.push(...remoteById.values());
  return {
    entries: merged.sort((left, right) => right.updatedAt.localeCompare(left.updatedAt)),
    stats: {
      total: merged.length,
      conflicts,
      deletes: merged.filter((entry) => entry.isDeleted).length
    }
  };
}

export function createBackup(envelope, backups = [], now = new Date()) {
  const next = [{ name: `vault-${backupTimestamp(now)}.json`, envelope }, ...backups];
  return next.slice(0, 5);
}

export function makeRemoteSyncClient(settings, fetchImpl = globalThis.fetch, options = {}) {
  if (typeof fetchImpl !== "function") {
    throw new Error("Fetch is not available for remote sync.");
  }
  const timeoutMs = options.timeoutMs ?? 12_000;
  if (settings.providerType === "webdav" || settings.providerType === "nasWebdav") {
    return makeWebDavSyncClient(settings, fetchImpl, timeoutMs);
  }
  if (settings.providerType === "s3Presigned") {
    return makePresignedUrlSyncClient(settings, fetchImpl, timeoutMs);
  }
  throw new Error("Sync provider is not configured.");
}

export function encodeSyncPayload(payload) {
  return JSON.stringify(payload);
}

export function decodeSyncPayload(rawPayload) {
  if (!rawPayload || !rawPayload.trim()) return null;
  const parsed = JSON.parse(rawPayload);
  if (!parsed || typeof parsed !== "object" || !parsed.snapshot || !Array.isArray(parsed.snapshot.entries)) {
    throw new Error("Remote sync payload is invalid.");
  }
  return parsed;
}

export async function synchronizeSnapshot(localSnapshot, settings, client, now = new Date()) {
  const download = await client.download();
  if (!isSuccessfulDownload(download.statusCode)) {
    throw new Error(`Sync download failed with status ${download.statusCode}.`);
  }

  const localPayload = {
    version: 1,
    exportedAt: now.toISOString(),
    deviceId: settings.deviceId,
    revision: settings.lastSyncRevision ?? 0,
    snapshot: localSnapshot
  };
  const remotePayload = decodeSyncPayload(download.payload);
  if (!remotePayload) {
    await uploadSyncPayload(client, localPayload);
    return syncResult(localSnapshot, settings, localPayload.revision, {
      total: localSnapshot.entries.length,
      conflicts: 0,
      deletes: localSnapshot.entries.filter((entry) => entry.isDeleted).length
    }, true, false, now);
  }

  const mergeResult = mergeEntries(
    localSnapshot.entries,
    remotePayload.snapshot.entries,
    settings.conflictStrategy ?? "remoteWins",
    now
  );
  const mergedSnapshot = mergeSnapshot(
    localSnapshot,
    remotePayload.snapshot,
    mergeResult.entries,
    settings.conflictStrategy ?? "remoteWins",
    settings.hasLocalChanges === true
  );

  if (snapshotEquals(mergedSnapshot, remotePayload.snapshot)) {
    return syncResult(
      mergedSnapshot,
      settings,
      remotePayload.revision ?? 0,
      mergeResult.stats,
      false,
      !snapshotEquals(mergedSnapshot, localSnapshot),
      now
    );
  }

  const mergedRevision = Math.max(localPayload.revision, remotePayload.revision ?? 0) + 1;
  await uploadSyncPayload(client, {
    version: 1,
    exportedAt: now.toISOString(),
    deviceId: settings.deviceId,
    revision: mergedRevision,
    snapshot: mergedSnapshot
  });
  return syncResult(
    mergedSnapshot,
    settings,
    mergedRevision,
    mergeResult.stats,
    true,
    !snapshotEquals(mergedSnapshot, localSnapshot),
    now
  );
}

async function deriveAesKey(password, salt, iterations) {
  const material = await crypto.subtle.importKey("raw", encoder.encode(password), "PBKDF2", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "PBKDF2", salt, iterations, hash: "SHA-256" },
    material,
    { name: "AES-GCM", length: 256 },
    true,
    ["encrypt", "decrypt"]
  );
}

async function exportRawKey(key) {
  return new Uint8Array(await crypto.subtle.exportKey("raw", key));
}

function payloadForDraft(draft, category, tags) {
  if (draft.type === "server") {
    return {
      server: {
        name: draft.username ?? "",
        ipAddress: draft.username ?? "",
        port: "",
        username: draft.username ?? "",
        password: draft.secret ?? "",
        notes: draft.notes ?? "",
        tags,
        category
      },
      category,
      tags
    };
  }
  if (draft.type === "service") {
    return {
      service: {
        name: draft.username ?? "",
        connectionAddress: draft.username ?? "",
        connectionPort: "",
        accounts: [],
        notes: draft.notes ?? "",
        tags,
        category
      },
      category,
      tags
    };
  }
  return {
    credential: {
      username: draft.username ?? "",
      password: draft.secret ?? "",
      token: "",
      appId: "",
      accessKey: "",
      secretKey: "",
      notes: draft.notes ?? "",
      tags,
      category
    },
    category,
    tags
  };
}

function normalizeTags(value) {
  if (Array.isArray(value)) return value.map((tag) => tag.trim()).filter(Boolean);
  return String(value ?? "")
    .split(",")
    .map((tag) => tag.trim())
    .filter(Boolean);
}

function searchIndex(entry) {
  return `${entry.label} ${entry.type} ${entry.payload.category ?? ""} ${(entry.payload.tags ?? []).join(" ")}`.toLowerCase();
}

function effectiveVersion(entry) {
  if (entry.version && Object.keys(entry.version).length > 0) return entry.version;
  return { [entry.updatedBy || "legacy"]: 1 };
}

function pickLatest(left, right) {
  return left.updatedAt >= right.updatedAt ? left : right;
}

function choosePrimary(local, remote, strategy) {
  if (strategy === "localWins") return local;
  if (strategy === "remoteWins") return remote;
  return pickLatest(local, remote);
}

function conflictCopy(entry, now) {
  return {
    ...entry,
    id: crypto.randomUUID(),
    label: `${entry.label} (conflict-${entry.updatedBy || "unknown"})`,
    createdAt: now.toISOString()
  };
}

function makeWebDavSyncClient(settings, fetchImpl, timeoutMs) {
  return {
    async download() {
      try {
        const response = await performRemoteFetch(
          fetchImpl,
          buildWebDavUrl(settings.webdavUrl, settings.webdavPath),
          { method: "GET", headers: webDavAuthHeaders(settings) },
          timeoutMs
        );
        return downloadResult(response);
      } catch (error) {
        return remoteErrorResult(error);
      }
    },
    async upload(payload) {
      try {
        const response = await performRemoteFetch(
          fetchImpl,
          buildWebDavUrl(settings.webdavUrl, settings.webdavPath),
          {
            method: "PUT",
            headers: { "Content-Type": "application/json", ...webDavAuthHeaders(settings) },
            body: payload
          },
          timeoutMs
        );
        return { payload: null, statusCode: response.status };
      } catch (error) {
        return remoteErrorResult(error);
      }
    }
  };
}

function makePresignedUrlSyncClient(settings, fetchImpl, timeoutMs) {
  return {
    async download() {
      try {
        const response = await performRemoteFetch(
          fetchImpl,
          validateRemoteUrl(settings.presignedDownloadUrl),
          { method: "GET" },
          timeoutMs
        );
        return downloadResult(response);
      } catch (error) {
        return remoteErrorResult(error);
      }
    },
    async upload(payload) {
      try {
        const response = await performRemoteFetch(
          fetchImpl,
          validateRemoteUrl(settings.presignedUploadUrl),
          { method: "PUT", headers: { "Content-Type": "application/json" }, body: payload },
          timeoutMs
        );
        return { payload: null, statusCode: response.status };
      } catch (error) {
        return remoteErrorResult(error);
      }
    }
  };
}

function buildWebDavUrl(baseUrl, remotePath) {
  const base = validateRemoteUrl(baseUrl);
  const basePath = base.pathname.endsWith("/") ? base.pathname.slice(0, -1) : base.pathname;
  base.pathname = `${basePath}${normalizedRemotePath(remotePath)}`;
  return base;
}

function normalizedRemotePath(remotePath) {
  let path = String(remotePath ?? "").trim();
  if (!path) path = "/vault.json";
  if (!path.startsWith("/")) path = `/${path}`;
  if (path.endsWith("/")) path += "vault.json";
  return path;
}

function validateRemoteUrl(value) {
  const trimmed = String(value ?? "").trim();
  if (!trimmed) {
    const error = new Error("Remote sync URL is empty.");
    error.code = "invalid-url";
    throw error;
  }
  try {
    return new URL(trimmed);
  } catch {
    const error = new Error("Remote sync URL is invalid.");
    error.code = "invalid-url";
    throw error;
  }
}

function webDavAuthHeaders(settings) {
  const username = settings.webdavUsername ?? "";
  const password = settings.webdavPassword ?? "";
  if (!username && !password) return {};
  return {
    Authorization: `Basic ${bytesToBase64(encoder.encode(`${username}:${password}`))}`
  };
}

async function performRemoteFetch(fetchImpl, url, init, timeoutMs) {
  const controller = typeof AbortController === "function" ? new AbortController() : null;
  const timeout = controller ? setTimeout(() => controller.abort(), timeoutMs) : null;
  try {
    return await fetchImpl(url, controller ? { ...init, signal: controller.signal } : init);
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}

async function downloadResult(response) {
  if (response.status === 404 || response.status === 204) {
    return { payload: null, statusCode: 404 };
  }
  const payload = await response.text();
  return { payload: payload || null, statusCode: response.status };
}

function remoteErrorResult(error) {
  if (error?.name === "AbortError" || error?.name === "TimeoutError") {
    return { payload: null, statusCode: 408 };
  }
  if (error?.code === "invalid-url") {
    return { payload: null, statusCode: 400 };
  }
  return { payload: null, statusCode: 503 };
}

async function uploadSyncPayload(client, payload) {
  const upload = await client.upload(encodeSyncPayload(payload));
  if (upload.statusCode < 200 || upload.statusCode >= 300) {
    throw new Error(`Sync upload failed with status ${upload.statusCode}.`);
  }
}

function mergeSnapshot(local, remote, entries, conflictStrategy = "remoteWins", localHasChanges = false) {
  const latest = (local.updatedAt ?? "") >= (remote.updatedAt ?? "") ? local : remote;
  const shouldMergeCleanLocalTaxonomy = conflictStrategy === "keepBoth" && !localHasChanges;
  const baseCategories = shouldMergeCleanLocalTaxonomy
    ? [...(local.categories ?? []), ...(remote.categories ?? [])]
    : localHasChanges
      ? (local.categories ?? [])
      : (remote.categories ?? []);
  const baseTags = shouldMergeCleanLocalTaxonomy
    ? [...(local.tags ?? []), ...(remote.tags ?? [])]
    : localHasChanges
      ? (local.tags ?? [])
      : (remote.tags ?? []);
  const activeEntries = entries.filter((entry) => !entry.isDeleted);
  return {
    ...latest,
    entries: entries.sort((left, right) => right.updatedAt.localeCompare(left.updatedAt)),
    categories: [...new Set([...baseCategories, ...activeEntries.map((entry) => entry.payload.category).filter(Boolean)])].sort(),
    tags: [...new Set([...baseTags, ...activeEntries.flatMap((entry) => entry.payload.tags ?? []).filter(Boolean)])].sort(),
    updatedAt: [local.updatedAt, remote.updatedAt].filter(Boolean).sort().at(-1) ?? new Date().toISOString()
  };
}

function syncResult(snapshot, settings, revision, stats, uploaded, appliedRemote, now) {
  const message = `Synced ${stats.total} items, ${stats.conflicts} conflicts, ${stats.deletes} deletes, revision ${revision}.`;
  const log = { timestamp: now.toISOString(), message, level: "info" };
  return {
    snapshot,
    settings: {
      ...settings,
      lastSyncRevision: revision,
      lastSyncAt: now.toISOString(),
      lastSyncStatus: "success",
      lastSyncMessage: message,
      logs: [log, ...(settings.logs ?? [])].slice(0, 50)
    },
    stats,
    uploaded,
    appliedRemote
  };
}

function isSuccessfulDownload(statusCode) {
  return (statusCode >= 200 && statusCode < 300) || statusCode === 404;
}

function snapshotEquals(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function backupTimestamp(date) {
  return date.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z").replace("T", "-").replace("Z", "");
}

export function bytesToBase64(bytes) {
  return btoa(String.fromCharCode(...bytes));
}

export function base64ToBytes(value) {
  return Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
}

function randomBytes(count) {
  const bytes = new Uint8Array(count);
  crypto.getRandomValues(bytes);
  return bytes;
}

function concatBytes(left, right) {
  const merged = new Uint8Array(left.length + right.length);
  merged.set(left, 0);
  merged.set(right, left.length);
  return merged;
}

function constantTimeEqual(left, right) {
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let index = 0; index < left.length; index += 1) {
    diff |= left[index] ^ right[index];
  }
  return diff === 0;
}

function decodeBase32(secret) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  const clean = secret.toUpperCase().replace(/=|\s|-/g, "");
  let bits = "";
  for (const char of clean) {
    const value = alphabet.indexOf(char);
    if (value < 0) throw new Error("TOTP secret is not valid Base32.");
    bits += value.toString(2).padStart(5, "0");
  }
  const bytes = [];
  for (let index = 0; index + 8 <= bits.length; index += 8) {
    bytes.push(Number.parseInt(bits.slice(index, index + 8), 2));
  }
  return new Uint8Array(bytes);
}
