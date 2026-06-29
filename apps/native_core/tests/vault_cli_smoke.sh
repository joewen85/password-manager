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
