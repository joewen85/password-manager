# Field Reference Contract

This document defines the cross-platform data contract for category-template fields that can optionally reference one vault entry from another category. Tags remain a separate, loose grouping mechanism and are not used as entry references.

## Scope

The first contract version supports:

- text fields;
- optional single-entry reference fields;
- a target category used to limit entry selection;
- stable entry IDs as stored reference values;
- backward-compatible decoding of snapshots created before reference fields existed.

Multiple references, cascading deletion, automatic dependency export, and category IDs are out of scope for this version.

## Rollout Status

P1 implements lossless reading, writing, synchronization, and import/export of the additive fields on every maintained client. P2a adds the same pure reference resolver and safe display projection to Android, HarmonyOS, iOS, macOS, and the shared native core. P2b connects category-rename propagation and verifies that delete, restore, and category-move lifecycles retain stored references. P2c adds safe resolved-target search projection, copy-import ID remapping, and conflict-preservation coverage. Reference creation, editing, and detail display remain staged for the platform UI phases.

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

Currently supported `valueType` values are:

- `text`: a regular user-entered text value;
- `entryReference`: the value is the canonical ID of one vault entry.

Entry custom fields use the following shape:

```json
{
  "id": "4d3fc498-71ed-4cc8-a255-724cfe36ff26",
  "templateFieldId": "template_owner",
  "name": "Owner",
  "value": "2e6cab93-b5e6-4bee-a789-e495f7ad63c5"
}
```

`id` identifies this field value instance. `templateFieldId` identifies the category-template field that defines its behavior. They are deliberately separate identifiers.

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
          "targetCategory": "Accounts"
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
- A missing `templateFieldId` is read as an empty string.
- A version-1 scoped export without `categoryTemplates` remains readable and is treated as having no included templates. New scoped exports use version 2.
- Existing text values are never interpreted as references unless their template field explicitly has `valueType = entryReference`.
- During template application, implementations match by non-empty `templateFieldId` first and fall back to the existing normalized field-name match for legacy data.
- New writers include `valueType`, `targetCategory`, and `templateFieldId` so all maintained clients preserve the same shape.
- The encrypted envelope and sync payload versions do not change because this is an additive change inside the encrypted vault JSON. Adding a snapshot version alone would not protect data: existing clients neither negotiate capabilities nor reject future versions before rewriting them.

There is no database schema in this repository. Vault data is stored as encrypted JSON snapshots, so the decoder defaults above are the migration path for initialized and existing vaults.

### Identifier Rules

- A non-empty `FieldTemplate.id` is an opaque, stable value. Implementations preserve it exactly and never recalculate it when the field name changes.
- New user-created template fields use canonical lowercase UUID strings.
- Existing non-empty `VaultEntry.id` and `CustomField.id` values are also preserved as opaque strings. Decoders must not replace a non-UUID ID with a generated UUID.
- The built-in name and notes fields keep well-known IDs defined by the shared contract.
- When legacy input has no template field ID, all clients synthesize the same deterministic `template_<normalized-name>` fallback. Normalization lowercases the trimmed name, retains ASCII letters, digits, and CJK Unified Ideographs U+4E00 through U+9FFF, replaces every other run with one underscore, and trims leading/trailing underscores. If that normalized name is empty but the trimmed name is not, clients use `template_u_<utf8-hex>`, where `utf8-hex` is the lowercase hexadecimal encoding of the trimmed original name's UTF-8 bytes (for example, `😀` becomes `template_u_f09f9880` and `!!!` becomes `template_u_212121`). An empty original name uses `template_empty` defensively, although empty-named template fields are discarded during normalization.
- A non-empty `CustomField.templateFieldId` must equal the defining template field's opaque ID. A custom field's own `id` remains its independent value-instance ID.

## Invariants

- `entryReference` fields are optional in this version.
- A non-empty reference value is a canonical vault entry ID, never a label, category name, or tag.
- `targetCategory` limits selection but is not the identity of the referenced entry.
- Renaming a referenced entry does not change the stored reference.
- Moving a referenced entry to another category does not silently clear the stored reference.
- Soft-deleting a referenced entry does not cascade to the source entry.
- An unresolved, deleted, or category-mismatched reference remains stored and is presented as unavailable until the user clears or replaces it.
- A source entry cannot expose secret fields from the referenced entry without the normal vault-unlocked access path.

## Resolution Semantics

Resolution applies only when the source custom field matches a template field whose `valueType` is exactly `entryReference`:

- A non-empty `templateFieldId` is matched exactly as an opaque, case-sensitive ID. Implementations do not fall back to a field-name match when that ID is present but unknown.
- Only a truly empty `templateFieldId` enables the legacy fallback, which compares trimmed field names without case sensitivity.
- A whitespace-only reference value resolves to `empty` before any target lookup.
- A non-empty reference value matches a target entry ID exactly and case-sensitively. Labels, names, categories, and tags never participate in identity matching.
- A target that is not present resolves to `missing`.
- A target whose current `isDeleted` flag is set resolves to `deleted`, even if its category also differs.
- For a live target, a non-empty `targetCategory` is compared after trimming both categories and without case sensitivity. A failed comparison resolves to `categoryMismatch`; an empty target category imposes no restriction.
- A live target satisfying the category constraint resolves to `resolved`.

The effective precedence is `empty` -> `missing` -> `deleted` -> `categoryMismatch` -> `resolved`. `empty` and `missing` have no target projection. Every found-target state (`deleted`, `categoryMismatch`, and `resolved`) may expose only a projection containing the target `id`, `label`, and trimmed `category`; it must never return the target entry, payload, username, password, token, secret, notes, tags, or custom fields.

## Category Lifecycle

When a category is renamed, every template field whose `valueType` is exactly `entryReference` and whose trimmed `targetCategory` matches the trimmed old category name without case sensitivity is updated to the trimmed new canonical name. Field IDs, names, source values, template ownership, and all other metadata remain unchanged. Text fields and unknown future field types are never rewritten by this propagation rule.

When a category is deleted:

- entries currently in that category follow the existing behavior and become uncategorized;
- reference field definitions retain their target category text;
- existing reference values are retained;
- the client reports the target category or referenced entry as unavailable rather than deleting data silently.

Soft-deleting a referenced entry retains the source value and changes resolution to `deleted`. Restoring the same entry ID can return it to `resolved`. Moving the live target to another category, including the uncategorized state produced by category deletion, retains the source value and resolves to `categoryMismatch` while the configured category constraint is no longer satisfied.

## Persistence And Sync

Reference field definitions live in `categoryTemplates`. Reference values live in each entry's `customFields`. They are encrypted, persisted, backed up, merged, and synchronized with the enclosing snapshot or entry.

All maintained clients must preserve the three additive properties before any client exposes reference editing. A mixed deployment with an older client can otherwise rewrite a template with only `id` and `name`, so users must update every synchronized client before enabling reference fields.

The current version-1 sync envelope has no peer-capability negotiation, and already-deployed clients cannot be made to reject a future payload retroactively. Therefore deployment uses an explicit minimum-client gate: P1 adds lossless readers/writers on every maintained client without exposing reference editing; reference UI can ship only after those compatible builds are available for every synchronized platform. Rollback to an earlier client after reference fields are created is unsupported and must be called out in release notes.

Concurrent edits continue to use the repository's existing snapshot, category-template, and entry version-vector rules. Entry content comparison includes `customFields`; keep-both conflict copies retain reference values and `templateFieldId`. This contract does not introduce a second conflict system.

## Import And Export

- Full snapshot export includes category templates and reference values.
- Single-entry and category exports include the source entries' relevant category templates so `templateFieldId`, `valueType`, and `targetCategory` remain interpretable after import.
- Single-entry and category exports may contain reference IDs but do not automatically include referenced entries from other categories.
- Import keeps unresolved reference IDs rather than clearing them.
- Import merges included templates by their category and stable field IDs before applying imported entries.
- Copy imports determine destination IDs for the whole batch before writing entries. A recognized `entryReference` whose target is applied in that batch is rewritten to the target's destination ID; a target not included or not mapped keeps the original stored ID.
- A scoped export must not disclose a referenced entry's label, username, password, token, secret, or other field unless that entry was explicitly included in the export scope.

## Search And Display

Clients display the referenced entry label and category after resolving the stored ID. Raw IDs are not the primary user-facing value. Search replaces recognized reference-field values with the target label and trimmed category only when resolution is `resolved`; empty, missing, deleted, and category-mismatched references contribute no target value. Search never indexes the stored reference ID or any target payload, username, password, token, secret, notes, tags, or custom fields.

## Permissions And Privacy

Reference fields operate entirely inside the existing encrypted vault. They require no new Android or HarmonyOS permissions and do not change the current privacy declarations. Platform permission documentation should record this conclusion when the UI feature is released.
