#!/usr/bin/env node
import fs from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import path from 'node:path';
import process from 'node:process';
import vm from 'node:vm';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const controllerPath = path.join(
  root,
  'apps/harmony_app/entry/src/main/ets/src/service/VaultController.ets',
);

let failures = 0;

function assert(condition, message) {
  if (condition) {
    console.log(`[OK] ${message}`);
    return;
  }
  failures += 1;
  console.error(`[FAIL] ${message}`);
}

function extractFunction(source, name) {
  const start = source.indexOf(`function ${name}(`);
  if (start < 0) {
    throw new Error(`Cannot find Harmony controller function: ${name}`);
  }
  const bodyStart = source.indexOf('{', start);
  let depth = 0;
  let quote = '';
  let escaped = false;
  for (let index = bodyStart; index < source.length; index += 1) {
    const char = source[index];
    if (quote.length > 0) {
      if (escaped) {
        escaped = false;
      } else if (char === '\\') {
        escaped = true;
      } else if (char === quote) {
        quote = '';
      }
      continue;
    }
    if (char === "'" || char === '"' || char === '`') {
      quote = char;
      continue;
    }
    if (char === '{') {
      depth += 1;
    } else if (char === '}') {
      depth -= 1;
      if (depth === 0) {
        return source.slice(start, index + 1);
      }
    }
  }
  throw new Error(`Cannot find end of Harmony controller function: ${name}`);
}

function extractPrivateAsyncMethod(source, name) {
  const signature = `private async ${name}(`;
  const start = source.indexOf(signature);
  if (start < 0) {
    throw new Error(`Cannot find Harmony controller method: ${name}`);
  }
  const bodyStart = source.indexOf('{', start);
  let depth = 0;
  let quote = '';
  let escaped = false;
  for (let index = bodyStart; index < source.length; index += 1) {
    const char = source[index];
    if (quote.length > 0) {
      if (escaped) {
        escaped = false;
      } else if (char === '\\') {
        escaped = true;
      } else if (char === quote) {
        quote = '';
      }
      continue;
    }
    if (char === "'" || char === '"' || char === '`') {
      quote = char;
      continue;
    }
    if (char === '{') {
      depth += 1;
    } else if (char === '}') {
      depth -= 1;
      if (depth === 0) {
        return source
          .slice(start, index + 1)
          .replace(signature, `async function ${name}(`);
      }
    }
  }
  throw new Error(`Cannot find end of Harmony controller method: ${name}`);
}

function loadCategorySyncRuntime(controller) {
  const functionNames = [
    'readString',
    'pickFirstNonEmpty',
    'resolveEntryCategory',
    'cloneCategoryVersion',
    'mergedCategoryVersion',
    'compareCategoryVersion',
    'normalizeCategorySyncState',
    'resolveCategorySyncState',
    'normalizeCategoryStates',
    'categoryTombstone',
    'mergeCategoryStatesForSync',
  ];
  const conflictStrategy = `
    const ConflictStrategy = Object.freeze({
      LOCAL_WINS: 'localWins',
      REMOTE_WINS: 'remoteWins',
      KEEP_BOTH: 'keepBoth',
    });
  `;
  const source = `${conflictStrategy}
    ${functionNames.map((name) => extractFunction(controller, name)).join('\n')}
    ;({ ConflictStrategy, ${functionNames.join(', ')} });`;
  return vm.runInNewContext(stripTypeScriptTypes(source, { mode: 'transform' }), {});
}

function loadBusinessEqualityRuntime(controller) {
  const source = `${extractFunction(controller, 'hasSameSyncBusinessContent')}
    ;hasSameSyncBusinessContent;`;
  return vm.runInNewContext(stripTypeScriptTypes(source, { mode: 'transform' }), {});
}

function loadSyncPathRuntime(controller) {
  const functionNames = [
    'deepCopyRuntimePayload',
    'parseSyncEnvelope',
    'isSuccessfulRemoteStatus',
    'cloneSyncSettings',
    'hasSameSyncBusinessContent',
  ];
  const source = `
    ${functionNames.map((name) => extractFunction(controller, name)).join('\n')}
    function sanitizeRuntimePayload(payload) {
      return JSON.parse(JSON.stringify(payload));
    }
    ${extractPrivateAsyncMethod(controller, 'performSyncOnce')}
    ;performSyncOnce;
  `;
  return vm.runInNewContext(
    stripTypeScriptTypes(source, { mode: 'transform' }),
    { console },
  );
}

function payload({
  categories = [],
  categoryTemplates = [],
  categoryStates = [],
  entries = [],
  updatedAt = 1,
  hasLocalChanges = false,
  deviceId = 'harmony-device',
} = {}) {
  return {
    categories,
    categoryTemplates,
    categoryStates,
    entries,
    tags: [],
    security: {},
    updatedAt,
    syncSettings: {
      hasLocalChanges,
      deviceId,
    },
  };
}

function staleRemote(updatedAt) {
  return payload({
    categories: ['test'],
    categoryTemplates: [{ category: 'test', fields: [] }],
    entries: [{
      id: 'remote-entry',
      label: 'Remote entry',
      payload: { category: 'test' },
      isDeleted: false,
    }],
    updatedAt,
    deviceId: 'remote-device',
  });
}

function assertDeletedState(states, message) {
  assert(
    states.length === 1 &&
      states[0].name === 'test' &&
      states[0].isDeleted === true,
    message,
  );
}

function syncSettings(strategy, revision) {
  return {
    providerType: 'webdav',
    webdavUrl: 'https://sync.example.test',
    webdavUsername: '',
    webdavPassword: '',
    webdavPath: '/vault.json',
    presignedDownloadUrl: '',
    presignedUploadUrl: '',
    objectStorageAccessKeyId: '',
    objectStorageSecretAccessKey: '',
    objectStorageBucket: '',
    objectStorageEndpoint: '',
    objectStorageAppId: '',
    objectStorageCustomUrl: '',
    objectStorageObjectKey: 'vault.sync.json',
    autoSyncEnabled: true,
    autoSyncIntervalMinutes: 30,
    autoSyncIntervalValue: 30,
    autoSyncIntervalUnit: 'minutes',
    autoSyncOnUnlock: true,
    conflictStrategy: strategy,
    syncMasterKey: false,
    deviceId: 'harmony-device',
    lastSyncRevision: revision,
    lastSyncAt: 100,
    lastSyncStatus: 'local-status',
    lastSyncMessage: 'local-message',
    lastRemoteFingerprint: 'remote-r11',
    hasLocalChanges: false,
    logs: [],
  };
}

async function assertRuntimeMetadataSyncPath({
  performSyncOnce,
  categoryRuntime,
  initialTombstone,
  strategy,
}) {
  const localRevision = 11;
  const remoteRevision = 12;
  const localSettings = syncSettings(strategy, localRevision);
  const localPayload = payload({
    categoryStates: [initialTombstone],
    updatedAt: 300,
  });
  localPayload.syncSettings = localSettings;

  const remotePayload = payload({
    categoryStates: [initialTombstone],
    updatedAt: 200,
    deviceId: 'remote-device',
  });
  remotePayload.syncSettings = {
    ...syncSettings(strategy, remoteRevision),
    deviceId: 'remote-device',
    lastSyncAt: 200,
    lastSyncStatus: 'remote-status',
    lastSyncMessage: 'remote-message',
    lastRemoteFingerprint: 'remote-r12',
  };

  const remoteEnvelope = JSON.stringify({
    version: 1,
    exportedAt: '2026-07-29T00:00:00Z',
    deviceId: 'remote-device',
    revision: remoteRevision,
    masterKeyRecord: null,
    encryptedVault: { ciphertext: 'fixture' },
  });
  const uploads = [];
  const builtPayloads = [];
  const statuses = [];
  const persists = [];
  const client = {
    async metadata() {
      return { statusCode: 200, fingerprint: 'remote-r12' };
    },
    async download() {
      return { statusCode: 200, payload: remoteEnvelope };
    },
    async upload(value) {
      uploads.push(value);
      return { statusCode: 200, payload: '' };
    },
  };
  const harness = {
    snapshot: localPayload,
    localChangeRevision: 0,
    syncRequestedAgain: false,
    masterKeyRecord: null,
    sessionKeyToken: 'session-key',
    crypto: {
      async decryptString() {
        return JSON.stringify(remotePayload);
      },
    },
    mergePayloads(local, remote, receivedStrategy) {
      assert(
        receivedStrategy === strategy,
        `${strategy} full sync path forwards the selected conflict strategy`,
      );
      const categoryStates = categoryRuntime.mergeCategoryStatesForSync(
        local,
        remote,
        receivedStrategy,
      );
      return {
        entries: JSON.parse(JSON.stringify(remote.entries)),
        categories: JSON.parse(JSON.stringify(remote.categories)),
        categoryTemplates: JSON.parse(JSON.stringify(remote.categoryTemplates)),
        categoryStates,
        tags: JSON.parse(JSON.stringify(remote.tags)),
        security: JSON.parse(JSON.stringify(remote.security)),
        updatedAt: Math.max(local.updatedAt, remote.updatedAt),
        syncSettings: JSON.parse(JSON.stringify(local.syncSettings)),
      };
    },
    localRevisionChangedSince(revision) {
      return revision !== this.localChangeRevision;
    },
    recordSyncStatus(status, message, revision, fingerprint) {
      statuses.push({ status, message, revision, fingerprint });
      this.snapshot.syncSettings = {
        ...this.snapshot.syncSettings,
        hasLocalChanges: false,
        lastSyncRevision: revision,
        lastSyncStatus: status,
        lastSyncMessage: message,
        lastRemoteFingerprint: fingerprint ?? '',
      };
    },
    async persist(markLocalChange) {
      persists.push(markLocalChange);
    },
    async buildSyncPayload(_snapshot, revision) {
      builtPayloads.push(revision);
      return `upload-revision-${revision}`;
    },
    async safeRemoteFingerprint() {
      return 'uploaded-r13';
    },
  };

  await performSyncOnce.call(harness, client, localSettings);

  assert(
    builtPayloads.length === 0 && uploads.length === 0,
    `${strategy} full sync path does not upload a runtime-metadata-only revision`,
  );
  assert(
    statuses.length === 1 &&
      statuses[0].status === 'success' &&
      statuses[0].revision === remoteRevision,
    `${strategy} full sync path accepts the remote revision`,
  );
  assertDeletedState(
    harness.snapshot.categoryStates,
    `${strategy} full sync path preserves the category tombstone`,
  );
  assert(
    harness.snapshot.syncSettings.lastSyncRevision === remoteRevision &&
      harness.snapshot.syncSettings.hasLocalChanges === false,
    `${strategy} full sync path persists clean settings at the remote revision`,
  );
  assert(
    persists.length === 1 && persists[0] === false,
    `${strategy} full sync path persists without marking a local change`,
  );
}

async function main() {
  assert(fs.existsSync(controllerPath), 'Harmony VaultController exists');
  if (!fs.existsSync(controllerPath)) {
    process.exit(1);
  }

  const controller = fs.readFileSync(controllerPath, 'utf8');
  const runtime = loadCategorySyncRuntime(controller);
  let performSyncOnce = null;
  try {
    performSyncOnce = loadSyncPathRuntime(controller);
  } catch (error) {
    assert(false, `Harmony exposes an executable full sync path: ${error}`);
  }
  let hasSameSyncBusinessContent = null;
  try {
    hasSameSyncBusinessContent = loadBusinessEqualityRuntime(controller);
  } catch (error) {
    assert(false, `Harmony exposes a business-only sync equality check: ${error}`);
  }
  const initialTombstone = {
    name: 'test',
    isDeleted: true,
    updatedAt: 100,
    version: { legacy: 1, 'harmony-device': 1 },
    updatedBy: 'harmony-device',
  };

  for (const strategy of [
    runtime.ConflictStrategy.REMOTE_WINS,
    runtime.ConflictStrategy.KEEP_BOTH,
  ]) {
    const firstRound = runtime.mergeCategoryStatesForSync(
      payload({
        categoryStates: [initialTombstone],
        updatedAt: 100,
        hasLocalChanges: true,
      }),
      staleRemote(200),
      strategy,
    );
    assertDeletedState(
      firstRound,
      `${strategy} keeps the category tombstone during the deletion sync`,
    );

    const secondRound = runtime.mergeCategoryStatesForSync(
      payload({
        categoryStates: firstRound,
        updatedAt: 300,
        hasLocalChanges: false,
      }),
      staleRemote(400),
      strategy,
    );
    assertDeletedState(
      secondRound,
      `${strategy} keeps the tombstone after dirty state is cleared and a newer stale snapshot arrives`,
    );

    const normalized = runtime.normalizeCategoryStates(
      secondRound,
      ['test'],
      [{ category: 'test', fields: [] }],
      staleRemote(500).entries,
      500,
    );
    assertDeletedState(
      normalized,
      `${strategy} does not recreate a deleted category from stale categories, templates, or entries`,
    );
  }

  const inferredDeletion = runtime.mergeCategoryStatesForSync(
    payload({ updatedAt: 100, hasLocalChanges: true }),
    staleRemote(200),
    runtime.ConflictStrategy.KEEP_BOTH,
  );
  assertDeletedState(
    inferredDeletion,
    'Legacy local deletion is migrated to a persistent tombstone on first sync',
  );
  assert(
    inferredDeletion[0].version.legacy === 1 &&
      inferredDeletion[0].version['harmony-device'] === 1,
    'Legacy deletion migration advances the local device version vector',
  );

  const recreated = runtime.resolveCategorySyncState(
    {
      ...initialTombstone,
      isDeleted: false,
      updatedAt: 600,
      version: { legacy: 1, 'harmony-device': 2 },
    },
    initialTombstone,
    runtime.ConflictStrategy.REMOTE_WINS,
  );
  assert(!recreated.isDeleted, 'Explicit recreation with a dominating version clears the tombstone');

  if (hasSameSyncBusinessContent !== null) {
    const localRuntimePayload = payload({
      categoryStates: [initialTombstone],
      updatedAt: 300,
    });
    localRuntimePayload.syncSettings.lastSyncStatus = 'local-status';
    const remoteRuntimePayload = payload({
      categoryStates: [initialTombstone],
      updatedAt: 200,
    });
    remoteRuntimePayload.syncSettings.lastSyncStatus = 'remote-status';
    assert(
      hasSameSyncBusinessContent(localRuntimePayload, remoteRuntimePayload),
      'Harmony ignores runtime metadata when deciding whether to upload',
    );
    assert(
      !hasSameSyncBusinessContent(
        localRuntimePayload,
        payload({ categoryStates: [], updatedAt: 200 }),
      ),
      'Harmony still uploads when a category tombstone changes',
    );
  }

  if (performSyncOnce !== null) {
    for (const strategy of [
      runtime.ConflictStrategy.REMOTE_WINS,
      runtime.ConflictStrategy.KEEP_BOTH,
    ]) {
      await assertRuntimeMetadataSyncPath({
        performSyncOnce,
        categoryRuntime: runtime,
        initialTombstone,
        strategy,
      });
    }
  }

  assert(
    controller.includes('const categoryStates = mergeCategoryStatesForSync(local, remote, strategy);'),
    'Harmony payload merge consumes persistent category states',
  );
  assert(
    controller.includes('categoryStates.filter((state: CategorySyncState) => !state.isDeleted)'),
    'Harmony payload merge derives visible categories only from active states',
  );
  assert(
    controller.includes('categoryStates: snapshot.categoryStates,'),
    'Harmony export preserves category tombstones',
  );
  assert(
    controller.includes('this.snapshot = uploadPayload;') &&
      controller.includes('await this.persist(false);'),
    'Harmony persists the clean post-sync snapshot instead of relying on transient dirty state',
  );

  if (failures > 0) {
    console.error(`[FAIL] Harmony category sync tests failed: ${failures}`);
    process.exit(1);
  }
  console.log('[OK] Harmony category sync tests passed');
}

await main();
