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
const categoryEditingPath = path.join(
  root,
  'apps/harmony_app/entry/src/main/ets/src/domain/CategoryTemplateEditing.ets',
);
const controllerPath = path.join(
  root,
  'apps/harmony_app/entry/src/main/ets/src/service/VaultController.ets',
);
const indexPath = path.join(
  root,
  'apps/harmony_app/entry/src/main/ets/pages/Index.ets',
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

function loadRuntime() {
  const resolver = fs.readFileSync(resolverPath, 'utf8')
    .replace(/import\s*{[\s\S]*?}\s*from\s*'\.\.\/model\/VaultTypes';\s*/, '')
    .replace(/\bexport\s+/g, '');
  const operations = fs.readFileSync(operationsPath, 'utf8')
    .replace(/import\s*{[\s\S]*?}\s*from\s*'\.\.\/model\/VaultTypes';\s*/, '')
    .replace(/import\s*{[\s\S]*?}\s*from\s*'\.\/FieldReferenceResolver';\s*/, '')
    .replace(/\bexport\s+/g, '');
  const categoryEditing = fs.readFileSync(categoryEditingPath, 'utf8')
    .replace(/import\s*{[\s\S]*?}\s*from\s*'\.\.\/model\/VaultTypes';\s*/, '')
    .replace(/\bexport\s+/g, '');
  const executable = stripTypeScriptTypes(
    `${resolver}\n${operations}\n${categoryEditing}\n;({
      EntryReferenceStatus,
      FieldValueReferenceStatus,
      canExposeRawCustomFieldValue,
      categoryTemplateFieldsForUserSave,
      entryReferenceCandidates,
      isEditableCategoryFieldType,
      resolveEntryReference,
      resolveFieldValueReference,
      safeCustomFieldSearchValues,
    });`,
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
      password: `password-for-${id}`,
      token: `token-for-${id}`,
      secretKey: `secret-for-${id}`,
      notes: `notes-for-${id}`,
    },
    tags: [],
    customFields: [],
    createdAt: 1,
    updatedAt: 1,
    isDeleted,
  };
}

function methodSlice(source, start, end) {
  const startIndex = source.indexOf(start);
  if (startIndex < 0) {
    return '';
  }
  const endIndex = source.indexOf(end, startIndex + start.length);
  return endIndex < 0 ? source.slice(startIndex) : source.slice(startIndex, endIndex);
}

function extractMethod(source, signature) {
  const start = source.indexOf(signature);
  if (start < 0) {
    throw new Error(`Cannot find Harmony page method: ${signature.trim()}`);
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
  throw new Error(`Cannot find end of Harmony page method: ${signature.trim()}`);
}

function loadIndexMethod(indexSource, signature, methodName, globals = {}) {
  const method = extractMethod(indexSource, signature)
    .replace(/^\s*private\s+/, 'function ');
  const executable = stripTypeScriptTypes(`${method}\n;${methodName};`, { mode: 'transform' });
  return vm.runInNewContext(executable, globals);
}

function loadSourceFunction(source, signature, functionName, globals = {}) {
  const executable = stripTypeScriptTypes(
    `${extractMethod(source, signature)}\n;${functionName};`,
    { mode: 'transform' },
  );
  return vm.runInNewContext(executable, globals);
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function excludesSentinels(values, sentinels) {
  const strings = (Array.isArray(values) ? values : [values]).map((value) => `${value}`);
  return sentinels.every((sentinel) =>
    strings.every((value) => !value.includes(sentinel))
  );
}

const canonicalLowercaseUuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function main() {
  [resolverPath, operationsPath, categoryEditingPath, controllerPath, indexPath].forEach((file) => {
    assert(fs.existsSync(file), `Required Harmony field-reference file exists: ${path.relative(root, file)}`);
  });

  const runtime = loadRuntime();
  const controllerSource = fs.readFileSync(controllerPath, 'utf8');
  const indexSource = fs.readFileSync(indexPath, 'utf8');
  const indexGlobals = {
    EntryReferenceStatus: runtime.EntryReferenceStatus,
    FieldValueReferenceStatus: runtime.FieldValueReferenceStatus,
    canExposeRawCustomFieldValue: runtime.canExposeRawCustomFieldValue,
    isEditableCategoryFieldType: runtime.isEditableCategoryFieldType,
    util: {
      generateRandomUUID() {
        return '550E8400-E29B-41D4-A716-446655440000';
      },
    },
  };
  const updateDraftCustomFieldValue = loadIndexMethod(
    indexSource, '  private updateDraftCustomFieldValue(', 'updateDraftCustomFieldValue', indexGlobals,
  );
  const selectActiveDraftReference = loadIndexMethod(
    indexSource, '  private selectActiveDraftReference(', 'selectActiveDraftReference', indexGlobals,
  );
  const clearActiveDraftReference = loadIndexMethod(
    indexSource, '  private clearActiveDraftReference(', 'clearActiveDraftReference', indexGlobals,
  );
  const copyCustomFields = loadIndexMethod(
    indexSource, '  private copyCustomFields(', 'copyCustomFields', indexGlobals,
  );
  const normalizedDraftCustomFields = loadIndexMethod(
    indexSource, '  private normalizedDraftCustomFields(', 'normalizedDraftCustomFields', indexGlobals,
  );
  const isUnsupportedCustomField = loadIndexMethod(
    indexSource, '  private isUnsupportedCustomField(', 'isUnsupportedCustomField', indexGlobals,
  );
  const entryReferenceDetailText = loadIndexMethod(
    indexSource, '  private entryReferenceDetailText(', 'entryReferenceDetailText', indexGlobals,
  );
  const fieldReferenceDetailText = loadIndexMethod(
    indexSource, '  private fieldReferenceDetailText(', 'fieldReferenceDetailText', indexGlobals,
  );
  const fieldReferenceConfigurationNeedsRepair = loadIndexMethod(
    indexSource,
    '  private fieldReferenceConfigurationNeedsRepair(',
    'fieldReferenceConfigurationNeedsRepair',
    indexGlobals,
  );
  const fieldReferenceCanSelectEntry = loadIndexMethod(
    indexSource,
    '  private fieldReferenceCanSelectEntry(',
    'fieldReferenceCanSelectEntry',
    indexGlobals,
  );
  const isEditableDraftReferenceField = loadIndexMethod(
    indexSource,
    '  private isEditableDraftReferenceField(',
    'isEditableDraftReferenceField',
    indexGlobals,
  );
  const protectedCustomFieldIdsForCategory = loadIndexMethod(
    indexSource,
    '  private protectedCustomFieldIdsForCategory(',
    'protectedCustomFieldIdsForCategory',
    indexGlobals,
  );
  const entrySummaryField = loadIndexMethod(
    indexSource, '  private entrySummaryField(', 'entrySummaryField', indexGlobals,
  );
  const nextUiId = loadIndexMethod(indexSource, '  private nextUiId(', 'nextUiId', indexGlobals);
  const categoryDraftTemplateFieldDefinitions = loadIndexMethod(
    indexSource,
    '  private categoryDraftTemplateFieldDefinitions(',
    'categoryDraftTemplateFieldDefinitions',
    indexGlobals,
  );
  const categoryDraftFieldReferenceError = loadIndexMethod(
    indexSource,
    '  private categoryDraftFieldReferenceError(',
    'categoryDraftFieldReferenceError',
    indexGlobals,
  );
  const categoryDraftTargetFieldTemplates = loadIndexMethod(
    indexSource,
    '  private categoryDraftTargetFieldTemplates(',
    'categoryDraftTargetFieldTemplates',
    indexGlobals,
  );
  const protectDraftFieldsBeforeCategorySwitch = loadIndexMethod(
    indexSource,
    '  private protectDraftFieldsBeforeCategorySwitch(',
    'protectDraftFieldsBeforeCategorySwitch',
    indexGlobals,
  );
  const applyCategoryTemplateToDraft = loadIndexMethod(
    indexSource, '  private applyCategoryTemplateToDraft(', 'applyCategoryTemplateToDraft', indexGlobals,
  );
  const selectDraftCategory = loadIndexMethod(
    indexSource, '  private selectDraftCategory(', 'selectDraftCategory', indexGlobals,
  );
  const draftFieldBelongsToCategory = loadIndexMethod(
    indexSource,
    '  private draftFieldBelongsToCategory(',
    'draftFieldBelongsToCategory',
    indexGlobals,
  );

  const baseFields = [
    { id: 'template_名称', name: '名称', valueType: 'text', targetCategory: '' },
    { id: 'template_备注', name: '备注', valueType: 'text', targetCategory: '' },
  ];
  const crossCategoryTargets = categoryDraftTargetFieldTemplates.call({
    categoryDraftIsCurrentCategory() {
      return false;
    },
    categoryTemplate() {
      return { category: 'Accounts', fields: baseFields };
    },
    isTextTemplateField(field) {
      return field.valueType === 'text';
    },
  }, { value: 'Accounts' });
  assert(
    JSON.stringify(crossCategoryTargets.map((field) => field.id)) ===
      JSON.stringify(['template_名称', 'template_备注']),
    'Field references can target the built-in entry name as well as custom text fields',
  );
  const stableText = {
    id: 'Text-Stable', name: 'Owner', valueType: 'text', targetCategory: '',
  };
  const stableReference = {
    id: 'Reference-Stable',
    name: 'Account',
    valueType: 'entryReference',
    targetCategory: 'Accounts',
  };
  const stableFieldReference = {
    id: 'Field-Reference-Stable',
    name: 'Account Email',
    valueType: 'fieldReference',
    targetCategory: 'Accounts',
    targetFieldId: 'Target-Email',
  };
  const futureTemplate = {
    id: 'Future-Stable',
    name: 'Future Field',
    valueType: 'futureRelationV3',
    targetCategory: '  Future Targets  ',
  };
  const existingFields = [
    ...baseFields,
    stableText,
    stableReference,
    stableFieldReference,
    futureTemplate,
  ];
  const unchangedSave = runtime.categoryTemplateFieldsForUserSave(existingFields, [
    clone(stableText), clone(stableReference), clone(stableFieldReference),
  ]);
  assert(
    JSON.stringify(unchangedSave.find((field) => field.id === stableReference.id)) ===
      JSON.stringify(stableReference),
    'A→A category-field save preserves the stable reference definition unchanged',
  );
  assert(
    JSON.stringify(unchangedSave.find((field) => field.id === futureTemplate.id)) ===
      JSON.stringify(futureTemplate),
    'Unknown field types remain read-only and preserve all template metadata verbatim',
  );
  assert(
    unchangedSave.some((field) => field.name === '名称') &&
      unchangedSave.some((field) => field.name === '备注'),
    'Category saves retain the required name and notes base fields',
  );
  assert(
    runtime.isEditableCategoryFieldType('text') &&
      runtime.isEditableCategoryFieldType('fieldReference') &&
      !runtime.isEditableCategoryFieldType('entryReference') &&
      !runtime.isEditableCategoryFieldType('futureRelationV3'),
    'Only text and field-reference category field types are editable',
  );
  assert(
    JSON.stringify(unchangedSave.find((field) => field.id === stableFieldReference.id)) ===
      JSON.stringify(stableFieldReference),
    'Field-reference category saves retain targetCategory and targetFieldId',
  );

  const storedValueFieldIds = new Set([
    stableText.id,
    stableReference.id,
    stableFieldReference.id,
  ]);
  const deletedReferenceSave = runtime.categoryTemplateFieldsForUserSave(
    existingFields, [clone(stableText)], storedValueFieldIds,
  );
  assert(
    JSON.stringify(deletedReferenceSave.find((field) => field.id === stableReference.id)) ===
      JSON.stringify(stableReference),
    'Saving a category cannot silently delete an existing entry-reference definition',
  );
  const referenceToTextSave = runtime.categoryTemplateFieldsForUserSave(existingFields, [
    clone(stableText),
    { ...stableReference, valueType: 'text', targetCategory: '' },
  ], storedValueFieldIds);
  assert(
    JSON.stringify(referenceToTextSave.find((field) => field.id === stableReference.id)) ===
      JSON.stringify(stableReference),
    'Saving a category cannot silently reinterpret stored reference IDs as text',
  );
  const textToReferenceSave = runtime.categoryTemplateFieldsForUserSave(existingFields, [
    { ...stableText, valueType: 'entryReference', targetCategory: 'Accounts' },
    clone(stableReference),
  ], storedValueFieldIds);
  assert(
    JSON.stringify(textToReferenceSave.find((field) => field.id === stableText.id)) ===
      JSON.stringify(stableText),
    'Saving a category cannot silently reinterpret stored text as reference IDs',
  );
  const referencedTargetText = {
    id: 'Target-Email',
    name: 'Email',
    valueType: 'text',
    targetCategory: '',
    targetFieldId: '',
  };
  const protectedTargetIds = new Set([referencedTargetText.id]);
  const deletedTargetFieldSave = runtime.categoryTemplateFieldsForUserSave(
    [...baseFields, referencedTargetText],
    [],
    protectedTargetIds,
  );
  assert(
    JSON.stringify(deletedTargetFieldSave.find((field) => field.id === referencedTargetText.id)) ===
      JSON.stringify(referencedTargetText),
    'A target text field cannot be deleted while a fieldReference points to it',
  );
  const retypedTargetFieldSave = runtime.categoryTemplateFieldsForUserSave(
    [...baseFields, referencedTargetText],
    [{ ...referencedTargetText, valueType: 'entryReference', targetCategory: 'Accounts' }],
    protectedTargetIds,
  );
  assert(
    JSON.stringify(retypedTargetFieldSave.find((field) => field.id === referencedTargetText.id)) ===
      JSON.stringify(referencedTargetText),
    'A target text field cannot be retyped while a fieldReference points to it',
  );
  const renamedTargetFieldSave = runtime.categoryTemplateFieldsForUserSave(
    [...baseFields, referencedTargetText],
    [{ ...referencedTargetText, name: 'Directory Address' }],
    protectedTargetIds,
  );
  assert(
    renamedTargetFieldSave.find((field) => field.id === referencedTargetText.id)?.name ===
      'Directory Address',
    'A referenced target text field can be renamed because its stable ID is unchanged',
  );
  const categoryTemplateFieldIdsWithStoredValues = loadIndexMethod(
    controllerSource,
    '  private categoryTemplateFieldIdsWithStoredValues(',
    'categoryTemplateFieldIdsWithStoredValues',
  );
  const storedFieldValues = [
    {
      id: 'field-instance',
      name: stableReference.name,
      value: 'stored-target-id',
      templateFieldId: stableReference.id,
    },
    {
      id: 'unrelated-instance',
      name: 'Unrelated',
      value: 'must-not-protect',
      templateFieldId: 'Other-Template-Field',
    },
  ];
  const liveEntry = makeEntry('live-entry', 'Live Entry', 'Original Category');
  liveEntry.customFields = clone(storedFieldValues);
  const deletedEntry = makeEntry('deleted-entry', 'Deleted Entry', 'Original Category');
  deletedEntry.isDeleted = true;
  deletedEntry.customFields = clone(storedFieldValues);
  const movedEntry = makeEntry('moved-entry', 'Moved Entry', 'Other Category');
  movedEntry.customFields = clone(storedFieldValues);
  const liveEntryStoredValueFieldIds = categoryTemplateFieldIdsWithStoredValues.call({
    entryCategory(entry) {
      return entry.payload.category;
    },
    snapshot: {
      categoryTemplates: [{
        category: 'Original Category',
        fields: [...baseFields, stableReference],
      }],
      entries: [liveEntry, deletedEntry, movedEntry],
    },
  }, 'Original Category');
  assert(
    liveEntryStoredValueFieldIds.has(stableReference.id) &&
      !liveEntryStoredValueFieldIds.has('Other-Template-Field'),
    'A live non-empty source value protects its template field',
  );
  const historicalEntryStoredValueFieldIds = categoryTemplateFieldIdsWithStoredValues.call({
    entryCategory(entry) {
      return entry.payload.category;
    },
    snapshot: {
      categoryTemplates: [{
        category: 'Original Category',
        fields: [...baseFields, stableReference],
      }],
      entries: [deletedEntry, movedEntry],
    },
  }, 'Original Category');
  assert(
    historicalEntryStoredValueFieldIds.size === 0,
    'Deleted and moved source entries do not keep an unrelated category field locked',
  );
  const normalizeFieldTemplates = loadSourceFunction(
    controllerSource,
    'function normalizeFieldTemplates(',
    'normalizeFieldTemplates',
    {
      canonicalIdString(value) {
        return typeof value === 'string' ? value.trim() : '';
      },
      defaultCategoryFields() {
        return clone(baseFields);
      },
      nextFieldId() {
        return '550e8400-e29b-41d4-a716-446655440000';
      },
      normalizeFieldValueType(value) {
        return typeof value === 'string' && value.length > 0 ? value : 'text';
      },
      readPreservedString(value) {
        return typeof value === 'string' ? value : '';
      },
      readString(value) {
        return typeof value === 'string' ? value.trim() : '';
      },
      stableFieldId(name) {
        return `template_${name.trim().toLowerCase().replace(/\s+/g, '_')}`;
      },
      util: indexGlobals.util,
    },
  );
  const newlySavedTemplate = normalizeFieldTemplates([{
    id: '',
    name: 'New Reference',
    valueType: 'entryReference',
    targetCategory: 'Accounts',
  }])[0];
  assert(
    newlySavedTemplate?.id === 'template_new_reference',
    'Legacy template input without an ID retains the deterministic stable-field fallback',
  );
  const newDraftFieldId = nextUiId.call({});
  assert(
    canonicalLowercaseUuid.test(newDraftFieldId),
    'New custom-field instance IDs are canonical lowercase UUIDs',
  );
  const draftTemplateDefinitions = categoryDraftTemplateFieldDefinitions.call({
    categoryDraftCustomFields: [
      {
        id: newDraftFieldId,
        name: 'New Reference',
        value: ' Accounts ',
      },
      {
        id: 'Existing-Custom-Field-ID',
        templateFieldId: 'Existing-Template-Field-ID',
        name: 'Existing Text',
        value: 'must-not-become-target-category',
      },
    ],
    categoryDraftFieldValueType(fieldId) {
      return fieldId === newDraftFieldId ? 'fieldReference' : 'text';
    },
    categoryDraftTargetFieldId(fieldId) {
      return fieldId === newDraftFieldId ? 'Target-Email' : '';
    },
  });
  const newDraftDefinition = draftTemplateDefinitions.find(
    (field) => field.name === 'New Reference',
  );
  const existingDraftDefinition = draftTemplateDefinitions.find(
    (field) => field.name === 'Existing Text',
  );
  assert(
    newDraftDefinition?.id === newDraftFieldId &&
      canonicalLowercaseUuid.test(newDraftDefinition.id) &&
      newDraftDefinition.targetCategory === 'Accounts' &&
      newDraftDefinition.targetFieldId === 'Target-Email',
    'The new template-field writer carries stable source and target IDs into the saved definition',
  );
  assert(
    existingDraftDefinition?.id === 'Existing-Template-Field-ID' &&
      existingDraftDefinition.targetCategory === '',
    'The template-field writer preserves an existing opaque templateFieldId verbatim',
  );

  const sameCategoryReferenceField = {
    id: 'Draft-Source-Reference',
    templateFieldId: 'Source-Reference',
    name: 'Local Email',
    value: 'Servers',
  };
  const sameCategoryValidationState = {
    categoryDraft: 'Servers',
    categoryRenameSource: '',
    categoryDraftFieldValueType() {
      return 'fieldReference';
    },
    categoryDraftHasMissingTargetCategory() {
      return false;
    },
    categoryDraftTargetFieldId() {
      return 'Target-Text';
    },
    categoryDraftIsCurrentCategory() {
      return true;
    },
    categoryDraftHasMissingTargetField() {
      return false;
    },
  };
  assert(
    categoryDraftFieldReferenceError.call(
      sameCategoryValidationState,
      sameCategoryReferenceField,
    ) === '',
    'Same-category references to a different stable text field are valid',
  );
  sameCategoryValidationState.categoryDraftTargetFieldId = () => 'Source-Reference';
  assert(
    categoryDraftFieldReferenceError.call(
      sameCategoryValidationState,
      sameCategoryReferenceField,
    ).includes('不能直接关联当前字段'),
    'Same-category direct self-reference is rejected by stable field ID',
  );

  const templatesByCategory = {
    A: [{
      id: 'Template-A-Owner',
      name: 'Owner',
      valueType: 'entryReference',
      targetCategory: 'Accounts',
    }],
    B: [{
      id: 'Template-B-Owner',
      name: 'Owner',
      valueType: 'entryReference',
      targetCategory: 'Accounts',
    }],
  };
  function makeCategorySwitchState() {
    let generatedId = 0;
    return {
      draftCategory: 'A',
      draftCategorySearch: '',
      categoryDraftCustomFields: [],
      categoryDraftFieldTypes: [],
      draftProtectedCustomFieldIds: [],
      draftCustomFieldCategories: [{ fieldId: 'Custom-A-Owner', category: 'A' }],
      draftCustomFields: [{
        id: 'Custom-A-Owner',
        templateFieldId: 'Template-A-Owner',
        name: 'Owner',
        value: 'Target-A-ID',
      }],
      sameCategoryName(left, right) {
        return left.trim().toLowerCase() === right.trim().toLowerCase();
      },
      hasTemplateFieldBinding(field) {
        return typeof field.templateFieldId === 'string' && field.templateFieldId.length > 0;
      },
      draftFieldBelongsToCategory(fieldId, category) {
        return draftFieldBelongsToCategory.call(this, fieldId, category);
      },
      templateFieldsForCategory(category) {
        return templatesByCategory[category] ?? [];
      },
      templateDefinitionForCustomField(field, category) {
        const definitions = this.templateFieldsForCategory(category);
        if (typeof field.templateFieldId === 'string' && field.templateFieldId.length > 0) {
          return definitions.find((candidate) => candidate.id === field.templateFieldId);
        }
        return definitions.find(
          (candidate) => candidate.name.trim().toLowerCase() === field.name.trim().toLowerCase(),
        );
      },
      isTextTemplateField(field) {
        return field.valueType === 'text';
      },
      isEntryReferenceTemplateField(field) {
        return field.valueType === 'entryReference';
      },
      isFieldReferenceTemplateField(field) {
        return field.valueType === 'fieldReference';
      },
      nextUiId() {
        generatedId += 1;
        return `generated-${generatedId}`;
      },
      protectDraftFieldsBeforeCategorySwitch() {
        return protectDraftFieldsBeforeCategorySwitch.call(this);
      },
      applyCategoryTemplateToDraft(category) {
        return applyCategoryTemplateToDraft.call(this, category);
      },
    };
  }
  const sameCategoryState = makeCategorySwitchState();
  selectDraftCategory.call(sameCategoryState, 'A');
  assert(
    sameCategoryState.draftCustomFields.length === 1 &&
      sameCategoryState.draftCustomFields[0].id === 'Custom-A-Owner' &&
      sameCategoryState.draftCustomFields[0].templateFieldId === 'Template-A-Owner' &&
      sameCategoryState.draftCustomFields[0].value === 'Target-A-ID',
    'A→A category selection reuses the existing bound field without duplication',
  );
  const roundTripState = makeCategorySwitchState();
  selectDraftCategory.call(roundTripState, 'B');
  selectDraftCategory.call(roundTripState, 'A');
  const roundTripAFields = roundTripState.draftCustomFields.filter(
    (field) => field.templateFieldId === 'Template-A-Owner',
  );
  const roundTripBFields = roundTripState.draftCustomFields.filter(
    (field) => field.templateFieldId === 'Template-B-Owner',
  );
  assert(
    roundTripState.draftCustomFields.length === 2 &&
      roundTripAFields.length === 1 &&
      roundTripAFields[0].id === 'Custom-A-Owner' &&
      roundTripAFields[0].value === 'Target-A-ID' &&
      roundTripBFields.length === 1,
    'A→B→A category selection reuses each stable binding instead of creating duplicates',
  );

  const collidingTemplateId = 'template_owner';
  const collidingTemplatesByCategory = {
    A: [{
      id: collidingTemplateId,
      name: 'Owner',
      valueType: 'entryReference',
      targetCategory: 'Accounts-A',
    }],
    B: [{
      id: collidingTemplateId,
      name: 'Owner',
      valueType: 'entryReference',
      targetCategory: 'Accounts-B',
    }],
  };
  const collisionState = makeCategorySwitchState();
  collisionState.draftCustomFields = [{
    id: 'Custom-A-Collision',
    templateFieldId: collidingTemplateId,
    name: 'Owner',
    value: 'Target-A-Collision-ID',
  }];
  collisionState.draftCustomFieldCategories = [{
    fieldId: 'Custom-A-Collision',
    category: 'A',
  }];
  collisionState.templateFieldsForCategory = function templateFieldsForCategory(category) {
    return collidingTemplatesByCategory[category] ?? [];
  };
  selectDraftCategory.call(collisionState, 'B');
  const collisionAAfterB = collisionState.draftCustomFields.find(
    (field) => field.id === 'Custom-A-Collision',
  );
  const collisionBFields = collisionState.draftCustomFields.filter(
    (field) => collisionState.draftFieldBelongsToCategory(field.id, 'B'),
  );
  assert(
    collisionState.draftCustomFields.length === 2 &&
      collisionAAfterB?.value === 'Target-A-Collision-ID' &&
      collisionState.draftProtectedCustomFieldIds.includes('Custom-A-Collision') &&
      collisionBFields.length === 1 &&
      collisionBFields[0].id !== 'Custom-A-Collision' &&
      collisionBFields[0].templateFieldId === collidingTemplateId &&
      collisionBFields[0].value === '',
    'A→B with a colliding legacy template ID creates an independent B field without consuming A',
  );
  const collisionBId = collisionBFields[0]?.id;
  selectDraftCategory.call(collisionState, 'A');
  const collisionAFields = collisionState.draftCustomFields.filter(
    (field) => collisionState.draftFieldBelongsToCategory(field.id, 'A'),
  );
  const collisionBAfterRoundTrip = collisionState.draftCustomFields.find(
    (field) => field.id === collisionBId,
  );
  assert(
    collisionState.draftCustomFields.length === 2 &&
      collisionAFields.length === 1 &&
      collisionAFields[0].id === 'Custom-A-Collision' &&
      collisionAFields[0].value === 'Target-A-Collision-ID' &&
      collisionBAfterRoundTrip?.value === '',
    'A→B→A with a colliding legacy template ID restores the original A field without duplication',
  );

  const source = makeEntry('Source-ID', 'Production Server', 'Servers');
  const liveAccount = makeEntry('Target-Live-ID', 'Primary Account', ' Accounts ');
  const deletedAccount = makeEntry('Target-Deleted-ID', 'Deleted Account', 'Accounts', true);
  const otherCategory = makeEntry('Target-Other-ID', 'Archive Account', 'Archive');
  const entries = [source, liveAccount, deletedAccount, otherCategory];
  const candidates = runtime.entryReferenceCandidates(entries, 'accounts', 'primary');
  assert(
    JSON.stringify(candidates) === JSON.stringify([{
      id: 'Target-Live-ID', label: 'Primary Account', category: 'Accounts',
    }]),
    'Reference candidates include only live entries matching the target category and search query',
  );
  assert(
    Object.keys(candidates[0]).sort().join(',') === 'category,id,label' &&
      candidates[0].payload === undefined && candidates[0].password === undefined,
    'Reference candidate projection exposes only id, label, and category',
  );
  assert(
    runtime.entryReferenceCandidates([liveAccount, otherCategory], '', '').length === 2,
    'An empty target category means unrestricted selection rather than uncategorized only',
  );

  const template = {
    category: 'Servers',
    fields: [
      {
        id: 'Template-Owner',
        name: 'Owner',
        valueType: 'entryReference',
        targetCategory: 'Accounts',
      },
      {
        id: 'Template-Future',
        name: 'Future',
        valueType: 'futureRelationV3',
        targetCategory: 'Future Targets',
      },
    ],
  };
  const referenceField = {
    id: 'Field-Owner',
    templateFieldId: 'Template-Owner',
    name: 'Owner',
    value: liveAccount.id,
  };
  const forbiddenValues = [
    liveAccount.id,
    liveAccount.payload.password,
    liveAccount.payload.token,
    liveAccount.payload.secretKey,
    liveAccount.payload.notes,
  ];
  const resolvedSearchValues = runtime.safeCustomFieldSearchValues(referenceField, template, entries);
  assert(
    resolvedSearchValues.includes('Owner') &&
      resolvedSearchValues.includes('Primary Account') &&
      resolvedSearchValues.includes('Accounts') &&
      excludesSentinels(resolvedSearchValues, forbiddenValues),
    'Resolved reference search uses only the field name and safe target projection',
  );
  [
    { label: 'missing', value: 'Missing-Target-ID' },
    { label: 'deleted', value: deletedAccount.id },
    { label: 'category-mismatch', value: otherCategory.id },
  ].forEach((testCase) => {
    const values = runtime.safeCustomFieldSearchValues(
      { ...referenceField, value: testCase.value }, template, entries,
    );
    assert(
      values.includes('Owner') && excludesSentinels(values, [testCase.value, ...forbiddenValues]),
      `${testCase.label} reference search retains the field name without indexing raw IDs`,
    );
  });
  const unknownField = {
    id: 'Field-Future',
    templateFieldId: 'Template-Future',
    name: 'Future',
    value: 'RAW-UNKNOWN-ID password-unknown token-unknown secret-unknown notes-unknown',
  };
  const unknownSentinels = [
    'RAW-UNKNOWN-ID', 'password-unknown', 'token-unknown', 'secret-unknown', 'notes-unknown',
  ];
  const unknownSearchValues = runtime.safeCustomFieldSearchValues(unknownField, template, entries);
  assert(
    unknownSearchValues.includes('Future') && excludesSentinels(unknownSearchValues, unknownSentinels),
    'Unknown field types remain searchable by name without indexing their raw value',
  );
  const orphanField = {
    id: 'Field-Orphan',
    templateFieldId: 'Missing-Template-ID',
    name: 'Orphan',
    value: 'RAW-ORPHAN-ID password-orphan token-orphan secret-orphan notes-orphan',
  };
  const orphanSentinels = [
    'RAW-ORPHAN-ID', 'password-orphan', 'token-orphan', 'secret-orphan', 'notes-orphan',
  ];
  const orphanSearchValues = runtime.safeCustomFieldSearchValues(orphanField, template, entries);
  assert(
    orphanSearchValues.includes('Orphan') && excludesSentinels(orphanSearchValues, orphanSentinels),
    'Orphan template bindings remain searchable by name without indexing their raw value',
  );
  const legacyField = { id: 'Legacy-Field', name: 'Legacy', value: 'legacy-visible-value' };
  const legacySearchValues = runtime.safeCustomFieldSearchValues(legacyField, template, []);
  assert(
    legacySearchValues.includes('Legacy') && legacySearchValues.includes('legacy-visible-value'),
    'Truly unbound legacy text fields retain their existing searchable value behavior',
  );
  assert(
    runtime.resolveEntryReference(
      { ...referenceField, value: deletedAccount.id }, template, entries,
    ).status === runtime.EntryReferenceStatus.DELETED,
    'The shared resolver retains the dedicated deleted-target state',
  );

  const selectionInitial = [
    clone(referenceField),
    {
      id: 'Field-Backup',
      templateFieldId: 'Template-Backup',
      name: 'Backup',
      value: 'Backup-Target-ID',
    },
    clone(unknownField),
  ];
  const selectionState = {
    draftReferenceFieldId: referenceField.id,
    draftCustomFields: clone(selectionInitial),
    restoreCount: 0,
    activeDraftReferenceField() {
      return this.draftCustomFields.find((field) => field.id === this.draftReferenceFieldId) ?? null;
    },
    updateDraftCustomFieldValue(id, value) {
      return updateDraftCustomFieldValue.call(this, id, value);
    },
    restoreEntryEditorOverlay() {
      this.restoreCount += 1;
    },
  };
  selectActiveDraftReference.call(selectionState, 'Replacement-Target-ID');
  assert(
    selectionState.draftCustomFields[0].id === referenceField.id &&
      selectionState.draftCustomFields[0].templateFieldId === referenceField.templateFieldId &&
      selectionState.draftCustomFields[0].name === referenceField.name &&
      selectionState.draftCustomFields[0].value === 'Replacement-Target-ID' &&
      JSON.stringify(selectionState.draftCustomFields.slice(1)) ===
        JSON.stringify(selectionInitial.slice(1)) &&
      selectionState.restoreCount === 1,
    'Selecting a reference changes only the target field value and restores the editor once',
  );
  const fieldsBeforeClear = clone(selectionState.draftCustomFields);
  clearActiveDraftReference.call(selectionState);
  assert(
    selectionState.draftCustomFields[0].id === referenceField.id &&
      selectionState.draftCustomFields[0].templateFieldId === referenceField.templateFieldId &&
      selectionState.draftCustomFields[0].name === referenceField.name &&
      selectionState.draftCustomFields[0].value === '' &&
      JSON.stringify(selectionState.draftCustomFields.slice(1)) ===
        JSON.stringify(fieldsBeforeClear.slice(1)) &&
      selectionState.restoreCount === 2,
    'Clearing a reference changes only the target field value and restores the editor once',
  );

  const legacyEntryReferenceState = {
    draftProtectedCustomFieldIds: [],
    templateDefinitionForCustomField(field) {
      return field.id === referenceField.id ? template.fields[0] : futureTemplate;
    },
    isEntryReferenceTemplateField(definition) {
      return definition.valueType === 'entryReference';
    },
    isFieldReferenceTemplateField(definition) {
      return definition.valueType === 'fieldReference';
    },
    hasTemplateFieldBinding(field) {
      return typeof field.templateFieldId === 'string' && field.templateFieldId.length > 0;
    },
    templateFieldValueType(definition) {
      return definition.valueType;
    },
  };
  assert(
    isEditableDraftReferenceField.call(legacyEntryReferenceState, referenceField),
    'Legacy entry-reference values remain selectable, replaceable, and clearable',
  );
  assert(
    protectedCustomFieldIdsForCategory.call(
      legacyEntryReferenceState,
      [referenceField, unknownField],
      'Servers',
    ).join(',') === unknownField.id,
    'Legacy entry references are not locked with unknown field types in entry editing',
  );

  const copiedUnknownFields = copyCustomFields.call({
    nextUiId() {
      throw new Error('A non-empty unknown field ID must not be regenerated');
    },
  }, [clone(unknownField)]);
  assert(
    JSON.stringify(copiedUnknownFields[0]) === JSON.stringify(unknownField),
    'Copying draft fields preserves unknown field identity, binding, name, and raw value exactly',
  );
  const normalizedUnknownFields = normalizedDraftCustomFields.call({
    draftCustomFields: [clone(unknownField)],
    isEditableDraftCustomField() {
      return false;
    },
    nextUiId() {
      throw new Error('A non-empty unknown field ID must not be regenerated');
    },
  });
  assert(
    JSON.stringify(normalizedUnknownFields[0]) === JSON.stringify(unknownField),
    'Saving draft fields preserves unknown field identity, binding, name, and raw value exactly',
  );

  const unsupportedState = {
    entryCategory() {
      return 'Servers';
    },
    categoryTemplate() {
      return template;
    },
    templateDefinitionForCustomField(field) {
      return field.id === unknownField.id ? template.fields[1] : undefined;
    },
    templateFieldValueType(definition) {
      return definition.valueType;
    },
  };
  assert(
    isUnsupportedCustomField.call(unsupportedState, source, unknownField),
    'A field with an unknown template value type is treated as unsupported',
  );
  assert(
    isUnsupportedCustomField.call(unsupportedState, source, orphanField),
    'A non-empty unmatched template binding is treated as an unsupported orphan',
  );
  assert(
    !isUnsupportedCustomField.call(unsupportedState, source, legacyField),
    'A truly unbound legacy field remains an editable text field',
  );

  const referenceRawId = 'RAW-REFERENCE-ID';
  const detailForbiddenSentinels = [
    referenceRawId, 'password-detail', 'token-detail', 'secret-detail', 'notes-detail',
  ];
  const detailCases = [
    {
      label: 'empty',
      expected: '未选择关联条目',
      resolution: { status: runtime.EntryReferenceStatus.EMPTY },
    },
    {
      label: 'resolved',
      expected: 'Primary Account',
      resolution: {
        status: runtime.EntryReferenceStatus.RESOLVED,
        target: { id: referenceRawId, label: 'Primary Account', category: 'Accounts' },
      },
    },
    {
      label: 'missing',
      expected: '关联条目不存在',
      resolution: { status: runtime.EntryReferenceStatus.MISSING },
    },
    {
      label: 'deleted',
      expected: '已删除',
      resolution: {
        status: runtime.EntryReferenceStatus.DELETED,
        target: { id: referenceRawId, label: 'Deleted Account', category: 'Accounts' },
      },
    },
    {
      label: 'category-mismatch',
      expected: '要求: Accounts',
      resolution: {
        status: runtime.EntryReferenceStatus.CATEGORY_MISMATCH,
        target: { id: referenceRawId, label: 'Archive Account', category: 'Archive' },
      },
    },
  ];
  const detailState = {
    entryReferenceDetailResolution(_entry, field) {
      return field.resolution;
    },
    templateDefinitionForCustomField() {
      return template.fields[0];
    },
    entryCategory() {
      return 'Servers';
    },
  };
  detailCases.forEach((testCase) => {
    const text = entryReferenceDetailText.call(detailState, source, {
      ...referenceField,
      value: referenceRawId,
      resolution: testCase.resolution,
    });
    assert(
      text.includes(testCase.expected) && excludesSentinels(text, detailForbiddenSentinels),
      `${testCase.label} reference detail uses safe status text without raw IDs or secrets`,
    );
  });

  const fieldReferenceRawId = 'RAW-FIELD-REFERENCE-ID';
  const resolvedFieldValue = 'resolved-value-must-not-enter-status-or-search';
  const fieldDetailForbiddenSentinels = [fieldReferenceRawId, resolvedFieldValue];
  const fieldDetailCases = [
    {
      label: 'empty',
      expected: '未选择目标条目',
      resolution: { status: runtime.FieldValueReferenceStatus.EMPTY },
    },
    {
      label: 'invalid-configuration',
      expected: '配置无效',
      resolution: { status: runtime.FieldValueReferenceStatus.INVALID_CONFIGURATION },
    },
    {
      label: 'missing',
      expected: '目标条目不存在',
      resolution: { status: runtime.FieldValueReferenceStatus.MISSING },
    },
    {
      label: 'deleted',
      expected: '目标条目已删除',
      resolution: {
        status: runtime.FieldValueReferenceStatus.DELETED,
        target: {
          id: fieldReferenceRawId,
          label: 'Deleted Account',
          category: 'Accounts',
          fieldId: 'Target-Email',
          fieldName: '',
          value: '',
        },
      },
    },
    {
      label: 'category-mismatch',
      expected: '当前位于 Archive',
      resolution: {
        status: runtime.FieldValueReferenceStatus.CATEGORY_MISMATCH,
        target: {
          id: fieldReferenceRawId,
          label: 'Archive Account',
          category: 'Archive',
          fieldId: 'Target-Email',
          fieldName: '',
          value: '',
        },
      },
    },
    {
      label: 'target-field-missing',
      expected: '目标字段已删除',
      resolution: {
        status: runtime.FieldValueReferenceStatus.TARGET_FIELD_MISSING,
        target: {
          id: fieldReferenceRawId,
          label: 'Primary Account',
          category: 'Accounts',
          fieldId: 'Target-Email',
          fieldName: '',
          value: '',
        },
      },
    },
    {
      label: 'target-field-unsupported',
      expected: '目标字段不再是文本类型',
      resolution: {
        status: runtime.FieldValueReferenceStatus.TARGET_FIELD_UNSUPPORTED,
        target: {
          id: fieldReferenceRawId,
          label: 'Primary Account',
          category: 'Accounts',
          fieldId: 'Target-Email',
          fieldName: 'Email',
          value: '',
        },
      },
    },
    {
      label: 'target-field-empty',
      expected: '目标字段值为空',
      resolution: {
        status: runtime.FieldValueReferenceStatus.TARGET_FIELD_EMPTY,
        target: {
          id: fieldReferenceRawId,
          label: 'Primary Account',
          category: 'Accounts',
          fieldId: 'Target-Email',
          fieldName: 'Email',
          value: '',
        },
      },
    },
    {
      label: 'resolved',
      expected: '已解析',
      resolution: {
        status: runtime.FieldValueReferenceStatus.RESOLVED,
        target: {
          id: fieldReferenceRawId,
          label: 'Primary Account',
          category: 'Accounts',
          fieldId: 'Target-Email',
          fieldName: 'Email',
          value: resolvedFieldValue,
        },
      },
    },
  ];
  const fieldDetailState = {
    fieldReferenceDetailResolution(_entry, field) {
      return field.resolution;
    },
    fieldReferenceConfiguredPath() {
      return 'Account Email → Accounts / Email';
    },
  };
  fieldDetailCases.forEach((testCase) => {
    const text = fieldReferenceDetailText.call(fieldDetailState, source, {
      id: 'Field-Account-Email',
      templateFieldId: stableFieldReference.id,
      name: stableFieldReference.name,
      value: fieldReferenceRawId,
      resolution: testCase.resolution,
    });
    assert(
      text.includes(testCase.expected) &&
        excludesSentinels(text, fieldDetailForbiddenSentinels),
      `${testCase.label} field-reference detail uses safe nine-state text`,
    );
  });
  const configurationRepairState = {
    fieldReferenceDetailResolution(_entry, field) {
      return field.resolution;
    },
    fieldReferenceConfigurationNeedsRepair(entry, field) {
      return fieldReferenceConfigurationNeedsRepair.call(this, entry, field);
    },
  };
  fieldDetailCases.forEach((testCase) => {
    const testField = { resolution: testCase.resolution };
    const needsConfigurationRepair = fieldReferenceConfigurationNeedsRepair.call(
      configurationRepairState,
      source,
      testField,
    );
    const canSelectEntry = fieldReferenceCanSelectEntry.call(
      configurationRepairState,
      source,
      testField,
    );
    const configurationStatus = [
      'invalid-configuration',
      'target-field-missing',
      'target-field-unsupported',
    ].includes(testCase.label);
    assert(
      needsConfigurationRepair === configurationStatus &&
        canSelectEntry === !configurationStatus,
      `${testCase.label} offers the repair action that can actually fix its state`,
    );
  });

  const summaryState = {
    ...unsupportedState,
    isEntryReferenceCustomField(_entry, field) {
      return field.kind === 'reference';
    },
    isFieldReferenceCustomField(_entry, field) {
      return field.kind === 'fieldReference';
    },
    entryReferenceDetailResolution(_entry, field) {
      return field.resolution;
    },
    fieldReferenceDetailResolution(_entry, field) {
      return field.resolution;
    },
    isUnsupportedCustomField(entry, field) {
      return isUnsupportedCustomField.call(this, entry, field);
    },
  };
  detailCases.forEach((testCase) => {
    const summary = entrySummaryField.call(summaryState, source, {
      ...referenceField,
      kind: 'reference',
      value: referenceRawId,
      resolution: testCase.resolution,
    });
    assert(
      excludesSentinels(summary, detailForbiddenSentinels) &&
        (testCase.label === 'resolved'
          ? summary.includes('Primary Account')
          : summary.includes(testCase.label === 'empty' ? '未关联' : '关联失效')),
      `${testCase.label} reference summary uses safe projected or status text`,
    );
  });
  fieldDetailCases.forEach((testCase) => {
    const summary = entrySummaryField.call(summaryState, source, {
      id: 'Field-Account-Email',
      templateFieldId: stableFieldReference.id,
      name: stableFieldReference.name,
      kind: 'fieldReference',
      value: fieldReferenceRawId,
      resolution: testCase.resolution,
    });
    assert(
      excludesSentinels(summary, fieldDetailForbiddenSentinels) &&
        (testCase.label === 'resolved'
          ? summary.includes('Primary Account / Email')
          : summary.includes(testCase.label === 'empty' ? '未关联' : '关联失效')),
      `${testCase.label} field-reference summary excludes target values and raw IDs`,
    );
  });
  const unknownSummary = entrySummaryField.call(summaryState, source, unknownField);
  assert(
    unknownSummary.includes('不支持的字段') && excludesSentinels(unknownSummary, unknownSentinels),
    'Unknown field summaries hide the raw value behind an unsupported-field status',
  );
  const orphanSummary = entrySummaryField.call(summaryState, source, orphanField);
  assert(
    orphanSummary.includes('不支持的字段') && excludesSentinels(orphanSummary, orphanSentinels),
    'Orphan field summaries hide the raw value behind an unsupported-field status',
  );

  const controllerResolution = methodSlice(
    controllerSource, '  resolveEntryReferenceField(', '  getSyncSettings()',
  );
  assert(
    controllerResolution.includes('this.snapshot.entries') &&
      controllerResolution.includes('resolveFieldValueReference(') &&
      !controllerResolution.includes('this.getEntries()'),
    'VaultController resolves five- and nine-state details from the complete snapshot',
  );

  const categoryFieldsEditor = extractMethod(
    indexSource, '  private CategoryDraftCustomFieldsEditor()',
  );
  const categoryTargetEditor = extractMethod(
    indexSource, '  private CategoryDraftTargetCategoryEditor(',
  );
  const categoryTargetFieldEditor = extractMethod(
    indexSource, '  private CategoryDraftTargetFieldEditor(',
  );
  assert(
    categoryFieldsEditor.includes("this.ChoiceChip('文本'") &&
      categoryFieldsEditor.includes("'关联字段',") &&
      categoryFieldsEditor.includes('当前版本无法编辑该字段，原配置已保留。') &&
      categoryTargetEditor.includes('this.categoryDraftTargetCategories()') &&
      categoryTargetEditor.includes('this.categoryDraftFieldReferenceError(field)') &&
      categoryTargetFieldEditor.includes('this.categoryDraftTargetFieldTemplates(field)') &&
      categoryTargetFieldEditor.includes('this.updateCategoryDraftTargetFieldId(') &&
      !categoryTargetEditor.includes("this.ChoiceChip('不限分类'"),
    'Category editing exposes dependent field-reference choices and visible validation',
  );
  const choiceChip = extractMethod(indexSource, '  private ChoiceChip(');
  assert(
    choiceChip.includes('.height(44)') &&
      choiceChip.includes('.margin({ right: 8, bottom: 8 })') &&
      choiceChip.includes("selected ? '已选择' : '未选择'"),
    'Choice chips keep 44vp touch targets, separation, and explicit selected-state accessibility',
  );

  const detailContent = extractMethod(indexSource, '  private EntryDetailContent(');
  const referenceDetail = extractMethod(indexSource, '  private EntryReferenceDetailRow(');
  const fieldReferenceDetail = extractMethod(indexSource, '  private FieldReferenceDetailRow(');
  const unsupportedDetail = extractMethod(indexSource, '  private UnsupportedDetailFieldRow(');
  const nonCopyableDetailMethods = [referenceDetail, fieldReferenceDetail, unsupportedDetail];
  assert(
    detailContent.includes('this.FieldReferenceDetailRow(entry, field);') &&
    detailContent.includes('this.EntryReferenceDetailRow(entry, field);') &&
      detailContent.includes('this.fieldReferenceResolvedValue(entry, field)') &&
      detailContent.includes('this.DetailValueRow(') &&
      detailContent.includes('this.UnsupportedDetailFieldRow(field);') &&
      nonCopyableDetailMethods.every((method) =>
        !method.includes('this.DetailValueRow(') &&
        !method.includes('copyValueToClipboard') &&
        !method.includes('pasteboard') &&
        !method.includes('Text(field.value')
      ),
    'Resolved field values use the explicit detail row while status rows hide raw values',
  );

  const selectorPanel = extractMethod(indexSource, '  private EntryReferenceSelectOverlayPanel()');
  const selectorRow = extractMethod(indexSource, '  private EntryReferenceSelectRow(');
  const legacyFieldEditor = extractMethod(indexSource, '  private EntryReferenceFieldEditor(');
  const fieldEditor = extractMethod(indexSource, '  private FieldReferenceFieldEditor(');
  assert(
    selectorPanel.includes('this.FloatingPanelHeader(') &&
      selectorPanel.includes('this.SecondaryTextButton(') &&
      selectorPanel.includes('.backgroundColor(UI_SURFACE_ALT)') &&
      selectorPanel.includes('.border({ width: 1, color: UI_STROKE })') &&
      selectorPanel.includes('.borderRadius(12)') &&
      selectorRow.includes('.backgroundColor(selected ? UI_ACCENT : UI_SURFACE_ALT)') &&
      selectorRow.includes('.borderRadius(12)') &&
      legacyFieldEditor.includes('this.PrimaryTextButton(') &&
      legacyFieldEditor.includes('this.SecondaryTextButton(') &&
      fieldEditor.includes('this.PrimaryTextButton(') &&
      fieldEditor.includes('this.SecondaryTextButton(') &&
      fieldReferenceDetail.includes('this.fieldReferenceConfigurationNeedsRepair(') &&
      fieldReferenceDetail.includes("this.PrimaryTextButton('编辑字段配置'") &&
      fieldReferenceDetail.includes('this.fieldReferenceCanSelectEntry(') &&
      fieldReferenceDetail.includes('this.fieldReferenceRepairLabel(') &&
      fieldReferenceDetail.includes('this.prepareClearEntryReference(') &&
      referenceDetail.includes('.backgroundColor(UI_SURFACE_ALT)') &&
      fieldReferenceDetail.includes('.borderRadius(12)'),
    'Legacy and field-reference UI reuse existing panels, buttons, colors, borders, and radii',
  );
  assert(
    selectorPanel.includes('.fontColor(UI_TEXT)') &&
      selectorPanel.includes('.placeholderColor(UI_MUTED)') &&
      selectorPanel.includes('.caretColor(UI_ACCENT)'),
    'Reference selector search input follows the existing readable theme contract',
  );

  if (failures > 0) {
    console.error(`[FAIL] Harmony field-reference UI tests failed: ${failures}`);
    process.exit(1);
  }
  console.log('[OK] Harmony field-reference UI tests passed');
}

main();
