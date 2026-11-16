#!/usr/bin/env bash
# talos-job: kvm=yes timeout=45 heavy=yes
# Plan 15-06 Task 4a: the manual cutover dump (talos/dr/immich-dump.sh) restores into a fresh
# CNPG cluster with the same row count and checksum. These are the exact commands plan 15-07
# runs at cutover, against a CI cluster instead of the live one.
#
# Report line: PGDUMP restore PASS|FAIL ROWS=<n>
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
# shellcheck source=/dev/null
source "$repo/talos/test/lib.sh"
# shellcheck source=talos/test/backup-lib.sh
source "$here/../backup-lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"; bk_cleanup_all; talos_ci_down talos-ci >/dev/null 2>&1 || true' EXIT

bk_minio_start
talos_ci_up talos-ci
bk_storage
bk_ns homeserver privileged
bk_cnpg_install
bk_immich_secrets

ctx="$(kubectl config current-context)"

bk_immich_cluster_yaml immich-pg --no-backup | kubectl -n homeserver apply -f - >/dev/null
bk_wait_cluster immich-pg

# Seed a table shaped like Immich's main one, plus a checksum of its whole content.
bk_psql immich-pg "create table assets(id uuid primary key default gen_random_uuid(), name text, bytes bigint); insert into assets(name, bytes) select 'img-' || g, g * 1000 from generate_series(1,500) g;" >/dev/null
sum_before="$(bk_psql immich-pg "select md5(string_agg(name || ':' || bytes, ',' order by name)) from assets")"
rows_before="$(bk_psql immich-pg "select count(*) from assets")"

# The dump script as plan 15-07 runs it.
dump_out="$(bash "$repo/talos/dr/immich-dump.sh" --context "$ctx" --out "$work/immich.dump")"
echo "$dump_out"
grep -q '^DUMP size=[0-9]* sha256=[0-9a-f]\{64\}$' <<<"$dump_out"

# Lose the cluster and its volume, start a fresh one.
kubectl -n homeserver delete cluster immich-pg --wait=true >/dev/null
bk_immich_cluster_yaml immich-pg --no-backup | kubectl -n homeserver apply -f - >/dev/null
bk_wait_cluster immich-pg

restore_out="$(bash "$repo/talos/dr/immich-restore.sh" --dump "$work/immich.dump" --context "$ctx")"
echo "$restore_out"

rows_after="$(bk_psql immich-pg "select count(*) from assets")"
sum_after="$(bk_psql immich-pg "select md5(string_agg(name || ':' || bytes, ',' order by name)) from assets")"

if [[ "$rows_before" == "500" && "$rows_after" == "500" && "$sum_before" == "$sum_after" ]]; then
  tal_report "PGDUMP restore PASS ROWS=${rows_after}"
  tal_finding PGDUMP-RESTORE PASS "dump taken from the primary restored with identical rows and checksum"
else
  tal_report "PGDUMP restore FAIL ROWS=${rows_after} before=${rows_before}"
  exit 1
fi
