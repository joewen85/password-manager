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

P1 implements lossless reading, writing, synchronization, and import/export of the additive fields on every maintained client. It does not expose reference creation or editing, resolve references for display or search, apply lifecycle rules, or remap reference IDs during copy imports. Those behaviors are staged for P2 and the platform UI phases; the corresponding sections below define their required end state rather than current P1 behavior.

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

## Category Lifecycle

When a category is renamed, every reference field whose `targetCategory` matches the old category name is updated to the new canonical name.

When a category is deleted:

- entries currently in that category follow the existing behavior and become uncategorized;
- reference field definitions retain their target category text;
- existing reference values are retained;
- the client reports the target category or referenced entry as unavailable rather than deleting data silently.

## Persistence And Sync

Reference field definitions live in `categoryTemplates`. Reference values live in each entry's `customFields`. They are encrypted, persisted, backed up, merged, and synchronized with the enclosing snapshot or entry.

All maintained clients must preserve the three additive properties before any client exposes reference editing. A mixed deployment with an older client can otherwise rewrite a template with only `id` and `name`, so users must update every synchronized client before enabling reference fields.

The current version-1 sync envelope has no peer-capability negotiation, and already-deployed clients cannot be made to reject a future payload retroactively. Therefore deployment uses an explicit minimum-client gate: P1 adds lossless readers/writers on every maintained client without exposing reference editing; reference UI can ship only after those compatible builds are available for every synchronized platform. Rollback to an earlier client after reference fields are created is unsupported and must be called out in release notes.

Concurrent edits continue to use the repository's existing snapshot, category-template, and entry version-vector rules. This contract does not introduce a second conflict system.

## Import And Export

- Full snapshot export includes category templates and reference values.
- Single-entry and category exports include the source entries' relevant category templates so `templateFieldId`, `valueType`, and `targetCategory` remain interpretable after import.
- Single-entry and category exports may contain reference IDs but do not automatically include referenced entries from other categories.
- Import keeps unresolved reference IDs rather than clearing them.
- Import merges included templates by their category and stable field IDs before applying imported entries.
- In P1, copy imports preserve the stored reference ID unchanged. P2 must remap references whose targets are included and copied in the same import to those targets' new IDs.
- A scoped export must not disclose a referenced entry's label, username, password, token, secret, or other field unless that entry was explicitly included in the export scope.

## Search And Display

Clients display the referenced entry label and category after resolving the stored ID. Raw IDs are not the primary user-facing value. Search may index the resolved label and category, but must not index or log secret values from the target entry.

## Permissions And Privacy

Reference fields operate entirely inside the existing encrypted vault. They require no new Android or HarmonyOS permissions and do not change the current privacy declarations. Platform permission documentation should record this conclusion when the UI feature is released.
