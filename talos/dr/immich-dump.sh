#!/usr/bin/env bash
# Manual cutover dump of Immich's Postgres (plan 15-06 Task 4, used by plan 15-07).
# There is no CronJob and nothing here is wired into the live cluster: The operator runs it
# once, during the write freeze, from his own machine.
#
#   immich-dump.sh --context CONTEXT --out FILE [--namespace homeserver] [--cluster immich-pg] [--database immich]
#
# Streams `pg_dump -Fc` of the database from the CNPG primary to FILE on THIS machine
# (never into the cluster). Prints only `DUMP size=<bytes> sha256=<hash>`.
# Refuses to overwrite FILE and refuses to run without an explicit --context.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/dr/common.sh
source "$here/common.sh"

ctx=""
out=""
ns="homeserver"
cluster="immich-pg"
db="immich"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) ctx="${2:?}"; shift 2 ;;
    --out) out="${2:?}"; shift 2 ;;
    --namespace) ns="${2:?}"; shift 2 ;;
    --cluster) cluster="${2:?}"; shift 2 ;;
    --database) db="${2:?}"; shift 2 ;;
    *) dr_die 1 "unknown argument: $1" ;;
  esac
done

[[ -n "$ctx" ]] || dr_die 3 "refused: --context is required (no default, no current-context fallback)"
[[ -n "$out" ]] || dr_die 1 "usage: immich-dump.sh --context CONTEXT --out FILE"
[[ ! -e "$out" ]] || dr_die 4 "refused: $out already exists"
dr_need kubectl sha256sum

primary="$(kubectl --context "$ctx" -n "$ns" get pod -l "cnpg.io/cluster=${cluster},cnpg.io/instanceRole=primary" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$primary" ]] || dr_die 5 "no primary pod found for cluster $cluster"

tmp="${out}.partial"
rm -f "$tmp"
if ! kubectl --context "$ctx" -n "$ns" exec "$primary" -c postgres -- pg_dump -Fc -d "$db" >"$tmp"; then
  rm -f "$tmp"
  dr_die 1 "pg_dump failed"
fi
[[ -s "$tmp" ]] || {
  rm -f "$tmp"
  dr_die 1 "empty dump"
}
mv "$tmp" "$out"
size="$(wc -c <"$out" | tr -d ' ')"
sum="$(sha256sum "$out" | cut -d' ' -f1)"
echo "DUMP size=$size sha256=$sum"
