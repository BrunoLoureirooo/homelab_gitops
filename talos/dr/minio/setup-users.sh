#!/usr/bin/env bash
# Create the three backup buckets and one bucket-scoped MinIO user per bucket (plan 15-06 Task 6).
#
#   setup-users.sh --alias ALIAS --out DIR
#
# ALIAS is an `mc` alias you already set to the standalone MinIO with its ROOT credentials
# (mc alias set ALIAS http://localhost:9000 ROOTUSER ROOTPASS). DIR is where the generated
# credentials are written, one mode-0600 file per bucket; it must be OUTSIDE any git work tree.
# Prints bucket and user NAMES only, never a secret.
#
# Buckets and users (user = bucket-scoped, no other access):
#   velero-backups  -> velero        litestream -> litestream
#   immich-pg       -> immich-pg
set -euo pipefail

alias_name=""
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --alias) alias_name="${2:?}"; shift 2 ;;
    --out) out="${2:?}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$alias_name" && -n "$out" ]] || {
  echo "usage: setup-users.sh --alias ALIAS --out DIR" >&2
  exit 1
}
command -v mc >/dev/null 2>&1 || {
  echo "mc is not installed" >&2
  exit 5
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmpl="$here/policy.json.tmpl"

mkdir -p "$out"
out="$(cd "$out" && pwd)"
if git -C "$out" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "refused: $out is inside a git work tree; choose a directory outside any repository" >&2
  exit 3
fi
umask 077

declare -A user_for=(
  [velero-backups]=velero
  [litestream]=litestream
  [immich-pg]=immich-pg
)

for bucket in velero-backups litestream immich-pg; do
  user="${user_for[$bucket]}"
  mc mb --ignore-existing "$alias_name/$bucket" >/dev/null
  pol="$(mktemp)"
  sed "s/@@BUCKET@@/$bucket/g" "$tmpl" >"$pol"
  mc admin policy create "$alias_name" "backup-$bucket" "$pol" >/dev/null 2>&1 ||
    mc admin policy create "$alias_name" "backup-$bucket" "$pol" --overwrite >/dev/null 2>&1 || true
  rm -f "$pol"
  secret="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
  if mc admin user info "$alias_name" "$user" >/dev/null 2>&1; then
    echo "user $user exists, keeping its credentials (delete it first to rotate)"
    continue
  fi
  mc admin user add "$alias_name" "$user" "$secret" >/dev/null
  mc admin policy attach "$alias_name" "backup-$bucket" --user "$user" >/dev/null
  printf 'ACCESS_KEY=%s\nSECRET_KEY=%s\nBUCKET=%s\n' "$user" "$secret" "$bucket" >"$out/$bucket.env"
  chmod 600 "$out/$bucket.env"
  echo "bucket $bucket ready, user $user created, credentials in $out/$bucket.env"
done
echo "done: seal each file into talos/sealed-secrets/ as docs/dr/talos-backups.md describes"
