#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const fixtureDirectory = path.join(root, 'fixtures', 'vault-contract', 'v1');
const fixtureNames = [
  'snapshot-entry-reference.json',
  'snapshot-legacy-text.json',
  'snapshot-legacy-empty-slug.json',
  'snapshot-unknown-value-type.json',
  'scoped-item-entry-reference.json',
  'scoped-category-entry-reference.json',
];

const mode = process.argv[2] ?? '--check';
if (!['--check', '--write'].includes(mode) || process.argv.length > 3) {
  console.error('Usage: node scripts/verify_vault_contract_fixtures.mjs [--check|--write]');
  process.exit(2);
}

const fixtures = new Map();
let failed = false;
for (const name of fixtureNames) {
  const fixturePath = path.join(fixtureDirectory, name);
  const raw = fs.readFileSync(fixturePath, 'utf8');
  const parsed = JSON.parse(raw);
  const canonical = `${JSON.stringify(parsed, null, 2)}\n`;
  fixtures.set(name, parsed);
  if (mode === '--write') {
    fs.writeFileSync(fixturePath, canonical);
  } else if (raw !== canonical) {
    console.error(`[FAIL] ${name} is not canonical two-space JSON with a trailing newline.`);
    failed = true;
  }
}

function requireInvariant(condition, message) {
  if (!condition) {
    console.error(`[FAIL] ${message}`);
    failed = true;
  }
}

function fieldByName(snapshot, category, fieldName) {
  return snapshot.categoryTemplates
    .find((template) => template.category === category)?.fields
    .find((field) => field.name === fieldName);
}

const referenceSnapshot = fixtures.get('snapshot-entry-reference.json');
const targetId = 'harmony_target_01';
const source = referenceSnapshot.entries.find((entry) => entry.label === 'Production Server');
const ownerField = fieldByName(referenceSnapshot, 'Servers', 'Owner');
requireInvariant(referenceSnapshot.entries.some((entry) => entry.id === targetId), 'reference snapshot contains its target');
requireInvariant(ownerField?.valueType === 'entryReference', 'Owner template is an entry reference');
requireInvariant(ownerField?.targetCategory === 'Accounts', 'Owner template targets Accounts');
requireInvariant(source?.customFields[0]?.templateFieldId === ownerField?.id, 'custom field binds to the stable template ID');
requireInvariant(source?.customFields[0]?.value === targetId, 'custom field stores the opaque target ID');
requireInvariant(source?.customFields[1]?.value === '', 'reference snapshot covers an empty optional reference');
requireInvariant(!targetId.includes('-'), 'fixture keeps a maintained non-UUID entry ID');

const legacySnapshot = fixtures.get('snapshot-legacy-text.json');
const legacyTemplate = legacySnapshot.categoryTemplates[0].fields[0];
const legacyCustomField = legacySnapshot.entries[0].customFields[0];
requireInvariant(!Object.hasOwn(legacyTemplate, 'valueType'), 'legacy template omits valueType');
requireInvariant(!Object.hasOwn(legacyTemplate, 'targetCategory'), 'legacy template omits targetCategory');
requireInvariant(!Object.hasOwn(legacyTemplate, 'id'), 'legacy template covers deterministic ID fallback');
requireInvariant(!Object.hasOwn(legacyCustomField, 'templateFieldId'), 'legacy custom field omits templateFieldId');

const emptySlugSnapshot = fixtures.get('snapshot-legacy-empty-slug.json');
const emptySlugFields = emptySlugSnapshot.categoryTemplates[0].fields;
requireInvariant(emptySlugFields.length === 2, 'empty-slug fixture contains both legacy field names');
requireInvariant(emptySlugFields[0].name === '😀', 'empty-slug fixture covers an emoji-only name');
requireInvariant(emptySlugFields[1].name === '!!!', 'empty-slug fixture covers a punctuation-only name');
requireInvariant(emptySlugFields.every((field) => !Object.hasOwn(field, 'id')), 'empty-slug fixture omits template IDs');

const unknownSnapshot = fixtures.get('snapshot-unknown-value-type.json');
requireInvariant(fieldByName(unknownSnapshot, 'Future', 'Future Link')?.valueType === 'futureLink', 'unknown valueType remains non-empty');

for (const name of ['scoped-item-entry-reference.json', 'scoped-category-entry-reference.json']) {
  const scoped = fixtures.get(name);
  const included = [scoped.item, ...(scoped.items ?? [])].filter(Boolean);
  const referencedIds = included.flatMap((entry) => entry.customFields ?? []).map((field) => field.value).filter(Boolean);
  requireInvariant(scoped.version === 2, `${name} uses scoped export version 2`);
  requireInvariant(scoped.categoryTemplates?.length === 1, `${name} includes the source category template`);
  requireInvariant(fieldByName(scoped, 'Servers', 'Owner')?.valueType === 'entryReference', `${name} preserves reference semantics`);
  requireInvariant(referencedIds.includes(targetId), `${name} keeps the unresolved reference ID`);
  requireInvariant(!included.some((entry) => entry.id === targetId), `${name} does not implicitly export the target entry`);
}

if (failed) {
  process.exit(1);
}
console.log(`[OK] ${fixtureNames.length} vault contract fixtures are canonical and internally consistent.`);
