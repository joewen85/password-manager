#!/usr/bin/env node
import fs from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import path from 'node:path';
import process from 'node:process';
import vm from 'node:vm';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const resolverPath = path.join(
  root,
  'apps/harmony_app/entry/src/main/ets/src/domain/FieldReferenceResolver.ets',
);
const operationsPath = path.join(
  root,
  'apps/harmony_app/entry/src/main/ets/src/domain/EntryReferenceOperations.ets',
);
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

function loadOperationsRuntime() {
  const resolver = fs.readFileSync(resolverPath, 'utf8')
    .replace(/import\s*{[\s\S]*?}\s*from\s*'\.\.\/model\/VaultTypes';\s*/, '')
    .replace(/\bexport\s+/g, '');
  const operations = fs.readFileSync(operationsPath, 'utf8')
    .replace(/import\s*{[\s\S]*?}\s*from\s*'\.\.\/model\/VaultTypes';\s*/, '')
    .replace(/import\s*{[\s\S]*?}\s*from\s*'\.\/FieldReferenceResolver';\s*/, '')
    .replace(/\bexport\s+/g, '');
  const executable = stripTypeScriptTypes(
    `${resolver}\n${operations}\n;({ remapEntryReferenceCustomFields, resolvedEntryReferenceSearchValues });`,
    { mode: 'transform' },
  );
  return vm.runInNewContext(executable, {});
}

function loadSyncRuntime(controllerSource) {
  const deepCopyEntry = controllerSource.match(
    /function deepCopyEntry\([\s\S]*?\n}(?=\n\nfunction deepCopyRuntimePayload)/,
  )?.[0];
  const isSameEntry = controllerSource.match(
    /function isSameEntry\([\s\S]*?\n}(?=\n\nfunction hasSyncSettings)/,
  )?.[0];
  if (deepCopyEntry === undefined || isSameEntry === undefined) {
    return null;
  }
  const executable = stripTypeScriptTypes(
    `${deepCopyEntry}\n${isSameEntry}\n;({ deepCopyEntry, isSameEntry });`,
    { mode: 'transform' },
  );
  return vm.runInNewContext(executable, {});
}

function makeEntry(id, label, category, customFields = [], isDeleted = false) {
  return {
    id,
    label,
    type: 'credential',
    payload: {
      category,
      password: `password-for-${id}`,
      token: `token-for-${id}`,
      notes: `notes-for-${id}`,
    },
    tags: [],
    customFields,
    createdAt: 1,
    updatedAt: 1,
    isDeleted,
  };
}

function main() {
  assert(fs.existsSync(operationsPath), 'Harmony reference operations helper exists');
  const {
    remapEntryReferenceCustomFields,
    resolvedEntryReferenceSearchValues,
  } = loadOperationsRuntime();
  const controllerSource = fs.readFileSync(controllerPath, 'utf8');

  const templates = [{
    category: ' Servers ',
    fields: [
      { id: 'Template-Owner', name: 'Owner', valueType: 'entryReference', targetCategory: 'Accounts' },
      { id: 'Template-Backup', name: 'Backup', valueType: 'entryReference', targetCategory: 'Accounts' },
      { id: 'Template-Moved', name: 'Moved', valueType: 'entryReference', targetCategory: 'Accounts' },
      { id: 'Template-Missing', name: 'Missing', valueType: 'entryReference', targetCategory: 'Accounts' },
      { id: 'Template-Text', name: 'Text', valueType: 'text', targetCategory: '' },
      { id: 'Template-Future', name: 'Future', valueType: 'futureRelationV3', targetCategory: '' },
    ],
  }];
  const source = makeEntry('Source-Entry', 'Production Server', 'servers', [
    { id: 'Field-Owner', templateFieldId: 'Template-Owner', name: 'Owner', value: 'Target-Live' },
    { id: 'Field-Backup', templateFieldId: 'Template-Backup', name: 'Backup', value: 'Target-Deleted' },
    { id: 'Field-Moved', templateFieldId: 'Template-Moved', name: 'Moved', value: 'Target-Moved' },
    { id: 'Field-Missing', templateFieldId: 'Template-Missing', name: 'Missing', value: 'Target-Missing' },
    { id: 'Field-Text', templateFieldId: 'Template-Text', name: 'Text', value: 'Target-Live' },
    { id: 'Field-Future', templateFieldId: 'Template-Future', name: 'Future', value: 'Target-Live' },
  ]);
  const liveTarget = makeEntry('Target-Live', 'Primary Account', ' Accounts ');
  const deletedTarget = makeEntry('Target-Deleted', 'Deleted Account', 'Accounts', [], true);
  const movedTarget = makeEntry('Target-Moved', 'Moved Account', 'Archive');
  const searchValues = resolvedEntryReferenceSearchValues(
    source,
    templates,
    [source, liveTarget, deletedTarget, movedTarget],
  );
  assert(
    JSON.stringify(searchValues) === JSON.stringify(['Primary Account', 'Accounts']),
    'Search projection includes only RESOLVED target label and category',
  );
  const forbiddenSearchValues = [
    'Target-Live',
    'Target-Deleted',
    'Target-Moved',
    'Target-Missing',
    'Deleted Account',
    'Moved Account',
    liveTarget.payload.password,
    liveTarget.payload.token,
    liveTarget.payload.notes,
  ];
  assert(
    forbiddenSearchValues.every((value) => !searchValues.includes(value)),
    'Search projection excludes raw IDs, unresolved states, payloads, and secrets',
  );

  const importFields = [
    { id: 'Field-Owner', templateFieldId: 'Template-Owner', name: 'Owner', value: 'Old-Target' },
    { id: 'Field-Backup', templateFieldId: 'Template-Backup', name: 'Backup', value: 'Old-Later-Target' },
    { id: 'Field-Missing', templateFieldId: 'Template-Missing', name: 'Missing', value: 'Outside-Scope' },
    { id: 'Field-Text', templateFieldId: 'Template-Text', name: 'Text', value: 'Old-Target' },
    { id: 'Field-Future', templateFieldId: 'Template-Future', name: 'Future', value: 'Old-Target' },
    { id: 'Field-Legacy', name: ' owner ', value: 'Old-Target' },
  ];
  const idMap = new Map([
    ['Old-Target', 'New-Target'],
    ['Old-Later-Target', 'New-Later-Target'],
  ]);
  const remapped = remapEntryReferenceCustomFields(importFields, 'servers', templates, idMap);
  assert(
    remapped[0].value === 'New-Target' && remapped[1].value === 'New-Later-Target',
    'Complete ID map remaps direct and forward entry references',
  );
  assert(
    remapped[0].templateFieldId === 'Template-Owner' && remapped[0].id === 'Field-Owner',
    'Reference remapping preserves template and custom-field IDs',
  );
  assert(
    remapped[2].value === 'Outside-Scope',
    'References to targets outside the copied scope retain their original IDs',
  );
  assert(
    remapped[3].value === 'Old-Target' && remapped[4].value === 'Old-Target',
    'Text and unknown field types are never remapped as entry references',
  );
  assert(
    remapped[5].value === 'New-Target' && remapped[5].templateFieldId === undefined,
    'Legacy name-matched references remap without inventing a template field ID',
  );
  assert(
    importFields[0].value === 'Old-Target' && importFields[1].value === 'Old-Later-Target',
    'Reference remapping does not mutate imported source fields',
  );

  const fieldReferenceTemplates = [
    {
      category: 'Servers',
      fields: [
        ...templates[0].fields,
        {
          id: 'Template-Owner-Email',
          name: 'Owner Email',
          valueType: 'fieldReference',
          targetCategory: 'Accounts',
          targetFieldId: 'Template-Email',
        },
      ],
    },
    {
      category: 'Accounts',
      fields: [{
        id: 'Template-Email',
        name: 'Directory Address',
        valueType: 'text',
        targetCategory: '',
        targetFieldId: '',
      }],
    },
  ];
  const fieldReferenceSource = makeEntry('Field-Source', 'Field Source', 'Servers', [{
    id: 'Field-Owner-Email',
    templateFieldId: 'Template-Owner-Email',
    name: 'Owner Email',
    value: 'Field-Target',
  }]);
  const fieldReferenceTarget = makeEntry('Field-Target', 'Target Account', 'Accounts', [{
    id: 'Field-Email',
    templateFieldId: 'Template-Email',
    name: 'Old Email Name',
    value: 'private@example.com',
  }]);
  const fieldReferenceSearchValues = resolvedEntryReferenceSearchValues(
    fieldReferenceSource,
    fieldReferenceTemplates,
    [fieldReferenceSource, fieldReferenceTarget],
  );
  assert(
    JSON.stringify(fieldReferenceSearchValues) ===
      JSON.stringify(['Target Account', 'Accounts', 'Directory Address']),
    'Field-reference search indexes only target label, category, and field name',
  );
  assert(
    !fieldReferenceSearchValues.includes('private@example.com') &&
      !fieldReferenceSearchValues.includes('Field-Target') &&
      !fieldReferenceSearchValues.includes(fieldReferenceTarget.payload.password),
    'Field-reference search excludes target values, raw IDs, and secrets',
  );
  const remappedFieldReference = remapEntryReferenceCustomFields(
    fieldReferenceSource.customFields,
    'Servers',
    fieldReferenceTemplates,
    new Map([['Field-Target', 'Copied-Field-Target']]),
  );
  assert(
    remappedFieldReference[0].value === 'Copied-Field-Target' &&
      remappedFieldReference[0].templateFieldId === 'Template-Owner-Email',
    'Copy import remaps the selected target entry but preserves target-field metadata',
  );

  const searchMethod = controllerSource.slice(
    controllerSource.indexOf('  searchEntries('),
    controllerSource.indexOf('  async setupMasterPassword('),
  );
  assert(
    searchMethod.includes('resolvedEntryReferenceSearchValues(') &&
      !searchMethod.includes('customFields') &&
      !searchMethod.includes('field.value'),
    'VaultController search delegates reference indexing to the safe projection helper',
  );
  const applyImportPlan = controllerSource.slice(
    controllerSource.indexOf('  private async applyImportPlan('),
    controllerSource.indexOf('  private parseImportItems('),
  );
  assert(
    applyImportPlan.indexOf('const destinationIds = items.map') <
      applyImportPlan.indexOf('for (let index = 0; index < items.length; index++)'),
    'Scoped import builds every destination ID before executing copy operations',
  );
  assert(
    controllerSource.includes('remapEntryReferenceCustomFields(') &&
      controllerSource.includes('this.createImportedItem(current.item, idMap, destinationId)'),
    'Scoped import applies the complete ID map to copied custom fields',
  );
  assert(
    controllerSource.includes('targetFieldReferenceIdsForCategory(') &&
      controllerSource.includes('.forEach((fieldId: string) => storedValueFieldIds.add(fieldId));'),
    'Category saves protect target text fields referenced by fieldReference definitions',
  );

  const syncRuntime = loadSyncRuntime(controllerSource);
  assert(syncRuntime !== null, 'Harmony sync comparison helpers remain executable');
  if (syncRuntime !== null) {
    const left = makeEntry('Sync-Entry', 'Sync Entry', 'Servers', [{
      id: 'Sync-Field',
      templateFieldId: 'Template-Owner',
      name: 'Owner',
      value: 'Target-A',
    }]);
    const right = JSON.parse(JSON.stringify(left));
    assert(syncRuntime.isSameEntry(left, right), 'Sync equality accepts identical entry references');
    right.customFields[0].value = 'Target-B';
    assert(
      !syncRuntime.isSameEntry(left, right),
      'Sync equality detects entry-reference custom-field changes',
    );
    const conflictCopy = syncRuntime.deepCopyEntry(left);
    conflictCopy.id = 'Conflict-Copy';
    conflictCopy.label = 'Sync Entry (Conflict)';
    assert(
      conflictCopy.customFields[0].value === 'Target-A' &&
        conflictCopy.customFields !== left.customFields &&
        controllerSource.includes('const duplicate = deepCopyEntry(loser);'),
      'KEEP_BOTH conflict copies preserve entry-reference fields through deep copy',
    );
    const fieldReferenceConflict = makeEntry('Field-Sync', 'Field Sync', 'Servers', [{
      id: 'Field-Sync-Value',
      templateFieldId: 'Template-Owner-Email',
      name: 'Owner Email',
      value: 'Field-Target',
    }]);
    const fieldReferenceCopy = syncRuntime.deepCopyEntry(fieldReferenceConflict);
    assert(
      fieldReferenceCopy.customFields[0].value === 'Field-Target' &&
        fieldReferenceCopy.customFields[0].templateFieldId === 'Template-Owner-Email' &&
        fieldReferenceCopy.customFields !== fieldReferenceConflict.customFields,
      'Sync conflict copies preserve fieldReference target entry selections',
    );
  }

  if (failures > 0) {
    console.error(`[FAIL] Harmony reference operations tests failed: ${failures}`);
    process.exit(1);
  }
  console.log('[OK] Harmony reference operations tests passed');
}

main();
