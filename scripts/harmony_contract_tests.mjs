#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');

const files = {
  appScope: 'apps/harmony_app/AppScope/app.json5',
  buildProfile: 'apps/harmony_app/build-profile.json5',
  module: 'apps/harmony_app/entry/src/main/module.json5',
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
  assertIncludes(controller, 'return `template_${output.length > 0 ? output : nextId()}`;', 'Harmony field template IDs use underscores');
  assertIncludes(controller, 'return `${ts}_${rand}`;', 'Harmony generated fallback IDs use underscores');
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

function checkEntryEditorUiContract() {
  const page = read(files.indexPage);
  assertMatches(
    page,
    /if\s*\(\s*this\.editingEntryId\.length\s*>\s*0\s*\)\s*{\s*Text\('条目类型'\)/s,
    'Harmony new entry hides entry type selector until editing',
  );
  assertMatches(
    page,
    /if\s*\(\s*this\.editingEntryId\.length\s*>\s*0\s*&&\s*this\.draftType\s*===\s*'credential'\s*\)/,
    'Harmony new credential does not show username, password, or account fields before editing',
  );
  assertMatches(
    page,
    /if\s*\(\s*this\.editingEntryId\.length\s*>\s*0\s*&&\s*this\.draftType\s*===\s*'server'\s*\)/,
    'Harmony new server does not show server payload fields before editing',
  );
  assertMatches(
    page,
    /if\s*\(\s*this\.editingEntryId\.length\s*>\s*0\s*&&\s*this\.draftType\s*===\s*'service'\s*\)/,
    'Harmony new service does not show service payload fields before editing',
  );
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
    'ForEach(this.draftCustomFields',
    "this.AddFieldButton('添加字段'",
    'Harmony entry field add button appears after existing entry fields',
  );
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

function main() {
  for (const file of Object.values(files)) {
    const absolute = path.join(root, file);
    assert(fs.existsSync(absolute), `Required contract file exists: ${rel(file)}`);
  }
  checkReleaseMetadata();
  checkCryptoContract();
  checkTemplateIdContract();
  checkTotpContract();
  checkPersistenceAndSyncSecrecy();
  checkSyncSettingsContract();
  checkThemeResourcesContract();
  checkEntryEditorUiContract();
  checkCategoryManagementContract();

  if (failures > 0) {
    console.error(`[FAIL] Harmony contract tests failed: ${failures}`);
    process.exit(1);
  }
  console.log('[OK] Harmony contract tests passed');
}

main();
