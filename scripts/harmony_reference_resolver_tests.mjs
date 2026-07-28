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
let failures = 0;

function assert(condition, message) {
  if (condition) {
    console.log(`[OK] ${message}`);
    return;
  }
  failures += 1;
  console.error(`[FAIL] ${message}`);
}

function loadResolverRuntime() {
  const source = fs.readFileSync(resolverPath, 'utf8')
    .replace(/import\s*{[\s\S]*?}\s*from\s*'\.\.\/model\/VaultTypes';\s*/, '')
    .replace(/\bexport\s+/g, '');
  const executable = stripTypeScriptTypes(
    `${source}\n;({ EntryReferenceStatus, propagateEntryReferenceCategoryRename, resolveEntryReference });`,
    { mode: 'transform' },
  );
  return vm.runInNewContext(executable, {});
}

function makeEntry(id, label, category, isDeleted = false) {
  return {
    id,
    label,
    type: 'credential',
    payload: {
      category,
      password: 'must-not-leak',
      token: 'must-not-leak',
    },
    tags: [],
    customFields: [],
    createdAt: 1,
    updatedAt: 1,
    isDeleted,
  };
}

function main() {
  assert(fs.existsSync(resolverPath), 'Harmony field reference resolver exists');
  const {
    EntryReferenceStatus,
    propagateEntryReferenceCategoryRename,
    resolveEntryReference,
  } = loadResolverRuntime();
  assert(
    JSON.stringify(EntryReferenceStatus) === JSON.stringify({
      EMPTY: 'EMPTY',
      RESOLVED: 'RESOLVED',
      MISSING: 'MISSING',
      DELETED: 'DELETED',
      CATEGORY_MISMATCH: 'CATEGORY_MISMATCH',
    }),
    'Harmony field reference statuses match the cross-platform contract',
  );

  const referenceTemplate = {
    id: 'Template-Owner',
    name: 'Owner',
    valueType: 'entryReference',
    targetCategory: ' Accounts ',
  };
  const textTemplate = {
    id: 'Template-Text',
    name: 'Text',
    valueType: 'text',
    targetCategory: '',
  };
  const unknownTemplate = {
    id: 'Template-Future',
    name: 'Future',
    valueType: 'futureRelationV3',
    targetCategory: '',
  };
  const referenceCategoryTemplate = {
    category: 'Servers',
    fields: [referenceTemplate, textTemplate, unknownTemplate],
  };
  const liveTarget = makeEntry('Target-Entry', 'Primary Account', ' accounts ');
  const entries = [liveTarget];

  const renamedTemplates = propagateEntryReferenceCategoryRename(
    [
      referenceCategoryTemplate,
      {
        category: 'Services',
        fields: [{
          id: 'Template-Service-Owner',
          name: 'Service Owner',
          valueType: 'entryReference',
          targetCategory: 'ACCOUNTS',
        }],
      },
    ],
    ' accounts ',
    ' Identity ',
  );
  assert(
    renamedTemplates[0].fields[0].targetCategory === 'Identity' &&
      renamedTemplates[1].fields[0].targetCategory === 'Identity',
    'Category rename propagates across reference templates with trimmed case-insensitive matching',
  );
  assert(
    JSON.stringify(renamedTemplates[0].fields[0]) === JSON.stringify({
      id: referenceTemplate.id,
      name: referenceTemplate.name,
      valueType: referenceTemplate.valueType,
      targetCategory: 'Identity',
    }),
    'Category rename preserves reference field IDs and metadata',
  );
  assert(
    renamedTemplates[0].fields[1] === textTemplate &&
      renamedTemplates[0].fields[2] === unknownTemplate,
    'Category rename leaves text and unknown template types unchanged',
  );

  assert(
    resolveEntryReference(
      { id: 'Field-Empty', templateFieldId: referenceTemplate.id, name: 'Owner', value: '   ' },
      referenceCategoryTemplate,
      [makeEntry('   ', 'Blank ID', 'Other', true)],
    ).status === EntryReferenceStatus.EMPTY,
    'Whitespace-only reference values resolve as EMPTY',
  );

  const resolved = resolveEntryReference(
    { id: 'Field-Owner', templateFieldId: referenceTemplate.id, name: 'Renamed', value: liveTarget.id },
    referenceCategoryTemplate,
    entries,
  );
  assert(resolved.status === EntryReferenceStatus.RESOLVED, 'Stable template IDs resolve before field names');
  assert(
    JSON.stringify(resolved.target) === JSON.stringify({
      id: liveTarget.id,
      label: liveTarget.label,
      category: 'accounts',
    }),
    'Resolved targets expose only id, label, and category',
  );
  assert(
    Object.keys(resolved.target).sort().join(',') === 'category,id,label' &&
      resolved.target.payload === undefined && resolved.target.password === undefined,
    'Resolved targets do not expose payloads or secrets',
  );

  const legacyResolved = resolveEntryReference(
    { id: 'Legacy-Field', name: ' owner ', value: liveTarget.id },
    referenceCategoryTemplate,
    entries,
  );
  assert(
    legacyResolved.status === EntryReferenceStatus.RESOLVED,
    'Legacy fields without template IDs use normalized field-name matching',
  );
  assert(
    resolveEntryReference(
      { id: 'Wrong-Binding', templateFieldId: 'Missing-Template', name: 'Owner', value: liveTarget.id },
      referenceCategoryTemplate,
      entries,
    ) === null,
    'Non-empty unmatched template IDs do not fall back to field names',
  );
  assert(
    resolveEntryReference(
      { id: 'Blank-Binding', templateFieldId: '   ', name: 'Owner', value: liveTarget.id },
      referenceCategoryTemplate,
      entries,
    ) === null,
    'Whitespace template IDs remain opaque and do not fall back to field names',
  );

  assert(
    resolveEntryReference(
      { id: 'Text-Field', templateFieldId: textTemplate.id, name: 'Text', value: liveTarget.id },
      referenceCategoryTemplate,
      entries,
    ) === null,
    'Text templates are not interpreted as entry references',
  );
  assert(
    resolveEntryReference(
      { id: 'Future-Field', templateFieldId: unknownTemplate.id, name: 'Future', value: liveTarget.id },
      referenceCategoryTemplate,
      entries,
    ) === null,
    'Unknown template types are not interpreted as entry references',
  );

  const wrongCase = resolveEntryReference(
    { id: 'Wrong-Case', templateFieldId: referenceTemplate.id, name: 'Owner', value: 'target-entry' },
    referenceCategoryTemplate,
    entries,
  );
  assert(wrongCase.status === EntryReferenceStatus.MISSING, 'Target entry IDs match case-sensitively');
  assert(wrongCase.target === undefined, 'MISSING results do not expose a target');

  const deleted = resolveEntryReference(
    { id: 'Deleted-Field', templateFieldId: referenceTemplate.id, name: 'Owner', value: 'Deleted-Target' },
    referenceCategoryTemplate,
    [makeEntry('Deleted-Target', 'Deleted Account', 'Other', true)],
  );
  assert(deleted.status === EntryReferenceStatus.DELETED, 'Found soft-deleted targets resolve as DELETED');
  assert(
    JSON.stringify(deleted.target) === JSON.stringify({
      id: 'Deleted-Target',
      label: 'Deleted Account',
      category: 'Other',
    }),
    'DELETED results expose the same safe target projection',
  );
  assert(
    Object.keys(deleted.target).sort().join(',') === 'category,id,label' &&
      deleted.target.payload === undefined && deleted.target.password === undefined,
    'DELETED targets do not expose payloads or secrets',
  );

  const mismatch = resolveEntryReference(
    { id: 'Mismatch-Field', templateFieldId: referenceTemplate.id, name: 'Owner', value: 'Other-Target' },
    referenceCategoryTemplate,
    [makeEntry('Other-Target', 'Other Account', 'Other')],
  );
  assert(
    mismatch.status === EntryReferenceStatus.CATEGORY_MISMATCH,
    'Live targets outside the configured category resolve as CATEGORY_MISMATCH',
  );
  assert(
    JSON.stringify(mismatch.target) === JSON.stringify({
      id: 'Other-Target',
      label: 'Other Account',
      category: 'Other',
    }),
    'CATEGORY_MISMATCH results expose the same safe target projection',
  );
  assert(
    Object.keys(mismatch.target).sort().join(',') === 'category,id,label' &&
      mismatch.target.payload === undefined && mismatch.target.password === undefined,
    'CATEGORY_MISMATCH targets do not expose payloads or secrets',
  );

  const unrestricted = resolveEntryReference(
    { id: 'Unrestricted-Field', templateFieldId: 'Template-Any', name: 'Any', value: 'Other-Target' },
    {
      category: 'Servers',
      fields: [{ id: 'Template-Any', name: 'Any', valueType: 'entryReference', targetCategory: '   ' }],
    },
    [makeEntry('Other-Target', 'Other Account', 'Other')],
  );
  assert(
    unrestricted.status === EntryReferenceStatus.RESOLVED,
    'Empty trimmed target categories do not restrict reference resolution',
  );

  const lifecycleField = {
    id: 'Lifecycle-Field',
    templateFieldId: referenceTemplate.id,
    name: 'Owner',
    value: liveTarget.id,
  };
  const renamedReferenceTemplate = renamedTemplates[0];
  const movedTarget = makeEntry(liveTarget.id, liveTarget.label, 'Archive');
  assert(
    lifecycleField.value === liveTarget.id &&
      resolveEntryReference(
        lifecycleField,
        renamedReferenceTemplate,
        [makeEntry(liveTarget.id, liveTarget.label, 'Identity', true)],
      ).status === EntryReferenceStatus.DELETED,
    'Soft-deleting a target keeps the reference value and reports DELETED',
  );
  assert(
    lifecycleField.value === liveTarget.id &&
      resolveEntryReference(
        lifecycleField,
        renamedReferenceTemplate,
        [makeEntry(liveTarget.id, liveTarget.label, 'Identity')],
      ).status === EntryReferenceStatus.RESOLVED,
    'Restoring a target keeps the reference value and reports RESOLVED',
  );
  assert(
    lifecycleField.value === liveTarget.id &&
      resolveEntryReference(lifecycleField, renamedReferenceTemplate, [movedTarget]).status ===
        EntryReferenceStatus.CATEGORY_MISMATCH,
    'Moving a target keeps the reference value and reports CATEGORY_MISMATCH',
  );

  if (failures > 0) {
    console.error(`[FAIL] Harmony reference resolver tests failed: ${failures}`);
    process.exit(1);
  }
  console.log('[OK] Harmony reference resolver tests passed');
}

main();
