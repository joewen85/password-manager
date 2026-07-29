# Field Reference Contract

This document defines the cross-platform data contract for category-template fields that can reference either one vault entry or one stable field on a selected entry from another category. Tags remain a separate, loose grouping mechanism and are not used as references.

## Scope

The contract supports:

- text fields;
- legacy optional single-entry reference fields;
- additive field-reference metadata that identifies a target category and stable target template-field ID;
- a target category used to limit entry selection;
- stable entry IDs as stored reference values;
- backward-compatible decoding of snapshots created before reference fields existed.

Multiple references, recursive reference chains, cascading deletion, automatic dependency export, and category IDs are out of scope for this version.

## Rollout Status

P1-P6 implement the legacy `entryReference` contract, resolver, lifecycle, safe projections, UI slices, and native CLI display. P7 adds the cross-platform compatibility layer for the new `fieldReference` shape: every maintained client can losslessly read, write, synchronize, import, and export `targetFieldId`. P8 adds the common one-hop resolver, lifecycle guards, safe search projection, copy-import remapping, and sync behavior on Android, HarmonyOS, iOS, macOS, and the Windows/Linux native core. P9-P11 expose creation and editing UI on HarmonyOS, Android, iOS, and macOS; P12 adds native CLI presentation. Existing `entryReference` behavior remains unchanged throughout this rollout. Unknown field types and orphaned bindings remain preserved, but their stored values stay hidden from display, copy, and search.

## JSON Shape

Category template fields use the following shape:

```json
{
  "id": "template_owner",
  "name": "Owner",
  "valueType": "entryReference",
  "targetCategory": "Accounts"
}
```

A field-to-field reference uses a distinct additive type and a stable target template-field ID:

```json
{
  "id": "source_owner_email_field",
  "name": "Owner Email",
  "valueType": "fieldReference",
  "targetCategory": "Accounts",
  "targetFieldId": "target_email_field"
}
```

Currently supported `valueType` values are:

- `text`: a regular user-entered text value;
- `entryReference`: the value is the canonical ID of one vault entry;
- `fieldReference`: the value still selects one target entry by canonical ID, while `targetFieldId` identifies which field on that entry the relationship projects.

Entry custom fields use the following shape:

```json
{
  "id": "4d3fc498-71ed-4cc8-a255-724cfe36ff26",
  "templateFieldId": "template_owner",
  "name": "Owner",
  "value": "2e6cab93-b5e6-4bee-a789-e495f7ad63c5"
}
```

`id` identifies this field value instance. `templateFieldId` identifies the source category-template field that defines its behavior. For `fieldReference`, `value` stores the concrete target entry ID and `targetFieldId` stores the stable target category-template field ID. These identifiers are deliberately separate.

Entry, custom-field-instance, and template-field IDs are opaque, non-empty strings at the cross-platform boundary. New IDs use canonical lowercase UUID strings, but readers preserve existing non-UUID IDs produced by maintained clients rather than replacing or reinterpreting them.

Scoped exports that carry field semantics use version 2:

```json
{
  "version": 2,
  "scope": "item",
  "item": {},
  "categoryTemplates": [
    {
      "category": "Servers",
      "fields": [
        {
          "id": "template_owner",
          "name": "Owner",
          "valueType": "entryReference",
          "targetCategory": "Accounts",
          "targetFieldId": ""
        }
      ]
    }
  ]
}
```

## Compatibility And Migration

- A missing `valueType` is read as `text`.
- An unknown non-empty `valueType` is preserved verbatim. Clients must not offer an editor that could rewrite its value; they present the field as an unsupported, read-only field.
- A missing `targetCategory` is read as an empty string.
- A missing `targetFieldId` is read as an empty string.
- A missing `templateFieldId` is read as an empty string.
- A version-1 scoped export without `categoryTemplates` remains readable and is treated as having no included templates. New scoped exports use version 2.
- Existing text values are never interpreted as references unless their template field explicitly has `valueType = entryReference` or `valueType = fieldReference`.
- During template application, implementations match by non-empty `templateFieldId` first and fall back to the existing normalized field-name match for legacy data.
- A custom field with a non-empty `templateFieldId` that does not match the current category template is treated as an opaque, unsupported field. Its stored value is preserved but must not be displayed, copied, edited, or indexed as ordinary text.
- New writers include `valueType`, `targetCategory`, `targetFieldId`, and `templateFieldId` so all maintained clients preserve the same shape.
- The encrypted envelope and sync payload versions do not change because this is an additive change inside the encrypted vault JSON. Adding a snapshot version alone would not protect data: existing clients neither negotiate capabilities nor reject future versions before rewriting them.

There is no database schema in this repository. Vault data is stored as encrypted JSON snapshots, so the decoder defaults above are the migration path for initialized and existing vaults.

### Identifier Rules

- A non-empty `FieldTemplate.id` is an opaque, stable value. Implementations preserve it exactly and never recalculate it when the field name changes.
- A non-empty `FieldTemplate.targetFieldId` is another opaque, case-sensitive template-field ID. Implementations preserve it exactly and never derive it from the target field name.
- New user-created template fields and custom-field instances use canonical lowercase UUID strings.
- Existing non-empty `VaultEntry.id` and `CustomField.id` values are also preserved as opaque strings. Decoders must not replace a non-UUID ID with a generated UUID.
- The built-in name and notes fields keep well-known IDs defined by the shared contract.
- When legacy input has no template field ID, all clients synthesize the same deterministic `template_<normalized-name>` fallback. Normalization lowercases the trimmed name, retains ASCII letters, digits, and CJK Unified Ideographs U+4E00 through U+9FFF, replaces every other run with one underscore, and trims leading/trailing underscores. If that normalized name is empty but the trimmed name is not, clients use `template_u_<utf8-hex>`, where `utf8-hex` is the lowercase hexadecimal encoding of the trimmed original name's UTF-8 bytes (for example, `😀` becomes `template_u_f09f9880` and `!!!` becomes `template_u_212121`). An empty original name uses `template_empty` defensively, although empty-named template fields are discarded during normalization.
- A non-empty `CustomField.templateFieldId` must equal the defining template field's opaque ID. A custom field's own `id` remains its independent value-instance ID.

## Invariants

- `entryReference` fields are optional in this version.
- `fieldReference` keeps the same optional source value shape: an empty value selects no target entry.
- A non-empty reference value is a canonical vault entry ID, never a label, category name, or tag.
- `targetCategory` limits selection but is not the identity of the referenced entry.
- A valid `fieldReference` requires a non-empty `targetCategory` and `targetFieldId`; the first behavior release permits only a text target field, one-hop resolution, and no self-reference.
- Renaming a referenced target field does not change the relationship because `targetFieldId`, not its name, is the identity.
- Renaming a referenced entry does not change the stored reference.
- Moving a referenced entry to another category does not silently clear the stored reference.
- Soft-deleting a referenced entry does not cascade to the source entry.
- An unresolved, deleted, or category-mismatched reference remains stored and is presented as unavailable until the user clears or replaces it.
- Once a source template field has a non-empty stored value, clients must not silently delete the field definition or change its `valueType` among `text`, `entryReference`, and `fieldReference`. Renaming the field or changing a compatible reference constraint keeps the same stored-value semantics and stable field ID.
- A text template field targeted by any `fieldReference` may be renamed without breaking the relationship, but it cannot be deleted or changed to another type while that reference definition exists.
- A source entry cannot expose secret fields from the referenced entry without the normal vault-unlocked access path.

## Resolution Semantics

The currently released resolver applies only when the source custom field matches a template field whose `valueType` is exactly `entryReference`:

- A non-empty `templateFieldId` is matched exactly as an opaque, case-sensitive ID. Implementations do not fall back to a field-name match when that ID is present but unknown.
- Only a truly empty `templateFieldId` enables the legacy fallback, which compares trimmed field names without case sensitivity.
- A whitespace-only reference value resolves to `empty` before any target lookup.
- A non-empty reference value matches a target entry ID exactly and case-sensitively. Labels, names, categories, and tags never participate in identity matching.
- A target that is not present resolves to `missing`.
- A target whose current `isDeleted` flag is set resolves to `deleted`, even if its category also differs.
- For a live target, a non-empty `targetCategory` is compared after trimming both categories and without case sensitivity. A failed comparison resolves to `categoryMismatch`; an empty target category imposes no restriction.
- A live target satisfying the category constraint resolves to `resolved`.

The effective precedence is `empty` -> `missing` -> `deleted` -> `categoryMismatch` -> `resolved`. `empty` and `missing` have no target projection. Every found-target state (`deleted`, `categoryMismatch`, and `resolved`) may expose only a projection containing the target `id`, `label`, and trimmed `category`; it must never return the target entry, payload, username, password, token, secret, notes, tags, or custom fields.

The P8 `fieldReference` resolver applies only when the source custom field matches a source template field whose `valueType` is exactly `fieldReference`. It is strictly one hop and uses this precedence:

1. A whitespace-only source value resolves to `empty`.
2. An empty `targetCategory`, empty `targetFieldId`, or same-category `sourceField.id == targetFieldId` self-reference resolves to `invalidConfiguration`.
3. A source value with no exact, case-sensitive target-entry ID match resolves to `missing`.
4. A found soft-deleted target resolves to `deleted` before category or field checks.
5. A live target whose trimmed category does not equal trimmed `targetCategory` without case sensitivity resolves to `categoryMismatch`.
6. A missing target category template or missing exact, case-sensitive `targetFieldId` resolves to `targetFieldMissing`.
7. A target template field whose normalized type is not `text` resolves to `targetFieldUnsupported`; reference types are not recursively evaluated.
8. A missing or whitespace-only target field value resolves to `targetFieldEmpty`.
9. Otherwise the reference resolves to `resolved`.

The target custom-field instance first matches by a non-empty, exact, case-sensitive `templateFieldId`. Only a truly empty instance `templateFieldId` enables the legacy fallback by trimmed field name without case sensitivity; a wrong non-empty ID never falls back by name. This compatibility fallback cannot guarantee rename stability for unmigrated legacy instances, while ID-backed instances remain stable across field renames.

`empty`, `invalidConfiguration`, and `missing` have no target projection. Once the target entry is found, the resolver may return only its opaque ID, label, trimmed category, and configured target field ID; once the target template field is found, it may also return that field's name. The target field value is populated only for `resolved`. The resolver never returns the full target entry, payload, username, password, token, secret, notes, tags, or unrelated custom fields.

## Category Lifecycle

When a category is renamed, every template field whose `valueType` is exactly `entryReference` or `fieldReference` and whose trimmed `targetCategory` matches the trimmed old category name without case sensitivity is updated to the trimmed new canonical name. Field IDs, names, source values, `targetFieldId`, template ownership, and all other metadata remain unchanged. Text fields and unknown future field types are never rewritten by this propagation rule.

When a category is deleted:

- entries currently in that category follow the existing behavior and become uncategorized;
- reference field definitions retain their target category text;
- existing reference values are retained;
- custom fields whose source template no longer exists become opaque unsupported fields, preserving their value without displaying, copying, editing, or indexing it as text;
- the client reports the target category or referenced entry as unavailable rather than deleting data silently.

Soft-deleting a referenced entry retains the source value and changes resolution to `deleted`. Restoring the same entry ID can return it to `resolved`. Moving the live target to another category, including the uncategorized state produced by category deletion, retains the source value and resolves to `categoryMismatch` while the configured category constraint is no longer satisfied.

## Persistence And Sync

Reference field definitions live in `categoryTemplates`. Reference values live in each entry's `customFields`. They are encrypted, persisted, backed up, merged, and synchronized with the enclosing snapshot or entry.

All maintained clients must preserve the additive reference properties before any client exposes the corresponding editing UI. A mixed deployment with an older client can otherwise rewrite a template with only `id` and `name`, so users must update every synchronized client before enabling reference fields.

The current version-1 sync envelope has no peer-capability negotiation, and already-deployed clients cannot be made to reject a future payload retroactively. Therefore deployment uses an explicit minimum-client gate: P1 adds lossless readers/writers on every maintained client without exposing reference editing; reference UI can ship only after those compatible builds are available for every synchronized platform. Rollback to an earlier client after reference fields are created is unsupported and must be called out in release notes.

The removed legacy Flutter application is not a maintained writer and does not implement the additive reference contract. Historical Flutter vaults may be migrated into a current maintained client, but after a reference field is created, an old Flutter build must not write to the same synchronized vault. Downgrading or resuming legacy Flutter writeback is unsupported.

Concurrent edits continue to use the repository's existing snapshot, category-template, and entry version-vector rules. Entry content comparison includes `customFields`; keep-both conflict copies retain reference values and `templateFieldId`. This contract does not introduce a second conflict system.

## Import And Export

- Full snapshot export includes category templates and reference values.
- Single-entry and category exports include the source entries' relevant category templates so `templateFieldId`, `valueType`, `targetCategory`, and `targetFieldId` remain interpretable after import.
- Single-entry and category exports may contain reference IDs but do not automatically include referenced entries from other categories.
- Import keeps unresolved reference IDs rather than clearing them.
- Import merges included templates by their category and stable field IDs before applying imported entries.
- Copy imports determine destination IDs for the whole batch before writing entries. A recognized `entryReference` or `fieldReference` whose target is applied in that batch is rewritten to the target entry's destination ID; a target not included or not mapped keeps the original stored ID. `targetFieldId` is never remapped because it identifies a template field, not the copied entry.
- A scoped export must not disclose a referenced entry's label, username, password, token, secret, or other field unless that entry was explicitly included in the export scope.
- The native CLI `export-snapshot` command is a lossless plaintext export rather than a display projection. It intentionally preserves stored reference IDs and unknown/orphan values for later import and must be handled as sensitive vault data.

## Search And Display

Legacy `entryReference` UI displays the referenced entry label and category after resolving the stored ID. Raw IDs are not a user-facing value and must not appear in detail text, editable text controls, copy actions, search indexes, or logs. HarmonyOS, Android, iOS, and macOS entry editors allow users to select, replace, or clear only live `entryReference` candidates satisfying the target-category constraint. Their details render `empty`, `resolved`, `missing`, `deleted`, and `categoryMismatch`; a resolved target may be opened through the normal unlocked-vault detail path, while unavailable states may offer repair or clear actions without exposing the stored ID. The Windows/Linux shared CLI renders the same legacy states through `show-entry`; `--show-secret` may reveal only the selected source entry's own secret and never restores a reference ID, target secret, unknown value, or orphaned binding value.

P8 does not yet expose `fieldReference` creation, editing, detail, or copy UI. Its search projection contributes the resolved target entry label, trimmed category, and target field name only. It never contributes the target field value, source or target raw IDs, target payload, username, password, token, secret, notes, tags, or unrelated custom fields. Every non-resolved field-reference state contributes an empty search value. A later explicit detail or copy action may use the resolved target field value only after the normal vault-unlocked boundary and must never index or log it. Unknown field types and custom fields with orphaned non-empty `templateFieldId` values remain preserved, but their stored values are not displayed, copied, edited, or indexed.

## Permissions And Privacy

Reference fields operate entirely inside the existing encrypted vault JSON. They require no new Android, HarmonyOS, iOS, macOS, Windows, or Linux permissions, entitlements, network endpoints, SDKs, database schema, or data collection and do not change the current privacy declarations. There is therefore no database migration for P3-P8; additive JSON decoder defaults remain the compatibility path. `targetFieldId` is reference metadata, not a materialized target value, and does not expand export or collection scope. Platform permission documentation records this conclusion when each feature is released.
