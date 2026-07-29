#!/usr/bin/env node
import fs from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import path from 'node:path';
import process from 'node:process';
import vm from 'node:vm';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const modelPath = path.join(
  root,
  'apps/harmony_app/entry/src/main/ets/src/model/VaultTypes.ets',
);
const editingPath = path.join(
  root,
  'apps/harmony_app/entry/src/main/ets/src/domain/CategoryTemplateEditing.ets',
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

function extractFunction(source, name) {
  const start = source.indexOf(`function ${name}(`);
  if (start < 0) {
    throw new Error(`Cannot find Harmony controller function: ${name}`);
  }
  const bodyStart = source.indexOf('{', start);
  let depth = 0;
  let quote = '';
  let escaped = false;
  for (let index = bodyStart; index < source.length; index++) {
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
  throw new Error(`Cannot find the end of Harmony controller function: ${name}`);
}

function loadEditingRuntime() {
  const source = fs.readFileSync(editingPath, 'utf8')
    .replace(/import\s*{[\s\S]*?}\s*from\s*'\.\.\/model\/VaultTypes';\s*/, '')
    .replace(/\bexport\s+/g, '');
  const executable = stripTypeScriptTypes(
    `${source}\n;({ categoryTemplateFieldsForUserSave });`,
    { mode: 'transform' },
  );
  return vm.runInNewContext(executable, {});
}

function loadControllerRuntime(controllerSource) {
  const functionNames = [
    'createScopedItemExportRecord',
    'createScopedCategoryExportRecord',
    'decodeScopedImportRecord',
    'readString',
    'canonicalIdString',
    'defaultCategoryFields',
    'createFieldTemplate',
    'stableFieldId',
    'utf8Hex',
    'normalizeCategoryTemplates',
    'normalizeCategoryTemplate',
    'normalizeFieldTemplates',
    'mergeEditableTemplateFields',
    'mergeCategoryTemplates',
    'mergeImportedCategoryTemplateDefinitions',
    'cloneCategoryTemplate',
    'cloneFieldTemplate',
    'categoryTemplatesForExport',
    'normalizeFieldValueType',
    'readPreservedString',
  ];
  const source = `${functionNames.map((name) => extractFunction(controllerSource, name)).join('\n')}
    ;({ ${functionNames.join(', ')} });`;
  return vm.runInNewContext(
    stripTypeScriptTypes(source, { mode: 'transform' }),
    {},
  );
}

function fieldReferenceTemplate() {
  return {
    id: 'Template-Owner-Email',
    name: 'Owner Email',
    valueType: 'fieldReference',
    targetCategory: ' Accounts ',
    targetFieldId: 'Template-Account-Email',
  };
}

function main() {
  const modelSource = fs.readFileSync(modelPath, 'utf8');
  const controllerSource = fs.readFileSync(controllerPath, 'utf8');
  const editing = loadEditingRuntime();
  const runtime = loadControllerRuntime(controllerSource);

  assert(
    modelSource.includes('targetFieldId?: string;'),
    'Harmony FieldTemplate exposes optional targetFieldId metadata',
  );

  const fixturePath = path.join(
    root,
    'fixtures/vault-contract/v1/snapshot-field-reference.json',
  );
  const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
  const fixtureSourceTemplate = fixture.categoryTemplates
    .find((template) => template.category === 'Servers')?.fields
    .find((field) => field.name === 'Owner Email');
  const fixtureTargetTemplate = fixture.categoryTemplates
    .find((template) => template.category === 'Accounts')?.fields
    .find((field) => field.name === 'Email');
  const fixtureSourceEntry = fixture.entries
    .find((entry) => entry.label === 'Production Server');
  const fixtureSourceValue = fixtureSourceEntry?.customFields
    .find((field) => field.name === 'Owner Email');
  assert(
    fixtureSourceTemplate?.valueType === 'fieldReference',
    'Shared fixture declares fieldReference source semantics',
  );
  assert(
    fixtureSourceTemplate?.targetCategory === 'Accounts',
    'Shared fixture declares the target category',
  );
  assert(
    fixtureSourceTemplate?.targetFieldId === fixtureTargetTemplate?.id,
    'Shared fixture binds targetFieldId to the stable target template field',
  );
  assert(
    fixtureSourceValue?.templateFieldId === fixtureSourceTemplate?.id &&
      fixtureSourceValue?.value === 'account_target_01',
    'Shared fixture source value binds its source template and stores the target entry ID',
  );
  const fixtureRoundTrip = JSON.parse(JSON.stringify({
    categoryTemplates: runtime.normalizeCategoryTemplates(fixture.categoryTemplates, []),
    entries: fixture.entries,
  }));
  const roundTripSourceTemplate = fixtureRoundTrip.categoryTemplates
    .find((template) => template.category === 'Servers')?.fields[0];
  assert(
    roundTripSourceTemplate?.valueType === fixtureSourceTemplate?.valueType &&
      roundTripSourceTemplate?.targetCategory === fixtureSourceTemplate?.targetCategory &&
      roundTripSourceTemplate?.targetFieldId === fixtureSourceTemplate?.targetFieldId,
    'Harmony normalization and JSON round trip preserve shared fixture metadata',
  );

  const created = runtime.createFieldTemplate('Notes');
  assert(
    created.valueType === 'text' &&
      created.targetCategory === '' &&
      created.targetFieldId === '',
    'New text templates initialize reference metadata to empty strings',
  );

  const legacy = runtime.normalizeFieldTemplates([
    { id: 'Legacy-Template', name: 'Legacy Field' },
  ])[0];
  assert(
    legacy.valueType === 'text' &&
      legacy.targetCategory === '' &&
      legacy.targetFieldId === '',
    'Legacy templates default missing targetFieldId to an empty string',
  );

  const reference = fieldReferenceTemplate();
  const normalizedReference = runtime.normalizeFieldTemplates([reference])[0];
  assert(
    normalizedReference.valueType === reference.valueType &&
      normalizedReference.targetCategory === reference.targetCategory &&
      normalizedReference.targetFieldId === reference.targetFieldId,
    'Normalization preserves fieldReference metadata without reinterpretation',
  );

  const future = {
    ...reference,
    id: 'Template-Future',
    name: 'Future Link',
    valueType: 'futureRelationV4',
    targetFieldId: 'Future-Target-Field',
  };
  const normalizedFuture = runtime.normalizeFieldTemplates([future])[0];
  assert(
    normalizedFuture.valueType === 'futureRelationV4' &&
      normalizedFuture.targetFieldId === 'Future-Target-Field',
    'Unknown value types retain targetFieldId metadata',
  );

  const cloned = runtime.cloneFieldTemplate(normalizedFuture);
  assert(
    cloned !== normalizedFuture &&
      cloned.valueType === normalizedFuture.valueType &&
      cloned.targetFieldId === normalizedFuture.targetFieldId,
    'Template cloning preserves unknown value type and targetFieldId',
  );

  const edited = editing.categoryTemplateFieldsForUserSave(
    [normalizedFuture],
    [],
  );
  const editedFuture = edited.find((field) => field.id === normalizedFuture.id);
  assert(
    editedFuture?.valueType === normalizedFuture.valueType &&
      editedFuture?.targetFieldId === normalizedFuture.targetFieldId,
    'Category editing keeps unsupported field metadata read-only and lossless',
  );

  const editableReference = {
    id: 'Template-Entry-Reference',
    name: 'Owner',
    valueType: 'entryReference',
    targetCategory: 'Accounts',
    targetFieldId: 'Forward-Compatible-Target-Field',
  };
  const legacyEditRequest = { ...editableReference };
  delete legacyEditRequest.targetFieldId;
  const editedReference = editing.categoryTemplateFieldsForUserSave(
    [editableReference],
    [legacyEditRequest],
  ).find((field) => field.id === editableReference.id);
  assert(
    editedReference?.targetFieldId === editableReference.targetFieldId,
    'Legacy category edit requests cannot clear existing targetFieldId metadata',
  );

  const mergedEditable = runtime.mergeEditableTemplateFields(
    [{
      id: 'Existing-Text',
      name: 'Old Name',
      valueType: 'text',
      targetCategory: '',
      targetFieldId: 'Preserved-Extension-Value',
    }],
    [{ id: 'Requested-Text', name: 'New Name', valueType: 'text' }],
  );
  assert(
    mergedEditable[0].id === 'Existing-Text' &&
      mergedEditable[0].targetFieldId === 'Preserved-Extension-Value',
    'Editable template merge keeps existing extension metadata',
  );

  const sourceTemplates = [{ category: 'Servers', fields: [normalizedReference] }];
  const imported = runtime.mergeImportedCategoryTemplateDefinitions([], sourceTemplates);
  assert(
    imported[0].fields[0].targetFieldId === reference.targetFieldId,
    'Scoped import template merge preserves targetFieldId',
  );

  const exported = runtime.categoryTemplatesForExport(imported, ['Servers']);
  const itemRecord = runtime.createScopedItemExportRecord(
    { id: 'Source-Entry' },
    exported,
    '2026-07-29T00:00:00Z',
  );
  const decoded = runtime.decodeScopedImportRecord(JSON.stringify(itemRecord), 'item');
  assert(
    decoded.categoryTemplates[0].fields[0].targetFieldId === reference.targetFieldId,
    'Scoped export and decode round trip targetFieldId',
  );

  const synced = runtime.mergeCategoryTemplates([], sourceTemplates, [], ['Servers']);
  assert(
    synced[0].fields[0].valueType === 'fieldReference' &&
      synced[0].fields[0].targetFieldId === reference.targetFieldId,
    'Sync template merge preserves fieldReference metadata',
  );

  const upsertSource = controllerSource.slice(
    controllerSource.indexOf('  private upsertCategoryTemplate('),
    controllerSource.indexOf('  private async applyScopedImport('),
  );
  assert(
    upsertSource.includes('targetFieldId: readPreservedString(field.targetFieldId)'),
    'VaultController upsert preserves targetFieldId',
  );
  assert(
    controllerSource.includes('const templates = normalizeCategoryTemplates(') &&
      controllerSource.includes('const uploadPayload = sanitizeRuntimePayload(mergedPayload);'),
    'Persistence and sync continue through the shared template normalization path',
  );

  if (failures > 0) {
    console.error(`[FAIL] Harmony field-reference contract compatibility tests failed: ${failures}`);
    process.exit(1);
  }
  console.log('[OK] Harmony field-reference contract compatibility tests passed');
}

main();
