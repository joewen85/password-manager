#!/usr/bin/env node
import fs from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import path from 'node:path';
import process from 'node:process';
import vm from 'node:vm';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const etsRoot = path.join(root, 'apps/harmony_app/entry/src/main/ets');
const preferencesPath = path.join(etsRoot, 'src/domain/AppUiPreferences.ets');
const localizationPath = path.join(etsRoot, 'src/domain/AppLocalization.ets');
const abilityPath = path.join(etsRoot, 'entryability/EntryAbility.ets');
const indexPath = path.join(etsRoot, 'pages/Index.ets');
let failures = 0;

function assert(condition, message) {
  if (condition) {
    console.log(`[OK] ${message}`);
    return;
  }
  failures += 1;
  console.error(`[FAIL] ${message}`);
}

function loadLocalizationRuntime() {
  const preferences = fs.readFileSync(preferencesPath, 'utf8')
    .replace(/\bexport\s+/g, '');
  const localization = fs.readFileSync(localizationPath, 'utf8')
    .replace(/import\s*{[\s\S]*?}\s*from\s*['"]\.\/AppUiPreferences['"];\s*/, '')
    .replace(/\bexport\s+/g, '');
  const executable = stripTypeScriptTypes(
    `${preferences}\n${localization}\n;({
      defaultAppUiPreferences,
      normalizeAppAppearance,
      normalizeAppLanguage,
      resolveAppLanguage,
      localizeText,
      formatLocalizedText,
    });`,
    { mode: 'transform' },
  );
  return vm.runInNewContext(executable, {});
}

function main() {
  [preferencesPath, localizationPath, abilityPath, indexPath].forEach((file) => {
    assert(fs.existsSync(file), `Required Harmony UI preference file exists: ${path.relative(root, file)}`);
  });

  const runtime = loadLocalizationRuntime();
  const defaults = runtime.defaultAppUiPreferences();
  assert(defaults.language === 'system', 'Language defaults to the system setting');
  assert(defaults.appearance === 'system', 'Appearance defaults to the system setting');

  assert(runtime.normalizeAppLanguage('english') === 'english', 'English preference is preserved');
  assert(runtime.normalizeAppLanguage('simplifiedChinese') === 'simplifiedChinese', 'Chinese preference is preserved');
  assert(runtime.normalizeAppLanguage('unknown') === 'system', 'Unknown language preference falls back to system');
  assert(runtime.normalizeAppAppearance('dark') === 'dark', 'Dark appearance preference is preserved');
  assert(runtime.normalizeAppAppearance('unknown') === 'system', 'Unknown appearance preference falls back to system');

  assert(runtime.resolveAppLanguage('system', 'en-US') === 'en', 'System English locale resolves to English');
  assert(runtime.resolveAppLanguage('system', 'zh-Hans') === 'zh', 'System Simplified Chinese locale resolves to Chinese');
  assert(runtime.resolveAppLanguage('system', 'zh-CN') === 'zh', 'System Chinese locale resolves to Chinese');
  assert(runtime.resolveAppLanguage('english', 'zh-CN') === 'en', 'Explicit English overrides system locale');
  assert(runtime.resolveAppLanguage('simplifiedChinese', 'en-US') === 'zh', 'Explicit Chinese overrides system locale');
  assert(runtime.localizeText('外观', 'en') === 'Appearance', 'English translation is selected');
  assert(runtime.localizeText('外观', 'zh') === '外观', 'Chinese text remains in Chinese');
  assert(runtime.localizeText('研发环境', 'en') === '研发环境', 'Unknown and user-defined text is preserved');
  assert(
    runtime.formatLocalizedText('解锁暂时受限，请在 {0} 秒后重试', 'en', ['12']) ===
      'Unlock is temporarily blocked. Try again in 12 seconds.',
    'Localized messages retain formatted values',
  );

  const localizationSource = fs.readFileSync(localizationPath, 'utf8');
  const keys = [...localizationSource.matchAll(/\[\s*'((?:\\.|[^'])*)'\s*,\s*'((?:\\.|[^'])*)'\s*\]/g)]
    .map((match) => match[1]);
  assert(new Set(keys).size === keys.length, 'English translation keys are unique');

  const abilitySource = fs.readFileSync(abilityPath, 'utf8');
  const indexSource = fs.readFileSync(indexPath, 'utf8');
  assert(
    abilitySource.includes("Environment.envProp('languageCode', 'en')") &&
      indexSource.includes("@StorageProp('languageCode')"),
    'System language is exposed to the page through ArkUI environment storage',
  );
  assert(
    indexSource.includes("this.AppUiPreferencesSection()") &&
      indexSource.includes("this.setAppLanguage('english')") &&
      indexSource.includes("this.setAppLanguage('simplifiedChinese')"),
    'Settings expose English and Simplified Chinese choices',
  );

  if (failures > 0) {
    process.exitCode = 1;
    return;
  }
  console.log('Harmony app UI preference tests passed.');
}

main();
