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
    `${source}\n;({ EntryReferenceStatus, FieldValueReferenceStatus, propagateEntryReferenceCategoryRename, resolveEntryReference, resolveFieldValueReference, targetFieldReferenceIdsForCategory });`,
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
    FieldValueReferenceStatus,
    propagateEntryReferenceCategoryRename,
    resolveEntryReference,
    resolveFieldValueReference,
    targetFieldReferenceIdsForCategory,
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

  const targetFieldTemplate = {
    id: 'Target-Email',
    name: 'Directory Address',
    valueType: 'text',
    targetCategory: '',
    targetFieldId: '',
  };
  const sourceFieldTemplate = {
    id: 'Source-Owner-Email',
    name: 'Owner Email',
    valueType: 'fieldReference',
    targetCategory: ' Accounts ',
    targetFieldId: targetFieldTemplate.id,
  };
  const fieldTemplates = [
    { category: 'Accounts', fields: [targetFieldTemplate] },
    { category: 'Servers', fields: [sourceFieldTemplate] },
  ];
  const fieldSource = makeEntry('Source-Server', 'Production Server', 'Servers');
  fieldSource.customFields = [{
    id: 'Source-Owner-Email-Value',
    name: 'Owner Email',
    templateFieldId: sourceFieldTemplate.id,
    value: 'Target-Account',
  }];
  const fieldTarget = makeEntry('Target-Account', 'Production Account', ' accounts ');
  fieldTarget.customFields = [{
    id: 'Target-Email-Value',
    name: 'Old Email Name',
    templateFieldId: targetFieldTemplate.id,
    value: 'ops@example.com',
  }];
  const resolveField = (source = fieldSource, target = fieldTarget, templates = fieldTemplates) =>
    resolveFieldValueReference(source, source.customFields[0], templates, [source, target]);

  const fieldResolved = resolveField();
  assert(
    fieldResolved.status === FieldValueReferenceStatus.RESOLVED &&
      JSON.stringify(fieldResolved.target) === JSON.stringify({
        id: fieldTarget.id,
        label: fieldTarget.label,
        category: 'accounts',
        fieldId: targetFieldTemplate.id,
        fieldName: targetFieldTemplate.name,
        value: 'ops@example.com',
      }),
    'Field references resolve one text field through stable template and entry IDs',
  );
  assert(
    Object.keys(fieldResolved.target).sort().join(',') ===
      'category,fieldId,fieldName,id,label,value' &&
      fieldResolved.target.payload === undefined,
    'Field-reference projections exclude the complete target entry and payload',
  );

  const nameFieldTemplates = JSON.parse(JSON.stringify(fieldTemplates));
  const nameFieldTemplate = {
    id: 'template_名称',
    name: '名称',
    valueType: 'text',
    targetCategory: '',
    targetFieldId: '',
  };
  nameFieldTemplates[0].fields = [nameFieldTemplate];
  nameFieldTemplates[1].fields[0].targetFieldId = nameFieldTemplate.id;
  const nameFieldTarget = JSON.parse(JSON.stringify(fieldTarget));
  nameFieldTarget.customFields = [];
  const nameFieldResolved = resolveField(fieldSource, nameFieldTarget, nameFieldTemplates);
  assert(
    nameFieldResolved.status === FieldValueReferenceStatus.RESOLVED &&
      nameFieldResolved.target.fieldId === nameFieldTemplate.id &&
      nameFieldResolved.target.fieldName === '名称' &&
      nameFieldResolved.target.value === fieldTarget.label,
    'The built-in entry name target resolves from the target entry label',
  );

  const legacyFieldTarget = JSON.parse(JSON.stringify(fieldTarget));
  legacyFieldTarget.customFields[0].templateFieldId = '';
  legacyFieldTarget.customFields[0].name = '  directory address  ';
  legacyFieldTarget.customFields[0].value = 'legacy@example.com';
  const legacyFieldResolved = resolveField(fieldSource, legacyFieldTarget);
  assert(
    legacyFieldResolved.status === FieldValueReferenceStatus.RESOLVED &&
      legacyFieldResolved.target.value === 'legacy@example.com',
    'Legacy target fields with an empty template ID use normalized name fallback',
  );

  const exactFieldPrecedenceTarget = JSON.parse(JSON.stringify(fieldTarget));
  exactFieldPrecedenceTarget.customFields = [
    {
      id: 'Legacy-Target-Email',
      name: '  directory address  ',
      templateFieldId: '',
      value: 'legacy@example.com',
    },
    {
      id: 'Exact-Target-Email',
      name: 'Renamed Directory Address',
      templateFieldId: targetFieldTemplate.id,
      value: '  ',
    },
  ];
  assert(
    resolveField(fieldSource, exactFieldPrecedenceTarget).status ===
      FieldValueReferenceStatus.TARGET_FIELD_EMPTY,
    'Exact target field IDs win globally over earlier legacy name matches',
  );

  const wronglyBoundFieldTarget = JSON.parse(JSON.stringify(fieldTarget));
  wronglyBoundFieldTarget.customFields[0].templateFieldId = 'target-email';
  wronglyBoundFieldTarget.customFields[0].name = '  directory address  ';
  const wronglyBoundResolution = resolveField(fieldSource, wronglyBoundFieldTarget);
  assert(
    wronglyBoundResolution.status === FieldValueReferenceStatus.TARGET_FIELD_EMPTY,
    'Non-empty wrong target template IDs remain opaque and never fall back by name',
  );

  const emptySource = JSON.parse(JSON.stringify(fieldSource));
  emptySource.customFields[0].value = '  ';
  assert(
    resolveField(emptySource).status === FieldValueReferenceStatus.EMPTY,
    'Field-reference empty values win before configuration and target lookup',
  );
  const invalidTemplates = JSON.parse(JSON.stringify(fieldTemplates));
  invalidTemplates[1].fields[0].targetFieldId = '';
  assert(
    resolveField(fieldSource, fieldTarget, invalidTemplates).status ===
      FieldValueReferenceStatus.INVALID_CONFIGURATION,
    'Missing target field configuration is explicit',
  );
  const selfTemplates = JSON.parse(JSON.stringify(fieldTemplates));
  selfTemplates[1].fields[0].targetCategory = 'Servers';
  selfTemplates[1].fields[0].targetFieldId = sourceFieldTemplate.id;
  assert(
    resolveField(fieldSource, fieldTarget, selfTemplates).status ===
      FieldValueReferenceStatus.INVALID_CONFIGURATION,
    'A field cannot reference itself',
  );
  const missingSource = JSON.parse(JSON.stringify(fieldSource));
  missingSource.customFields[0].value = 'Missing-Target';
  assert(
    resolveField(missingSource).status === FieldValueReferenceStatus.MISSING,
    'Missing field-reference target entries are distinct',
  );
  const deletedFieldTarget = JSON.parse(JSON.stringify(fieldTarget));
  deletedFieldTarget.isDeleted = true;
  assert(
    resolveField(fieldSource, deletedFieldTarget).status === FieldValueReferenceStatus.DELETED,
    'Deleted field-reference targets retain the relationship',
  );
  const movedFieldTarget = JSON.parse(JSON.stringify(fieldTarget));
  movedFieldTarget.payload.category = 'Archive';
  assert(
    resolveField(fieldSource, movedFieldTarget).status ===
      FieldValueReferenceStatus.CATEGORY_MISMATCH,
    'Moved field-reference targets retain the relationship and report mismatch',
  );
  const missingFieldTemplates = JSON.parse(JSON.stringify(fieldTemplates));
  missingFieldTemplates[0].fields = [];
  assert(
    resolveField(fieldSource, fieldTarget, missingFieldTemplates).status ===
      FieldValueReferenceStatus.TARGET_FIELD_MISSING,
    'Deleted target template fields are distinct from missing entries',
  );
  const unsupportedFieldTemplates = JSON.parse(JSON.stringify(fieldTemplates));
  unsupportedFieldTemplates[0].fields[0].valueType = 'entryReference';
  assert(
    resolveField(fieldSource, fieldTarget, unsupportedFieldTemplates).status ===
      FieldValueReferenceStatus.TARGET_FIELD_UNSUPPORTED,
    'Reference chains and non-text target fields are rejected',
  );
  const emptyFieldTarget = JSON.parse(JSON.stringify(fieldTarget));
  emptyFieldTarget.customFields = [];
  assert(
    resolveField(fieldSource, emptyFieldTarget).status ===
      FieldValueReferenceStatus.TARGET_FIELD_EMPTY,
    'Absent target field instances resolve as an empty target field',
  );
  emptyFieldTarget.customFields = [{
    id: 'Blank-Target-Email',
    name: 'Email',
    templateFieldId: targetFieldTemplate.id,
    value: '\n',
  }];
  assert(
    resolveField(fieldSource, emptyFieldTarget).status ===
      FieldValueReferenceStatus.TARGET_FIELD_EMPTY,
    'Blank target text values resolve as an empty target field',
  );
  assert(
    targetFieldReferenceIdsForCategory(fieldTemplates, ' accounts ').has(targetFieldTemplate.id) &&
      !targetFieldReferenceIdsForCategory(fieldTemplates, 'Accounts').has('TARGET-EMAIL'),
    'Inbound target-field dependencies use category normalization and exact opaque field IDs',
  );
  const renamedFieldTemplates = propagateEntryReferenceCategoryRename(
    fieldTemplates,
    'accounts',
    'Identity',
  );
  assert(
    renamedFieldTemplates[1].fields[0].targetCategory === 'Identity' &&
      renamedFieldTemplates[1].fields[0].targetFieldId === targetFieldTemplate.id,
    'Category rename propagates field references without changing targetFieldId',
  );

  if (failures > 0) {
    console.error(`[FAIL] Harmony reference resolver tests failed: ${failures}`);
    process.exit(1);
  }
  console.log('[OK] Harmony reference resolver tests passed');
}

main();
