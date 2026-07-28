#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <password-manager-binary>" >&2
  exit 64
fi

bin="$1"
work_dir="$(dirname "$bin")/cli-smoke-$(basename "$bin")"
password="test-password"
vault="$work_dir/vault.envelope"
second_vault="$work_dir/second-vault.envelope"
sync_state="$work_dir/vault.sync-state"
second_sync_state="$work_dir/second-vault.sync-state"
remote_store="$work_dir/remote-vault.sync.json"
server_port_file="$work_dir/sync-port.txt"
backup_dir="$work_dir/backups"
export_file="$work_dir/export.json"
display_fixture="$work_dir/display-fixture.json"
display_output="$work_dir/display-output.json"
display_secret_output="$work_dir/display-secret-output.json"
display_export="$work_dir/display-export.json"

rm -rf "$work_dir"
mkdir -p "$work_dir"
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

"$bin" init "$password" --vault "$vault" >/dev/null
"$bin" add-category "$password" Infra --shortcut server --field Owner --vault "$vault" >/dev/null
"$bin" add-category "$password" CustomOnly --field Owner --vault "$vault" >/dev/null
"$bin" export-snapshot "$password" --vault "$vault" --out "$work_dir/category-template-check.json" >/dev/null
python3 - "$work_dir/category-template-check.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    snapshot = json.load(handle)

templates = {
    item.get("category"): [field.get("name") for field in item.get("fields", [])]
    for item in snapshot.get("categoryTemplates", [])
}
assert templates["CustomOnly"] == ["名称", "备注", "Owner"]
PY
"$bin" add-entry "$password" \
  --label "Smoke Entry" \
  --type service \
  --username svc-user \
  --secret svc-secret \
  --category Infra \
  --tag smoke \
  --field Owner=Platform \
  --vault "$vault" >/dev/null
printf '%s\n' "$password" | "$bin" list --password-stdin --vault "$vault" --query "Smoke Entry" | grep -q "matches=1"

python3 "$(dirname "$0")/vault_sync_server.py" "$server_port_file" "$remote_store" &
server_pid="$!"
for _ in {1..50}; do
  [[ -s "$server_port_file" ]] && break
  sleep 0.1
done
test -s "$server_port_file"
sync_url="http://127.0.0.1:$(cat "$server_port_file")"

printf '%s\n%s\n' "$password" "remote-password" | "$bin" sync --password-stdin \
  --provider webdav \
  --endpoint "$sync_url" \
  --object-key vault.sync.json \
  --vault "$vault" \
  --state "$sync_state" \
  --username native-smoke \
  --remote-password-stdin \
  --device-id native-smoke | grep -q "uploaded=true"
grep -q '"revision":0' "$remote_store"
grep -q 'hasLocalChanges=false' "$sync_state"
! grep -Eq 'test-password|svc-secret|SecretKey|SecretId|remote-password' "$sync_state"

"$bin" add-entry "$password" \
  --label "Second Local Entry" \
  --type credential \
  --username second-user \
  --secret second-secret \
  --category Infra \
  --vault "$vault" >/dev/null
grep -q 'hasLocalChanges=true' "$sync_state"
"$bin" sync "$password" \
  --provider webdav \
  --endpoint "$sync_url" \
  --object-key vault.sync.json \
  --vault "$vault" \
  --state "$sync_state" \
  --device-id native-smoke | grep -q "revision=1 uploaded=true"
grep -q 'Second Local Entry' "$remote_store"

"$bin" init "$password" --vault "$second_vault" >/dev/null
"$bin" sync "$password" \
  --provider webdav \
  --endpoint "$sync_url" \
  --object-key vault.sync.json \
  --vault "$second_vault" \
  --state "$second_sync_state" \
  --device-id second-native-smoke | grep -q "appliedRemote=true"
"$bin" list "$password" --vault "$second_vault" --query "Second Local Entry" | grep -q "matches=1"

"$bin" export-snapshot "$password" --vault "$second_vault" --out "$display_fixture" >/dev/null
python3 - "$display_fixture" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    snapshot = json.load(handle)

snapshot["entries"] = [
    {
        "id": "display-source-id",
        "label": "Display Source",
        "type": "service",
        "username": "source-user",
        "secret": "source-secret",
        "category": "Servers",
        "tags": [],
        "notes": "",
        "customFields": [
            {"id": "field-text", "templateFieldId": "template_text", "name": "Notes", "value": "visible-text"},
            {"id": "field-resolved", "templateFieldId": "template_resolved", "name": "Resolved Owner", "value": "raw-resolved-target-id"},
            {"id": "field-empty", "templateFieldId": "template_empty", "name": "Empty Owner", "value": ""},
            {"id": "field-missing", "templateFieldId": "template_missing", "name": "Missing Owner", "value": "raw-missing-target-id"},
            {"id": "field-deleted", "templateFieldId": "template_deleted", "name": "Deleted Owner", "value": "raw-deleted-target-id"},
            {"id": "field-mismatch", "templateFieldId": "template_mismatch", "name": "Mismatched Owner", "value": "raw-mismatched-target-id"},
            {"id": "field-future", "templateFieldId": "template_future", "name": "Future Owner", "value": "raw-unknown-value"},
            {"id": "field-orphan", "templateFieldId": "missing-template", "name": "Orphan Owner", "value": "raw-orphan-value"},
            {"id": "field-ad-hoc", "templateFieldId": "", "name": "Region", "value": "visible-ad-hoc"},
        ],
    },
    {
        "id": "raw-resolved-target-id",
        "label": "Resolved Account",
        "type": "credential",
        "username": "target-user",
        "secret": "target-secret",
        "category": "Accounts",
        "customFields": [{"id": "target-field", "name": "Private", "value": "target-custom-secret"}],
    },
    {
        "id": "raw-deleted-target-id",
        "label": "Deleted Account",
        "type": "credential",
        "secret": "deleted-target-secret",
        "category": "Accounts",
        "isDeleted": True,
    },
    {
        "id": "raw-mismatched-target-id",
        "label": "Archived Account",
        "type": "credential",
        "secret": "mismatched-target-secret",
        "category": "Archive",
    },
]
snapshot["categories"] = ["Accounts", "Archive", "Servers"]
snapshot["categoryTemplates"] = [{
    "category": "Servers",
    "fields": [
        {"id": "template_text", "name": "Notes", "valueType": "text", "targetCategory": ""},
        {"id": "template_resolved", "name": "Resolved Owner", "valueType": "entryReference", "targetCategory": "Accounts"},
        {"id": "template_empty", "name": "Empty Owner", "valueType": "entryReference", "targetCategory": "Accounts"},
        {"id": "template_missing", "name": "Missing Owner", "valueType": "entryReference", "targetCategory": "Accounts"},
        {"id": "template_deleted", "name": "Deleted Owner", "valueType": "entryReference", "targetCategory": "Accounts"},
        {"id": "template_mismatch", "name": "Mismatched Owner", "valueType": "entryReference", "targetCategory": "Accounts"},
        {"id": "template_future", "name": "Future Owner", "valueType": "futureLink", "targetCategory": "Accounts"},
    ],
}]

with open(path, "w", encoding="utf-8") as handle:
    json.dump(snapshot, handle, ensure_ascii=False)
PY
"$bin" import-snapshot "$password" --vault "$second_vault" --in "$display_fixture" >/dev/null
"$bin" show-entry "$password" display-source-id --vault "$second_vault" >"$display_output"
"$bin" show-entry "$password" display-source-id --show-secret --vault "$second_vault" >"$display_secret_output"
python3 - "$display_output" "$display_secret_output" <<'PY'
import json
import sys

expected = {
    "Notes": "visible-text",
    "Resolved Owner": "resolved: Resolved Account - Accounts",
    "Empty Owner": "empty",
    "Missing Owner": "missing",
    "Deleted Owner": "deleted",
    "Mismatched Owner": "categoryMismatch",
    "Future Owner": "",
    "Orphan Owner": "",
    "Region": "visible-ad-hoc",
}
for path in sys.argv[1:]:
    with open(path, "r", encoding="utf-8") as handle:
        output = json.load(handle)
    fields = {field["name"]: field["value"] for field in output["entries"][0]["customFields"]}
    assert fields == expected
    raw = json.dumps(output, ensure_ascii=False)
    for forbidden in (
        "raw-resolved-target-id",
        "raw-missing-target-id",
        "raw-deleted-target-id",
        "raw-mismatched-target-id",
        "raw-unknown-value",
        "raw-orphan-value",
        "target-secret",
        "target-custom-secret",
        "deleted-target-secret",
        "mismatched-target-secret",
    ):
        assert forbidden not in raw
PY
"$bin" list "$password" --vault "$second_vault" --query "raw-unknown-value" | grep -q "matches=0"
"$bin" list "$password" --vault "$second_vault" --query "raw-orphan-value" | grep -q "matches=0"
"$bin" list "$password" --vault "$second_vault" --query "raw-missing-target-id" | grep -q "matches=0"
"$bin" list "$password" --vault "$second_vault" --query "Resolved Account" | grep -q "display-source-id"
"$bin" export-snapshot "$password" --vault "$second_vault" --out "$display_export" >/dev/null
python3 - "$display_export" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    snapshot = json.load(handle)
source = next(entry for entry in snapshot["entries"] if entry["id"] == "display-source-id")
values = {field["name"]: field["value"] for field in source["customFields"]}
assert values["Resolved Owner"] == "raw-resolved-target-id"
assert values["Missing Owner"] == "raw-missing-target-id"
assert values["Deleted Owner"] == "raw-deleted-target-id"
assert values["Mismatched Owner"] == "raw-mismatched-target-id"
assert values["Future Owner"] == "raw-unknown-value"
assert values["Orphan Owner"] == "raw-orphan-value"
PY

"$bin" backup "$password" --vault "$vault" --backup-dir "$backup_dir" | grep -q "Backup saved:"
"$bin" list-backups --vault "$vault" --backup-dir "$backup_dir" | grep -q "backups=1"
backup_name="$("$bin" list-backups --vault "$vault" --backup-dir "$backup_dir" | awk 'NR == 2 { print $1 }')"
test -n "$backup_name"
"$bin" export-snapshot "$password" --vault "$vault" --out "$export_file" >/dev/null
grep -q '"entries"' "$export_file"
grep -q 'Smoke Entry' "$export_file"

"$bin" add-category "$password" Temporary --vault "$vault" >/dev/null
"$bin" status "$password" --vault "$vault" | grep -q "categories=3"
"$bin" import-snapshot "$password" --vault "$vault" --in "$export_file" | grep -q "Imported 2 active entries."
"$bin" status "$password" --vault "$vault" | grep -q "categories=2"

"$bin" add-category "$password" RestoreMarker --vault "$vault" >/dev/null
"$bin" status "$password" --vault "$vault" | grep -q "categories=3"
"$bin" restore-backup "$password" "$backup_name" --vault "$vault" --backup-dir "$backup_dir" | grep -q "Restored backup:"
"$bin" status "$password" --vault "$vault" | grep -q "categories=2"

totp_vault="$work_dir/totp-vault.envelope"
totp_restore_target="$work_dir/totp-restore-target.envelope"
totp_export="$work_dir/totp-export.json"
totp_error="$work_dir/totp-error.txt"
totp_backup_dir="$work_dir/totp-backups"
totp_secret="GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
"$bin" init "$password" --vault "$totp_vault" >/dev/null
"$bin" export-snapshot "$password" --vault "$totp_vault" --out "$totp_export" >/dev/null
python3 - "$totp_export" "$totp_secret" <<'PY'
import json
import sys

path, secret = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    snapshot = json.load(handle)

snapshot["security"] = {"requireTotp": True, "totpSecret": secret}

with open(path, "w", encoding="utf-8") as handle:
    json.dump(snapshot, handle, ensure_ascii=False)
PY
"$bin" import-snapshot "$password" --vault "$totp_vault" --in "$totp_export" | grep -q "Imported 0 active entries."
if "$bin" status "$password" --vault "$totp_vault" >"$work_dir/totp-status.txt" 2>"$totp_error"; then
  echo "TOTP-protected vault unlocked without a code" >&2
  exit 1
fi
grep -q "TOTP code is required" "$totp_error"
if "$bin" status "$password" --vault "$totp_vault" --totp-code 000000 >"$work_dir/totp-status.txt" 2>"$totp_error"; then
  echo "TOTP-protected vault unlocked with an invalid code" >&2
  exit 1
fi
grep -q "TOTP code is invalid" "$totp_error"
totp_code="$("$bin" totp "$totp_secret" "$(date +%s)")"
"$bin" status "$password" --vault "$totp_vault" --totp-code "$totp_code" | grep -q "entries=0"
printf '%s\n%s\n' "$password" "$totp_code" | "$bin" status --password-stdin --totp-stdin --vault "$totp_vault" | grep -q "entries=0"
printf '%s\n%s\n' "$password" "$totp_code" | "$bin" status --totp-stdin --password-stdin --vault "$totp_vault" | grep -q "entries=0"
"$bin" backup "$password" --vault "$totp_vault" --backup-dir "$totp_backup_dir" --totp-code "$totp_code" | grep -q "Backup saved:"
totp_backup_name="$("$bin" list-backups --vault "$totp_vault" --backup-dir "$totp_backup_dir" | awk 'NR == 2 { print $1 }')"
test -n "$totp_backup_name"
"$bin" init "$password" --vault "$totp_restore_target" >/dev/null
if "$bin" restore-backup "$password" "$totp_backup_name" --vault "$totp_restore_target" --backup-dir "$totp_backup_dir" >"$work_dir/totp-restore.txt" 2>"$totp_error"; then
  echo "TOTP-protected backup restored without a code" >&2
  exit 1
fi
grep -q "TOTP code is required" "$totp_error"
"$bin" restore-backup "$password" "$totp_backup_name" --vault "$totp_restore_target" --backup-dir "$totp_backup_dir" --totp-code "$totp_code" | grep -q "Restored backup:"
