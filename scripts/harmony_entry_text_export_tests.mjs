import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const controller = readFileSync(
  new URL('../apps/harmony_app/entry/src/main/ets/src/service/VaultController.ets', import.meta.url),
  'utf8',
);
const page = readFileSync(
  new URL('../apps/harmony_app/entry/src/main/ets/pages/Index.ets', import.meta.url),
  'utf8',
);

assert.match(controller, /exportSelectedEntryText\s*\(/);
assert.match(controller, /selectedFieldsText|buildSelectedEntryText/);
assert.match(page, /saveTextExportFile\s*\(/);
assert.match(page, /entry-export-selected[\s\S]*?\.txt/);
assert.match(controller, /id:\s*`custom\.\$\{field\.id\}`/);
assert.match(controller, /escapeEntryTextLine/);

console.log('HarmonyOS selected entry text export contract passed.');
