import test from "node:test";
import assert from "node:assert/strict";
import {
  DEFAULT_ITERATIONS,
  applySyncSecrets,
  compareVersion,
  createBackup,
  createVaultEnvelope,
  decryptVaultEnvelope,
  defaultSnapshot,
  defaultSyncSettings,
  deleteEntry,
  decodeSyncPayload,
  encodeSyncPayload,
  filterEntries,
  generateTotp,
  makeRemoteSyncClient,
  makeEntry,
  mergeEntries,
  redactedSyncSettings,
  rebuildCollections,
  synchronizeSnapshot,
  syncSecrets,
  verifyTotp
} from "../src/vault-core.mjs";

test("encrypted vault envelope round trips without plaintext fields", async () => {
  const snapshot = {
    ...defaultSnapshot(new Date("2026-01-01T00:00:00Z")),
    entries: [
      makeEntry(
        {
          label: "Production Email",
          type: "credential",
          username: "admin@example.com",
          secret: "secret-password",
          category: "Default",
          tags: "work",
          notes: "private note"
        },
        new Date("2026-01-01T00:00:00Z"),
        "entry-1"
      )
    ]
  };

  const envelope = await createVaultEnvelope("test-password", snapshot, {
    iterations: 10_000,
    salt: new Uint8Array(16),
    metadataSalt: new Uint8Array(16).fill(1),
    nonce: new Uint8Array(12),
    now: new Date("2026-01-01T00:00:00Z")
  });
  const raw = JSON.stringify(envelope);

  assert.equal(envelope.masterKeyRecord.iterations, 10_000);
  assert.equal(DEFAULT_ITERATIONS, 600_000);
  assert.match(raw, /encryptedVault/);
  assert.doesNotMatch(raw, /Production Email/);
  assert.doesNotMatch(raw, /admin@example.com/);
  assert.doesNotMatch(raw, /secret-password/);

  const decrypted = await decryptVaultEnvelope("test-password", envelope);
  assert.equal(decrypted.entries[0].label, "Production Email");
  await assert.rejects(() => decryptVaultEnvelope("wrong-password", envelope), /authentication failed/i);
});

test("TOTP generation matches RFC 6238 SHA1 fixture window", async () => {
  const secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
  const at = new Date(59_000);

  assert.equal(await generateTotp(secret, at), "287082");
  assert.equal(await verifyTotp(secret, "287082", at), true);
  assert.equal(await verifyTotp(secret, "000000", at), false);
});

test("entries filter collections backup and delete behavior", () => {
  const first = makeEntry(
    { label: "Email", type: "credential", username: "a@example.com", secret: "pw", category: "Work", tags: "mail,shared" },
    new Date("2026-01-01T00:00:00Z"),
    "entry-1"
  );
  const second = makeEntry(
    { label: "Server", type: "server", username: "10.0.0.1", secret: "pw", category: "Ops", tags: "infra" },
    new Date("2026-01-01T00:01:00Z"),
    "entry-2"
  );
  const deleted = deleteEntry(first, new Date("2026-01-01T00:02:00Z"));

  assert.deepEqual(rebuildCollections([first, second]), {
    categories: ["Ops", "Work"],
    tags: ["infra", "mail", "shared"]
  });
  assert.deepEqual(filterEntries([first, second], "server").map((entry) => entry.id), ["entry-2"]);
  assert.deepEqual(filterEntries([deleted, second]).map((entry) => entry.id), ["entry-2"]);
  assert.equal(createBackup({ schemaVersion: 1 }, [], new Date("2026-01-02T03:04:05Z"))[0].name, "vault-20260102-030405.json");
});

test("sync settings redaction and secret restore", () => {
  const settings = {
    ...defaultSyncSettings("device-1"),
    providerType: "webdav",
    webdavUsername: "alice",
    webdavPassword: "webdav-password",
    presignedDownloadUrl: "https://download.example.com/vault",
    presignedUploadUrl: "https://upload.example.com/vault"
  };
  const redacted = redactedSyncSettings(settings);
  const raw = JSON.stringify(redacted);

  assert.equal(redacted.webdavPassword, "");
  assert.doesNotMatch(raw, /webdav-password/);
  assert.doesNotMatch(raw, /download.example.com/);
  assert.deepEqual(applySyncSecrets(redacted, syncSecrets(settings)), settings);
});

test("version-vector merge handles dominance and concurrent conflicts", () => {
  const local = {
    ...makeEntry({ label: "Local", type: "credential", username: "local", secret: "pw" }, new Date("2026-01-01T00:00:00Z"), "shared"),
    version: { web: 2, remote: 1 },
    updatedBy: "web"
  };
  const remote = {
    ...makeEntry({ label: "Remote", type: "credential", username: "remote", secret: "pw" }, new Date("2026-01-01T00:01:00Z"), "shared"),
    version: { web: 1, remote: 2 },
    updatedBy: "remote"
  };

  assert.equal(compareVersion({ web: 2 }, { web: 1 }), "localDominates");
  assert.equal(compareVersion(local.version, remote.version), "concurrent");

  const merged = mergeEntries([local], [remote], "localWins", new Date("2026-01-01T00:02:00Z"));
  assert.equal(merged.stats.conflicts, 1);
  assert.equal(merged.entries.length, 2);
  assert.ok(merged.entries.some((entry) => entry.label.startsWith("Remote (conflict-remote)")));
});

test("WebDAV sync client normalizes URL and applies basic auth", async () => {
  const requests = [];
  const client = makeRemoteSyncClient(
    {
      ...defaultSyncSettings("device-1"),
      providerType: "webdav",
      webdavUrl: "https://sync.example.com/dav/",
      webdavPath: "vault.json",
      webdavUsername: "alice",
      webdavPassword: "secret"
    },
    async (url, init) => {
      requests.push({ url: url.toString(), init });
      return new Response(init.method === "GET" ? '{"ok":true}' : "", { status: init.method === "GET" ? 200 : 201 });
    },
    { timeoutMs: 1000 }
  );

  const download = await client.download();
  const upload = await client.upload('{"payload":true}');

  assert.equal(download.statusCode, 200);
  assert.equal(download.payload, '{"ok":true}');
  assert.equal(upload.statusCode, 201);
  assert.equal(requests[0].url, "https://sync.example.com/dav/vault.json");
  assert.equal(requests[0].init.method, "GET");
  assert.equal(requests[0].init.headers.Authorization, "Basic YWxpY2U6c2VjcmV0");
  assert.equal(requests[1].init.method, "PUT");
  assert.equal(requests[1].init.headers["Content-Type"], "application/json");
});

test("presigned URL sync client downloads and uploads with configured URLs", async () => {
  const requests = [];
  const client = makeRemoteSyncClient(
    {
      ...defaultSyncSettings("device-1"),
      providerType: "s3Presigned",
      presignedDownloadUrl: "https://bucket.example.com/download?sig=read",
      presignedUploadUrl: "https://bucket.example.com/upload?sig=write"
    },
    async (url, init) => {
      requests.push({ url: url.toString(), init });
      return new Response(init.method === "GET" ? '{"version":1,"snapshot":{"entries":[]}}' : "", { status: 200 });
    },
    { timeoutMs: 1000 }
  );

  assert.equal((await client.download()).statusCode, 200);
  assert.equal((await client.upload('{"version":1}')).statusCode, 200);
  assert.equal(requests[0].url, "https://bucket.example.com/download?sig=read");
  assert.equal(requests[0].init.method, "GET");
  assert.equal(requests[1].url, "https://bucket.example.com/upload?sig=write");
  assert.equal(requests[1].init.method, "PUT");
  assert.equal(requests[1].init.headers["Content-Type"], "application/json");
});

test("sync engine uploads local payload when remote vault is missing", async () => {
  const snapshot = {
    ...defaultSnapshot(new Date("2026-01-01T00:00:00Z")),
    entries: [
      makeEntry(
        { label: "Email", type: "credential", username: "a@example.com", secret: "pw" },
        new Date("2026-01-01T00:00:00Z"),
        "entry-1"
      )
    ],
    updatedAt: "2026-01-01T00:00:00.000Z"
  };
  let uploadedPayload = null;
  const client = {
    async download() {
      return { payload: null, statusCode: 404 };
    },
    async upload(payload) {
      uploadedPayload = payload;
      return { payload: null, statusCode: 201 };
    }
  };

  const result = await synchronizeSnapshot(
    snapshot,
    { ...defaultSyncSettings("device-1"), lastSyncRevision: 7 },
    client,
    new Date("2026-01-01T00:01:00Z")
  );
  const uploaded = decodeSyncPayload(uploadedPayload);

  assert.equal(result.uploaded, true);
  assert.equal(result.appliedRemote, false);
  assert.equal(result.settings.lastSyncStatus, "success");
  assert.equal(result.settings.lastSyncRevision, 7);
  assert.equal(uploaded.revision, 7);
  assert.equal(uploaded.snapshot.entries[0].label, "Email");
});

test("sync engine merges remote payload and uploads a new revision", async () => {
  const localSnapshot = {
    ...defaultSnapshot(new Date("2026-01-01T00:00:00Z")),
    entries: [
      {
        ...makeEntry(
          { label: "Local", type: "credential", username: "local", secret: "pw", category: "Local" },
          new Date("2026-01-01T00:02:00Z"),
          "shared"
        ),
        version: { web: 2 }
      }
    ],
    categories: ["Local"],
    updatedAt: "2026-01-01T00:02:00.000Z"
  };
  const remoteSnapshot = {
    ...defaultSnapshot(new Date("2026-01-01T00:01:00Z")),
    entries: [
      {
        ...makeEntry(
          { label: "Remote", type: "credential", username: "remote", secret: "pw", category: "Remote" },
          new Date("2026-01-01T00:01:00Z"),
          "shared"
        ),
        version: { web: 1 }
      }
    ],
    categories: ["Remote"],
    updatedAt: "2026-01-01T00:01:00.000Z"
  };
  const remotePayload = encodeSyncPayload({
    version: 1,
    exportedAt: "2026-01-01T00:01:00.000Z",
    deviceId: "remote-device",
    revision: 8,
    snapshot: remoteSnapshot
  });
  let uploadedPayload = null;
  const client = {
    async download() {
      return { payload: remotePayload, statusCode: 200 };
    },
    async upload(payload) {
      uploadedPayload = payload;
      return { payload: null, statusCode: 200 };
    }
  };

  const result = await synchronizeSnapshot(
    localSnapshot,
    { ...defaultSyncSettings("device-1"), lastSyncRevision: 4, conflictStrategy: "localWins" },
    client,
    new Date("2026-01-01T00:03:00Z")
  );
  const uploaded = decodeSyncPayload(uploadedPayload);

  assert.equal(result.settings.lastSyncRevision, 9);
  assert.equal(result.snapshot.entries[0].label, "Local");
  assert.deepEqual(result.snapshot.categories, ["Local", "Remote"]);
  assert.equal(uploaded.revision, 9);
  assert.equal(uploaded.snapshot.entries[0].label, "Local");
});

test("sync engine keepBoth preserves clean local empty category", async () => {
  const localSnapshot = {
    ...defaultSnapshot(new Date("2026-01-01T00:00:00Z")),
    categories: ["test"],
    updatedAt: "2026-01-01T00:00:00.000Z"
  };
  const remoteSnapshot = {
    ...defaultSnapshot(new Date("2026-01-01T00:01:00Z")),
    categories: [],
    updatedAt: "2026-01-01T00:01:00.000Z"
  };
  const remotePayload = encodeSyncPayload({
    version: 1,
    exportedAt: "2026-01-01T00:01:00.000Z",
    deviceId: "remote-device",
    revision: 2,
    snapshot: remoteSnapshot
  });
  let uploadedPayload = null;
  const client = {
    async download() {
      return { payload: remotePayload, statusCode: 200 };
    },
    async upload(payload) {
      uploadedPayload = payload;
      return { payload: null, statusCode: 200 };
    }
  };

  const result = await synchronizeSnapshot(
    localSnapshot,
    {
      ...defaultSyncSettings("device-1"),
      lastSyncRevision: 1,
      conflictStrategy: "keepBoth",
      hasLocalChanges: false
    },
    client,
    new Date("2026-01-01T00:03:00Z")
  );
  const uploaded = decodeSyncPayload(uploadedPayload);

  assert.equal(result.uploaded, true);
  assert.deepEqual(result.snapshot.categories, ["test"]);
  assert.deepEqual(uploaded.snapshot.categories, ["test"]);
});

test("sync engine keepBoth does not restore locally deleted category", async () => {
  const localSnapshot = {
    ...defaultSnapshot(new Date("2026-01-01T00:02:00Z")),
    categories: [],
    updatedAt: "2026-01-01T00:02:00.000Z"
  };
  const remoteSnapshot = {
    ...defaultSnapshot(new Date("2026-01-01T00:01:00Z")),
    categories: ["test"],
    updatedAt: "2026-01-01T00:01:00.000Z"
  };
  const remotePayload = encodeSyncPayload({
    version: 1,
    exportedAt: "2026-01-01T00:01:00.000Z",
    deviceId: "remote-device",
    revision: 3,
    snapshot: remoteSnapshot
  });
  let uploadedPayload = null;
  const client = {
    async download() {
      return { payload: remotePayload, statusCode: 200 };
    },
    async upload(payload) {
      uploadedPayload = payload;
      return { payload: null, statusCode: 200 };
    }
  };

  const result = await synchronizeSnapshot(
    localSnapshot,
    {
      ...defaultSyncSettings("device-1"),
      lastSyncRevision: 2,
      conflictStrategy: "keepBoth",
      hasLocalChanges: true
    },
    client,
    new Date("2026-01-01T00:03:00Z")
  );
  const uploaded = decodeSyncPayload(uploadedPayload);

  assert.equal(result.uploaded, true);
  assert.deepEqual(result.snapshot.categories, []);
  assert.deepEqual(uploaded.snapshot.categories, []);
});

test("sync engine keepBoth does not restore old category name after local rename", async () => {
  const localSnapshot = {
    ...defaultSnapshot(new Date("2026-01-01T00:02:00Z")),
    categories: ["prod"],
    updatedAt: "2026-01-01T00:02:00.000Z"
  };
  const remoteSnapshot = {
    ...defaultSnapshot(new Date("2026-01-01T00:01:00Z")),
    categories: ["test"],
    updatedAt: "2026-01-01T00:01:00.000Z"
  };
  const remotePayload = encodeSyncPayload({
    version: 1,
    exportedAt: "2026-01-01T00:01:00.000Z",
    deviceId: "remote-device",
    revision: 3,
    snapshot: remoteSnapshot
  });
  let uploadedPayload = null;
  const client = {
    async download() {
      return { payload: remotePayload, statusCode: 200 };
    },
    async upload(payload) {
      uploadedPayload = payload;
      return { payload: null, statusCode: 200 };
    }
  };

  const result = await synchronizeSnapshot(
    localSnapshot,
    {
      ...defaultSyncSettings("device-1"),
      lastSyncRevision: 2,
      conflictStrategy: "keepBoth",
      hasLocalChanges: true
    },
    client,
    new Date("2026-01-01T00:03:00Z")
  );
  const uploaded = decodeSyncPayload(uploadedPayload);

  assert.equal(result.uploaded, true);
  assert.deepEqual(result.snapshot.categories, ["prod"]);
  assert.deepEqual(uploaded.snapshot.categories, ["prod"]);
});
