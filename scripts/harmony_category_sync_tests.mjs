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

function main() {
  assert(fs.existsSync(controllerPath), 'Harmony VaultController exists');
  if (!fs.existsSync(controllerPath)) {
    process.exit(1);
  }

  const controller = fs.readFileSync(controllerPath, 'utf8');
  const runtime = loadCategorySyncRuntime(controller);
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

main();
