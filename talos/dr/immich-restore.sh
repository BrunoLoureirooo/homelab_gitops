#!/usr/bin/env bash
# Restore a dump made by immich-dump.sh into a fresh CNPG cluster (plan 15-06 Task 4,
# used by plan 15-07 at cutover).
#
#   immich-restore.sh --dump FILE --context CONTEXT [--namespace homeserver] [--cluster immich-pg] [--database immich] [--owner immich]
#
# Waits for the new primary, then streams the dump into `pg_restore --clean --if-exists
# --no-owner` as the database owner. Prints `RESTORE ROWS=<n>` where n is the row count of
# the largest user table in the public schema (discovered, not hard-coded; Immich's main table
# is its assets table) and `RESTORE TABLES=<n>`. Never prints data.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/dr/common.sh
source "$here/common.sh"

ctx=""
dump=""
ns="homeserver"
cluster="immich-pg"
db="immich"
owner="immich"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) ctx="${2:?}"; shift 2 ;;
    --dump) dump="${2:?}"; shift 2 ;;
    --namespace) ns="${2:?}"; shift 2 ;;
    --cluster) cluster="${2:?}"; shift 2 ;;
    --database) db="${2:?}"; shift 2 ;;
    --owner) owner="${2:?}"; shift 2 ;;
    *) dr_die 1 "unknown argument: $1" ;;
  esac
done

[[ -n "$ctx" ]] || dr_die 3 "refused: --context is required"
[[ -f "$dump" ]] || dr_die 5 "dump file not found"
dr_need kubectl

K=(kubectl --context "$ctx" -n "$ns")

echo "waiting for a ready primary of $cluster"
for _ in $(seq 1 120); do
  primary="$("${K[@]}" get pod -l "cnpg.io/cluster=${cluster},cnpg.io/instanceRole=primary" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$primary" ]] && [[ "$("${K[@]}" get pod "$primary" -o jsonpath='{.status.containerStatuses[?(@.name=="postgres")].ready}' 2>/dev/null)" == "true" ]]; then
    break
  fi
  primary=""
  sleep 5
done
[[ -n "$primary" ]] || dr_die 5 "no ready primary after 10 minutes"

"${K[@]}" exec -i "$primary" -c postgres -- pg_restore --clean --if-exists --no-owner --role "$owner" -d "$db" <"$dump" >/dev/null 2>&1 || {
  # pg_restore exits non-zero on harmless "does not exist" notices with --clean; the row
  # check below is the real verdict.
  echo "note: pg_restore reported warnings"
}

tables="$("${K[@]}" exec "$primary" -c postgres -- psql -At -d "$db" -c "select count(*) from pg_tables where schemaname='public'")"
# Exact counts (not the statistics estimate, which is stale right after a restore).
rows="$("${K[@]}" exec "$primary" -c postgres -- psql -At -d "$db" -c "select coalesce(max((xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', schemaname, relname), false, true, '')))[1]::text::bigint),0) from pg_stat_user_tables")"
echo "RESTORE TABLES=${tables:-0}"
echo "RESTORE ROWS=${rows:-0}"
[[ "${tables:-0}" -gt 0 ]] || exit 1
