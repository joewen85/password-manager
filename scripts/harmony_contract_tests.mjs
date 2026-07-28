#!/usr/bin/env node
import fs from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import path from 'node:path';
import process from 'node:process';
import vm from 'node:vm';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');

const files = {
  appScope: 'apps/harmony_app/AppScope/app.json5',
  buildProfile: 'apps/harmony_app/build-profile.json5',
  module: 'apps/harmony_app/entry/src/main/module.json5',
  model: 'apps/harmony_app/entry/src/main/ets/src/model/VaultTypes.ets',
  crypto: 'apps/harmony_app/entry/src/main/ets/src/security/VaultCryptoService.ets',
  totp: 'apps/harmony_app/entry/src/main/ets/src/security/TotpService.ets',
  controller: 'apps/harmony_app/entry/src/main/ets/src/service/VaultController.ets',
  syncTypes: 'apps/harmony_app/entry/src/main/ets/src/sync/SyncTypes.ets',
  indexPage: 'apps/harmony_app/entry/src/main/ets/pages/Index.ets',
  baseColors: 'apps/harmony_app/entry/src/main/resources/base/element/color.json',
  darkColors: 'apps/harmony_app/entry/src/main/resources/dark/element/color.json',
};

const expectedBundleName = 'life.devops.passwordmanager';
const expectedVendor = 'DevOps Life';
const expectedPermissions = [
  'ohos.permission.ACCESS_BIOMETRIC',
  'ohos.permission.INTERNET',
];
const platformIdentifierPattern = /^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$/;

let failures = 0;

function rel(file) {
  return files[file] ?? file;
}

function read(file) {
  return fs.readFileSync(path.join(root, file), 'utf8');
}

function parseJson5(file) {
  const raw = read(file)
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|[^:])\/\/.*$/gm, '$1')
    .replace(/,\s*([}\]])/g, '$1');
  return JSON.parse(raw);
}

function ok(message) {
  console.log(`[OK] ${message}`);
}

function fail(message) {
  failures += 1;
  console.error(`[FAIL] ${message}`);
}

function assert(condition, message) {
  if (condition) {
    ok(message);
  } else {
    fail(message);
  }
}

function assertIncludes(text, needle, message) {
  assert(text.includes(needle), `${message} (${needle})`);
}

function assertBefore(text, beforeNeedle, afterNeedle, message) {
  const beforeIndex = text.indexOf(beforeNeedle);
  const afterIndex = text.indexOf(afterNeedle);
  assert(beforeIndex >= 0 && afterIndex >= 0 && beforeIndex < afterIndex, message);
}

function assertMatches(text, pattern, message) {
  assert(pattern.test(text), `${message} (${pattern})`);
}

function assertPlatformIdentifier(value, label) {
  assert(typeof value === 'string' && value.length > 0, `${label} is present`);
  assert(!value.includes('-'), `${label} does not contain '-'`);
  assert(platformIdentifierPattern.test(value), `${label} is a dot-separated platform identifier`);
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

function loadHarmonyFieldReferenceRuntime() {
  const controller = read(files.controller);
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
    'mergeImportedCategoryTemplateDefinitions',
    'cloneCategoryTemplate',
    'cloneFieldTemplate',
    'categoryTemplatesForExport',
    'normalizeFieldValueType',
    'readPreservedString',
    'normalizeCustomFields',
    'nextId',
  ];
  const source = `${functionNames.map((name) => extractFunction(controller, name)).join('\n')}
    ;({ ${functionNames.join(', ')} });`;
  const executable = stripTypeScriptTypes(source, { mode: 'transform' });
  return vm.runInNewContext(executable, {});
}

function checkReleaseMetadata() {
  const app = parseJson5(files.appScope).app;
  assert(app.bundleName === expectedBundleName, `Harmony bundleName is ${expectedBundleName}`);
  assertPlatformIdentifier(app.bundleName, 'Harmony bundleName');
  assert(app.vendor === expectedVendor, `Harmony vendor is ${expectedVendor}`);
  assert(Number.isInteger(app.versionCode) && app.versionCode > 0, 'Harmony versionCode is a positive integer');
  assert(/^\d+\.\d+\.\d+([-.+][A-Za-z0-9.-]+)?$/.test(app.versionName), 'Harmony versionName is semver-like');

  const buildProfile = parseJson5(files.buildProfile);
  const product = buildProfile.app?.products?.find((item) => item.name === 'default');
  assert(product?.runtimeOS === 'HarmonyOS', 'Harmony product runtimeOS is HarmonyOS');
  assert(typeof product?.compatibleSdkVersion === 'string' && product.compatibleSdkVersion.length > 0, 'Harmony compatibleSdkVersion is configured');
  assert(typeof product?.targetSdkVersion === 'string' && product.targetSdkVersion.length > 0, 'Harmony targetSdkVersion is configured');

  const module = parseJson5(files.module).module;
  const permissions = (module.requestPermissions ?? [])
    .map((permission) => permission.name)
    .sort();
  assert(JSON.stringify(permissions) === JSON.stringify(expectedPermissions), 'Harmony permissions stay minimal and expected');
  assert((module.deviceTypes ?? []).includes('phone') && (module.deviceTypes ?? []).includes('tablet'), 'Harmony supports phone and tablet targets');
}

function checkCryptoContract() {
  const crypto = read(files.crypto);
  assertMatches(crypto, /DEFAULT_ITERATIONS:\s*number\s*=\s*600000;/, 'PBKDF2 default iterations match cross-platform contract');
  assertMatches(crypto, /const\s+DERIVED_KEY_BYTES:\s*number\s*=\s*32;/, 'PBKDF2 derived key size is 32 bytes');
  assertMatches(crypto, /generateSaltBase64\(bytes:\s*number\s*=\s*16\)/, 'PBKDF2 salt default is 16 bytes');
  assertIncludes(crypto, "cryptoFramework.createKdf('PBKDF2|SHA256')", 'PBKDF2 SHA256 KDF is used');
  assertIncludes(crypto, "algName: 'PBKDF2'", 'PBKDF2 spec declares PBKDF2 algorithm');
  assertIncludes(crypto, 'keySize: DERIVED_KEY_BYTES', 'PBKDF2 spec uses the fixed derived key size');
  assertMatches(crypto, /const\s+AES_GCM_NONCE_BYTES:\s*number\s*=\s*12;/, 'AES-GCM nonce size is 12 bytes');
  assertMatches(crypto, /const\s+AES_GCM_TAG_BYTES:\s*number\s*=\s*16;/, 'AES-GCM tag size is 16 bytes');
  assertIncludes(crypto, 'cryptoFramework.createCipher(`${resolveAesAlgName(keyBytes)}|GCM|PKCS7`)', 'AES-GCM cipher path is used');
  assertIncludes(crypto, "return 'AES256';", '32-byte key resolves to AES256');
  assertMatches(crypto, /version:\s*1,\s*\n\s*};/, 'Encrypted payload version remains 1');
}

function checkTemplateIdContract() {
  const controller = read(files.controller);
  assertIncludes(controller, 'return `template_${output}`;', 'Harmony field template IDs use normalized underscores');
  assertIncludes(controller, "return 'template_empty';", 'Harmony has a defensive empty-name template ID');
  assertIncludes(controller, 'return `template_u_${utf8Hex(trimmed)}`;', 'Harmony uses deterministic UTF-8 hex for empty slugs');
}

function checkFieldReferenceBehavior() {
  const runtime = loadHarmonyFieldReferenceRuntime();
  assert(runtime.canonicalIdString('Entry-MixedCase') === 'Entry-MixedCase', 'Harmony preserves opaque entry IDs');
  assert(
    runtime.canonicalIdString('AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA') ===
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'Harmony canonicalizes UUID IDs without changing opaque IDs',
  );
  const legacyTemplates = runtime.normalizeFieldTemplates([
    { id: 'Template-MixedCase', name: 'Owner' },
  ]);
  assert(
    JSON.stringify(legacyTemplates) === JSON.stringify([
      {
        id: 'Template-MixedCase',
        name: 'Owner',
        valueType: 'text',
        targetCategory: '',
      },
    ]),
    'Harmony legacy template fields receive text defaults without changing opaque IDs',
  );

  const emptySlugFixture = JSON.parse(read('fixtures/vault-contract/v1/snapshot-legacy-empty-slug.json'));
  const emptySlugTemplates = runtime.normalizeFieldTemplates(emptySlugFixture.categoryTemplates[0].fields);
  assert(
    JSON.stringify(emptySlugTemplates.map((field) => field.id)) ===
      JSON.stringify(['template_u_f09f9880', 'template_u_212121']),
    'Harmony synthesizes deterministic empty-slug IDs from the shared fixture',
  );

  const futureTemplates = runtime.normalizeFieldTemplates([
    {
      id: 'Future-Template-ID',
      name: 'Owner',
      valueType: 'futureRelationV3',
      targetCategory: 'Accounts',
    },
  ]);
  assert(futureTemplates[0].valueType === 'futureRelationV3', 'Harmony preserves unknown non-empty field value types');
  assert(futureTemplates[0].targetCategory === 'Accounts', 'Harmony preserves reference target categories');

  const editedTemplates = runtime.mergeEditableTemplateFields(
    [
      { id: 'Opaque-Text-ID', name: 'Legacy Name', valueType: 'text', targetCategory: '' },
      futureTemplates[0],
    ],
    [{ id: 'Generated-Replacement-ID', name: 'Renamed Text', valueType: 'text', targetCategory: '' }],
  );
  const renamedText = editedTemplates.find((field) => field.name === 'Renamed Text');
  const preservedFuture = editedTemplates.find((field) => field.name === 'Owner');
  assert(renamedText?.id === 'Opaque-Text-ID', 'Harmony category edits keep opaque template IDs when text fields are renamed');
  assert(preservedFuture?.id === 'Future-Template-ID', 'Harmony legacy category edits cannot remove unsupported template fields');
  assert(preservedFuture?.valueType === 'futureRelationV3', 'Harmony legacy category edits preserve unsupported field metadata');

  const customFields = runtime.normalizeCustomFields([
    {
      id: 'Custom-Field-ID',
      templateFieldId: 'Future-Template-ID',
      name: 'Owner',
      value: 'Target-Entry-ID',
    },
  ]);
  assert(customFields[0].id === 'Custom-Field-ID', 'Harmony preserves opaque custom field IDs');
  assert(customFields[0].templateFieldId === 'Future-Template-ID', 'Harmony preserves template field references');
  assert(customFields[0].value === 'Target-Entry-ID', 'Harmony preserves referenced entry IDs as field values');

  const sourceTemplates = [
    { category: 'Servers', fields: futureTemplates },
    {
      category: 'Accounts',
      fields: [{ id: 'Secret-Template', name: 'Password', valueType: 'text', targetCategory: '' }],
    },
  ];
  const selectedTemplates = runtime.categoryTemplatesForExport(sourceTemplates, ['Servers']);
  assert(selectedTemplates.length === 1 && selectedTemplates[0].category === 'Servers', 'Harmony scoped export includes only source category templates');
  assert(selectedTemplates[0].fields[0].valueType === 'futureRelationV3', 'Harmony scoped export retains unknown field semantics');

  const itemRecord = runtime.createScopedItemExportRecord(
    { id: 'Entry-MixedCase' },
    selectedTemplates,
    '2026-07-28T03:00:00Z',
  );
  assert(itemRecord.version === 2 && itemRecord.scope === 'item', 'Harmony writes version 2 item exports');
  assert(itemRecord.categoryTemplates.length === 1, 'Harmony item exports carry source category templates');

  const categoryRecord = runtime.createScopedCategoryExportRecord(
    'Servers',
    [{ id: 'Entry-MixedCase' }],
    selectedTemplates,
    '2026-07-28T04:00:00Z',
  );
  assert(categoryRecord.version === 2 && categoryRecord.count === 1, 'Harmony writes version 2 category exports');
  assert(categoryRecord.categoryTemplates.length === 1, 'Harmony category exports carry source category templates');

  const legacyImport = runtime.decodeScopedImportRecord(
    JSON.stringify({ scope: 'item', item: { id: 'Legacy-Entry-ID' } }),
    'item',
  );
  assert(legacyImport.version === 1, 'Harmony defaults version 1 scoped imports when version is missing');
  assert(legacyImport.categoryTemplates.length === 0, 'Harmony defaults missing scoped import templates to an empty list');

  const currentImport = runtime.decodeScopedImportRecord(
    JSON.stringify({
      version: 2,
      scope: 'item',
      item: { id: 'Current-Entry-ID' },
      categoryTemplates: sourceTemplates,
    }),
    'item',
  );
  assert(currentImport.version === 2, 'Harmony reads version 2 scoped imports');
  const importedServers = currentImport.categoryTemplates.find((template) => template.category === 'Servers');
  assert(importedServers?.fields[0].valueType === 'futureRelationV3', 'Harmony scoped import decoding preserves unknown field semantics');

  const mergedImports = runtime.mergeImportedCategoryTemplateDefinitions(
    [
      {
        category: 'Servers',
        fields: [{ id: 'Existing-Text', name: 'Text', valueType: 'text', targetCategory: '' }],
      },
    ],
    currentImport.categoryTemplates,
  );
  const mergedServers = mergedImports.find((template) => template.category === 'Servers');
  assert(mergedServers?.fields.length === 2, 'Harmony scoped import merges source fields into an existing category template');
  assert(
    mergedServers?.fields.some((field) => field.id === 'Future-Template-ID'),
    'Harmony scoped import preserves imported stable template IDs',
  );

  const fixtureDirectory = path.join(root, 'fixtures', 'vault-contract', 'v1');
  const referenceFixture = JSON.parse(
    fs.readFileSync(path.join(fixtureDirectory, 'snapshot-entry-reference.json'), 'utf8'),
  );
  const fixtureTemplates = runtime.normalizeFieldTemplates(
    referenceFixture.categoryTemplates.find((template) => template.category === 'Servers').fields,
  );
  const fixtureCustomFields = runtime.normalizeCustomFields(
    referenceFixture.entries.find((entry) => entry.label === 'Production Server').customFields,
  );
  assert(fixtureTemplates[0].valueType === 'entryReference', 'Harmony consumes the shared reference snapshot fixture');
  assert(fixtureCustomFields[0].templateFieldId === fixtureTemplates[0].id, 'Harmony shared fixture keeps template binding');

  for (const fixtureName of [
    'scoped-item-entry-reference.json',
    'scoped-category-entry-reference.json',
  ]) {
    const fixtureContents = fs.readFileSync(path.join(fixtureDirectory, fixtureName), 'utf8');
    const fixtureScope = fixtureName.includes('item') ? 'item' : 'category';
    const fixtureImport = runtime.decodeScopedImportRecord(fixtureContents, fixtureScope);
    assert(fixtureImport.version === 2, `Harmony reads shared ${fixtureScope} export version`);
    assert(fixtureImport.categoryTemplates[0].fields[0].valueType === 'entryReference', `Harmony preserves shared ${fixtureScope} export semantics`);
    assert(!fixtureImport.items.some((item) => item.id === 'harmony_target_01'), `Harmony shared ${fixtureScope} export excludes the target entry`);
  }
}

function checkTotpContract() {
  const totp = read(files.totp);
  assertMatches(totp, /periodSeconds:\s*30,/, 'TOTP period is 30 seconds');
  assertMatches(totp, /digits:\s*6,/, 'TOTP code length is 6 digits');
  assertMatches(totp, /skewWindows:\s*1,/, 'TOTP accepts one adjacent time window');
  assertIncludes(totp, 'const pattern = new RegExp(`^[0-9]{${this.config.digits}}$`);', 'TOTP validates numeric code shape');
  assertIncludes(totp, 'for (let offset = -this.config.skewWindows; offset <= this.config.skewWindows; offset++)', 'TOTP verifies adjacent-window codes');
  assertIncludes(totp, 'const digest = await hmacSha1(secretBytes, counterBytes);', 'TOTP uses SHA1 HMAC digest');
  assertIncludes(totp, 'const offset = digest[digest.length - 1] & 0x0f;', 'TOTP dynamic truncation offset is used');
  assertIncludes(totp, '((digest[offset] & 0x7f) << 24)', 'TOTP dynamic truncation clears the sign bit');
  assertIncludes(totp, "return code.toString().padStart(this.config.digits, '0');", 'TOTP pads generated numeric codes');
}

function checkPersistenceAndSyncSecrecy() {
  const controller = read(files.controller);
  assertIncludes(controller, 'this.snapshot = sanitizeRuntimePayload(this.snapshot);', 'Persistence sanitizes runtime payload before encryption');
  assertIncludes(controller, 'const encryptedVault = await this.crypto.encryptString(\n      JSON.stringify(this.snapshot),', 'Persistence encrypts JSON snapshot into encryptedVault');
  assertIncludes(controller, 'await this.store.writeEnvelope(envelope);', 'Persistence writes only the envelope through VaultStore');
  assertIncludes(controller, 'const uploadPayload = sanitizeRuntimePayload(this.snapshot);', 'Sync upload path sanitizes runtime payload');
  assertIncludes(controller, 'const normalizedPayload = sanitizeRuntimePayload(payload);', 'Sync payload builder sanitizes payload before encryption');
  assertIncludes(controller, 'const encryptedVault = await this.crypto.encryptString(\n      JSON.stringify(normalizedPayload),', 'Sync payload encrypts normalized payload');
  assertIncludes(controller, 'encryptedVault,', 'Sync envelope carries encryptedVault, not plaintext payload');
  assertIncludes(controller, 'const safeMessage = sanitizeLogMessage(message);', 'Sync status sanitizes log messages');
  assertMatches(controller, /safe\.replace\(\/\(password\|passwd\|pwd\)=\(\[\^&\\s\]\+\)\/gi,\s*'\$1=\*\*\*'\)/, 'Log redaction covers password/passwd/pwd query values');
  assertMatches(controller, /safe\.replace\(\/\(token\|secret\|authorization\)=\(\[\^&\\s\]\+\)\/gi,\s*'\$1=\*\*\*'\)/, 'Log redaction covers token/secret/authorization query values');
  assertMatches(controller, /safe\.replace\(\/\(Bearer\\s\+\)\[A-Za-z0-9\\\-._~\+\/\]\+=\*\/gi,\s*'\$1\*\*\*'\)/, 'Log redaction covers Bearer tokens');
}

function checkSyncSettingsContract() {
  const syncTypes = read(files.syncTypes);
  assertIncludes(syncTypes, 'return `${ts}_${rand}`;', 'Harmony generated device IDs use underscore separators');
}

function checkThemeResourcesContract() {
  const requiredColorNames = [
    'ui_background',
    'ui_surface',
    'ui_surface_alt',
    'ui_text',
    'ui_muted',
    'ui_stroke',
    'ui_accent',
    'ui_selected',
    'ui_danger',
    'ui_danger_surface',
  ];
  const baseNames = new Set((parseJson5(files.baseColors).color ?? []).map((item) => item.name));
  const darkNames = new Set((parseJson5(files.darkColors).color ?? []).map((item) => item.name));
  const page = read(files.indexPage);
  requiredColorNames.forEach((name) => {
    assert(baseNames.has(name), `Light theme defines ${name}`);
    assert(darkNames.has(name), `Dark theme defines ${name}`);
    assertIncludes(page, `$r('app.color.${name}')`, `Harmony page uses ${name} resource`);
  });
}

function checkThemedTextInputContract() {
  const page = read(files.indexPage);
  const inputBlocks = page.match(/TextInput\([\s\S]*?;/g) ?? [];
  assert(inputBlocks.length > 0, 'Harmony page contains TextInput controls');
  inputBlocks.forEach((block, index) => {
    assertIncludes(block, '.fontColor(UI_TEXT)', `TextInput ${index + 1} uses readable theme text color`);
    assertIncludes(block, '.placeholderColor(UI_MUTED)', `TextInput ${index + 1} uses readable theme placeholder color`);
    assertIncludes(block, '.caretColor(UI_ACCENT)', `TextInput ${index + 1} uses themed caret color`);
  });
}

function checkEntryEditorUiContract() {
  const page = read(files.indexPage);
  const editor = page.slice(
    page.indexOf('private EntryEditorFormContent()'),
    page.indexOf('private TagSection()'),
  );
  assert(!editor.includes("Text('条目类型'"), 'Harmony entry editor does not show legacy type selector');
  assert(!editor.includes('this.EntryTypeChip'), 'Harmony entry editor does not show legacy type chips');
  assert(!editor.includes('this.AccountsEditor'), 'Harmony entry editor does not show legacy account editor');
  assert(!editor.includes("placeholder: '用户名'"), 'Harmony entry editor does not show legacy username field');
  assert(!editor.includes("placeholder: '密码'"), 'Harmony entry editor does not show legacy password field');
  assert(!editor.includes("placeholder: 'Token'"), 'Harmony entry editor does not show legacy token field');
  assert(!editor.includes("placeholder: 'App ID'"), 'Harmony entry editor does not show legacy app id field');
  assert(!page.includes('private EntryTypeChip'), 'Harmony page does not define legacy entry type chips');
  assert(!page.includes('private AccountsEditor'), 'Harmony page does not define legacy account editor');
  assertMatches(
    page,
    /if\s*\(\s*!this\.categoryCreateReturnToEntry\s*\)\s*{\s*Text\('字段快捷键'\)/s,
    'Harmony category creation from entry editor hides preset shortcut chips',
  );
  const categoryDraftEditor = page.slice(
    page.indexOf('private CategoryDraftCustomFieldsEditor()'),
    page.indexOf('private CustomFieldsEditor()'),
  );
  assertBefore(
    categoryDraftEditor,
    'ForEach(this.categoryDraftCustomFields',
    "this.AddFieldButton('添加字段'",
    'Harmony category field add button appears after existing category fields',
  );
  const customFieldsEditor = page.slice(
    page.indexOf('private CustomFieldsEditor()'),
    page.indexOf('private AddFieldButton'),
  );
  assertBefore(
    customFieldsEditor,
    'ForEach(this.editableDraftCustomFields()',
    "this.AddFieldButton('添加字段'",
    'Harmony entry field add button appears after existing entry fields',
  );
}

function checkFieldReferenceEditorProtection() {
  const page = read(files.indexPage);
  const applyTemplate = page.slice(
    page.indexOf('private applyCategoryTemplateToDraft(category: string): void'),
    page.indexOf('private clearEntryDraft(): void'),
  );
  assertIncludes(
    applyTemplate,
    'this.templateFieldsForCategory(category).forEach((templateField: FieldTemplate)',
    'Harmony entry templates are applied from complete field definitions',
  );
  assertIncludes(
    applyTemplate,
    'if (!this.isTextTemplateField(templateField))',
    'Harmony legacy entry editor does not generate fields for reference or unknown template types',
  );
  assertIncludes(
    applyTemplate,
    'field.templateFieldId === templateField.id',
    'Harmony entry template application matches stable template field IDs first',
  );
  assert(
    applyTemplate.match(/!this\.draftProtectedCustomFieldIds\.includes\(field\.id\)/g)?.length === 2,
    'Harmony category switches cannot consume protected fields through ID or name fallback',
  );
  assertIncludes(
    applyTemplate,
    ': templateField.id,',
    'Harmony generated text fields record their template field ID',
  );
  assertIncludes(
    applyTemplate,
    'templateFieldId: field.templateFieldId,',
    'Harmony template application carries untouched custom-field bindings forward',
  );

  const updateFields = page.slice(
    page.indexOf('private updateDraftCustomFieldName(id: string, value: string): void'),
    page.indexOf('private removeDraftCustomField(id: string): void'),
  );
  assert(
    updateFields.match(/templateFieldId:\s*field\.templateFieldId/g)?.length === 2,
    'Harmony field name and value updates preserve templateFieldId',
  );

  const normalizeFields = page.slice(
    page.indexOf('private normalizedDraftCustomFields(): CustomField[]'),
    page.indexOf('private toggleExportPanel(entry: VaultEntry): void'),
  );
  assertIncludes(
    normalizeFields,
    'templateFieldId: field.templateFieldId,',
    'Harmony draft copy and normalization preserve templateFieldId',
  );
  assertIncludes(
    normalizeFields,
    'name: this.isEditableDraftCustomField(field) ? field.name.trim() : field.name,',
    'Harmony save keeps protected non-text field names unchanged',
  );
  assertIncludes(
    normalizeFields,
    'this.draftCustomFields.filter((field: CustomField)',
    'Harmony legacy editor filters a view without removing protected fields from the draft',
  );
  assertIncludes(
    normalizeFields,
    'return definition === undefined || this.isTextTemplateField(definition);',
    'Harmony hides known non-text fields and conservatively edits fields with missing definitions',
  );
  assertIncludes(
    normalizeFields,
    'if (this.draftProtectedCustomFieldIds.includes(field.id))',
    'Harmony keeps fields protected after switching to another category',
  );
  assertIncludes(
    page,
    'this.draftProtectedCustomFieldIds = this.protectedCustomFieldIdsForCategory(',
    'Harmony records protected field instances before applying another category template',
  );
  assertIncludes(
    page,
    'this.draftProtectedCustomFieldIds = [];',
    'Harmony clears protected field state with the entry draft',
  );

  const categoryDraft = page.slice(
    page.indexOf('private categoryTemplateDraftFields(category: string): CustomField[]'),
    page.indexOf('private isBaseCategoryField(name: string): boolean'),
  );
  assertIncludes(
    categoryDraft,
    'this.templateFieldsForCategory(category).forEach((templateField: FieldTemplate)',
    'Harmony category editor reads complete template definitions',
  );
  assertIncludes(
    categoryDraft,
    'if (!this.isTextTemplateField(templateField))',
    'Harmony legacy category editor only exposes text template fields',
  );

  const customFieldsEditor = page.slice(
    page.indexOf('private CustomFieldsEditor()'),
    page.indexOf('private AddFieldButton'),
  );
  assertIncludes(
    customFieldsEditor,
    'ForEach(this.editableDraftCustomFields()',
    'Harmony entry editor renders only legacy-editable text fields',
  );
  assert(!customFieldsEditor.includes('ForEach(this.draftCustomFields,'), 'Harmony protected fields are absent from the legacy editor list');
  assertIncludes(
    page,
    'const customFields = this.normalizedDraftCustomFields();',
    'Harmony entry save still submits the complete protected draft field set',
  );
}

function checkEntryDetailUiContract() {
  const page = read(files.indexPage);
  const detail = page.slice(
    page.indexOf('private EntryDetailContent(entry: VaultEntry)'),
    page.indexOf('private DetailValueRow'),
  );
  assert(!detail.includes('this.EntryPayloadDetailRows'), 'Harmony detail does not render legacy payload rows');
  assert(!page.includes('private EntryPayloadDetailRows'), 'Harmony page does not define legacy payload detail rows');
  assert(!page.includes('private payloadExportFieldOptions'), 'Harmony export selector does not define legacy payload field options');
  assert(!page.includes('payloadExportFieldOptions(entry)'), 'Harmony export selector does not append legacy payload fields');
  assertIncludes(page, 'const filledFields = entry.customFields', 'Harmony entry summary is based on custom fields');
  assertIncludes(page, "return templateFields.length > 0 ? `字段: ${templateFields.join('、')}` : '暂无字段数据';", 'Harmony entry summary falls back to category template fields');
}

function checkCategoryManagementContract() {
  const page = read(files.indexPage);
  const controller = read(files.controller);
  assertIncludes(page, 'private CategoryListRow(category: string)', 'Harmony category management uses row list items');
  assertIncludes(page, 'this.beginEditCategory(category);', 'Harmony category rows expose edit action');
  assertIncludes(page, 'this.categoryDraftCustomFields = this.categoryTemplateDraftFields(clean);', 'Harmony category edit loads existing template fields');
  assertIncludes(page, 'await this.controller().saveCategoryTemplate(target, this.categoryDraftCustomFieldNames());', 'Harmony category save persists edited fields');
  assertIncludes(controller, 'async saveCategoryTemplate(category: string, customFieldNames: string[] = []): Promise<void>', 'Harmony controller can save an existing category template');
}

function checkCategoryFocusContract() {
  const page = read(files.indexPage);
  assertIncludes(page, 'this.FilterPill(category, this.isFocusedCategory(category)', 'Harmony category filter highlights the focused category');
  assertIncludes(page, 'this.focusCategory(clean);', 'Harmony category filter selection focuses the requested category');
  assertIncludes(page, 'this.draftCategory = this.currentFocusedCategory();', 'Harmony new entries inherit the focused category');
  assertIncludes(page, 'private currentFocusedCategory(): string', 'Harmony page resolves the focused category before creating entries');
  assertIncludes(page, 'private focusCategory(category: string): void', 'Harmony page has a single category focus state writer');
  assertIncludes(page, 'this.focusCategory(category);', 'Harmony category management rows can focus a category');
}

function checkKeyboardAvoidanceContract() {
  const page = read(files.indexPage);
  assertIncludes(page, "import { window } from '@kit.ArkUI';", 'Harmony page can access window keyboard events');
  assertIncludes(page, "currentWindow.on('keyboardHeightChange', this.keyboardHeightChangeHandler);", 'Harmony page listens for keyboard height changes');
  assertIncludes(page, "this.appWindow.off('keyboardHeightChange', this.keyboardHeightChangeHandler);", 'Harmony page unregisters keyboard height listener');
  assertIncludes(page, '.position({ x: this.floatingPanelX(), y: this.floatingPanelY() })', 'Harmony floating panels move when keyboard is visible');
  assertIncludes(page, '.height(this.floatingPanelMaxHeight())', 'Harmony input-heavy floating panels fill available height instead of wrapping content');
  assertIncludes(page, "this.topOverlayPanel === 'entryEditor'", 'Harmony entry editor floating panel uses available height');
  assertIncludes(page, 'height - this.floatingPanelY() - this.floatingPanelBottomGap() - this.effectiveKeyboardInset()', 'Harmony floating panel height avoids keyboard space');
  assertIncludes(page, 'this.shouldUpdateKeyboardBaselineViewportHeight(width, height, previousWidth)', 'Harmony viewport baseline is guarded against keyboard transition races');
  assert(!page.includes('height > this.keyboardBaselineViewportHeight || this.keyboardHeight <= 0'), 'Harmony viewport baseline is not overwritten by a shrunken keyboard viewport');
  assertIncludes(page, 'private remainingKeyboardOverlap(): number', 'Harmony page subtracts only keyboard overlap not already covered by viewport resize');
  assertIncludes(page, 'return Math.min(this.remainingKeyboardOverlap(), Math.max(height - 220, 0));', 'Harmony floating panel height only subtracts remaining keyboard overlap');
  assertIncludes(page, 'private viewportCompressedByKeyboard(): boolean', 'Harmony page treats a compressed input overlay viewport as keyboard mode');
  assertIncludes(page, 'private floatingPanelKeyboardMode(): boolean', 'Harmony floating panels do not depend solely on keyboardHeight events');
  assertIncludes(page, 'return this.keyboardVisible() || this.viewportCompressedByKeyboard();', 'Harmony keyboard mode falls back to viewport compression');
  assertIncludes(page, 'this.syncKeyboardAvoidArea(this.appWindow);', 'Harmony page resyncs keyboard avoid area after viewport changes');
  assertIncludes(page, 'this.scheduleKeyboardAvoidAreaSync();', 'Harmony input focus schedules keyboard avoid-area resync');
  assertIncludes(page, '.onFocus(() => {', 'Harmony input fields resync keyboard avoid-area when focused');
  assertIncludes(page, 'private viewportAlreadyAvoidsKeyboard(): boolean', 'Harmony page detects when viewport already resized for keyboard');
  assertIncludes(page, 'if (this.viewportAlreadyAvoidsKeyboard())', 'Harmony page avoids subtracting keyboard height twice');
  assertIncludes(page, 'return this.keyboardHeight > 0;', 'Harmony page keeps keyboard-visible layout even when inset is already applied');
  assertIncludes(page, 'this.floatingPanelKeyboardMode() ? 120 : 260', 'Harmony input-heavy panel scroll areas shrink for keyboard mode');
}

function main() {
  for (const file of Object.values(files)) {
    const absolute = path.join(root, file);
    assert(fs.existsSync(absolute), `Required contract file exists: ${rel(file)}`);
  }
  checkReleaseMetadata();
  checkCryptoContract();
  checkTemplateIdContract();
  checkFieldReferenceBehavior();
  checkTotpContract();
  checkPersistenceAndSyncSecrecy();
  checkSyncSettingsContract();
  checkThemeResourcesContract();
  checkThemedTextInputContract();
  checkEntryEditorUiContract();
  checkFieldReferenceEditorProtection();
  checkEntryDetailUiContract();
  checkCategoryManagementContract();
  checkCategoryFocusContract();
  checkKeyboardAvoidanceContract();

  if (failures > 0) {
    console.error(`[FAIL] Harmony contract tests failed: ${failures}`);
    process.exit(1);
  }
  console.log('[OK] Harmony contract tests passed');
}

main();
