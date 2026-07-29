# Vault Contract Fixtures v1

These fixtures are the canonical semantic examples for additive reference fields. Every maintained native client must decode the relevant fixture, assert the reference metadata, re-encode it, and prove that `valueType`, `targetCategory`, `targetFieldId`, `templateFieldId`, and opaque IDs are preserved.

- `snapshot-entry-reference.json`: valid and empty references plus non-UUID IDs from a maintained client.
- `snapshot-field-reference.json`: a source field targets a stable text field in another category while its value selects the concrete target entry.
- `snapshot-legacy-text.json`: legacy fields without the additive properties.
- `snapshot-legacy-empty-slug.json`: legacy emoji-only and punctuation-only field names without template IDs; clients must synthesize `template_u_f09f9880` and `template_u_212121` respectively.
- `snapshot-unknown-value-type.json`: an unsupported future type that must survive a round trip.
- `scoped-item-entry-reference.json`: version-2 item export with source templates but no referenced target entry.
- `scoped-category-entry-reference.json`: version-2 category export with the same privacy boundary.

Run `node scripts/verify_vault_contract_fixtures.mjs --check` after editing a fixture.
