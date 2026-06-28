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
backup_dir="$work_dir/backups"
export_file="$work_dir/export.json"

rm -rf "$work_dir"
mkdir -p "$work_dir"

"$bin" init "$password" --vault "$vault" >/dev/null
"$bin" add-category "$password" Infra --shortcut server --field Owner --vault "$vault" >/dev/null
"$bin" add-entry "$password" \
  --label "Smoke Entry" \
  --type service \
  --username svc-user \
  --secret svc-secret \
  --category Infra \
  --tag smoke \
  --field Owner=Platform \
  --vault "$vault" >/dev/null

"$bin" backup "$password" --vault "$vault" --backup-dir "$backup_dir" | grep -q "Backup saved:"
"$bin" list-backups --vault "$vault" --backup-dir "$backup_dir" | grep -q "backups=1"
backup_name="$("$bin" list-backups --vault "$vault" --backup-dir "$backup_dir" | awk 'NR == 2 { print $1 }')"
test -n "$backup_name"
"$bin" export-snapshot "$password" --vault "$vault" --out "$export_file" >/dev/null
grep -q '"entries"' "$export_file"
grep -q 'Smoke Entry' "$export_file"

"$bin" add-category "$password" Temporary --vault "$vault" >/dev/null
"$bin" status "$password" --vault "$vault" | grep -q "categories=2"
"$bin" import-snapshot "$password" --vault "$vault" --in "$export_file" | grep -q "Imported 1 active entries."
"$bin" status "$password" --vault "$vault" | grep -q "categories=1"

"$bin" add-category "$password" RestoreMarker --vault "$vault" >/dev/null
"$bin" status "$password" --vault "$vault" | grep -q "categories=2"
"$bin" restore-backup "$password" "$backup_name" --vault "$vault" --backup-dir "$backup_dir" | grep -q "Restored backup:"
"$bin" status "$password" --vault "$vault" | grep -q "categories=1"

rm -rf "$work_dir"
