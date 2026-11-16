#!/usr/bin/env bash
# talos-job: kvm=yes timeout=60 heavy=yes
# Plan 15-06 Task 4: WAL archive plus point-in-time recovery for Immich's Postgres.
#
# 1. Install the CNPG operator (the version the live cluster runs) on a Talos CI cluster.
# 2. Create the REAL immich-pg Cluster as rendered by the Talos overlay (archiving to the
#    throwaway MinIO), take a base backup, insert 100 rows, record T1, insert 100 more,
#    switch the WAL and wait until it is archived.
# 3. Create a NEW Cluster by recovery with targetTime T1 and require exactly the first 100 rows.
#
# Report line: CNPG pitr PASS|FAIL ROWS_AT_T1=<n> ROWS_ALL=<n>
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
# shellcheck source=/dev/null
source "$repo/talos/test/lib.sh"
# shellcheck source=talos/test/backup-lib.sh
source "$here/../backup-lib.sh"

trap 'bk_cleanup_all; talos_ci_down talos-ci >/dev/null 2>&1 || true' EXIT

bk_minio_start
talos_ci_up talos-ci
bk_storage
bk_ns homeserver privileged
bk_cnpg_install
bk_immich_secrets

# ---- the source cluster, from the real overlay ------------------------------------------------------
bk_immich_cluster_yaml immich-pg | kubectl -n homeserver apply -f - >/dev/null
bk_wait_cluster immich-pg

# The overlay must have produced a working archive.
for _ in $(seq 1 60); do
  [[ "$(kubectl -n homeserver get cluster immich-pg -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}')" == "True" ]] && break
  sleep 5
done
[[ "$(kubectl -n homeserver get cluster immich-pg -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}')" == "True" ]] || {
  echo "::error::ContinuousArchiving never became True"
  exit 1
}

# Base backup first (a recovery needs one that starts BEFORE the target time).
kubectl -n homeserver apply -f - >/dev/null <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: pitr-base }
spec:
  cluster: { name: immich-pg }
EOF
for _ in $(seq 1 60); do
  [[ "$(kubectl -n homeserver get backup pitr-base -o jsonpath='{.status.phase}')" == "completed" ]] && break
  sleep 5
done
[[ "$(kubectl -n homeserver get backup pitr-base -o jsonpath='{.status.phase}')" == "completed" ]] || {
  echo "::error::base backup did not complete"
  exit 1
}

bk_psql immich-pg "create table pitr(i int primary key, batch int); insert into pitr select g, 1 from generate_series(1,100) g;" >/dev/null
sleep 3
t1="$(bk_psql immich-pg "select to_char(now() at time zone 'utc','YYYY-MM-DD\"T\"HH24:MI:SS.US')||'+00:00'")"
sleep 3
bk_psql immich-pg "insert into pitr select g, 2 from generate_series(101,200) g; select pg_switch_wal();" >/dev/null
for _ in $(seq 1 60); do
  # The second batch is safe once the archiver has pushed the switched segment.
  archived="$(bk_psql immich-pg "select archived_count from pg_stat_archiver")"
  [[ "${archived:-0}" -ge 2 ]] && break
  sleep 3
done
rows_all="$(bk_psql immich-pg "select count(*) from pitr")"

# ---- recovery to T1 into a NEW cluster ----------------------------------------------------------------
{
  bk_immich_cluster_yaml immich-pg-restore --no-backup |
    yq "del(.spec.bootstrap) |
        .spec.bootstrap.recovery.source = \"origin\" |
        .spec.bootstrap.recovery.database = \"immich\" |
        .spec.bootstrap.recovery.owner = \"immich\" |
        .spec.bootstrap.recovery.secret.name = \"immich-db-creds\" |
        .spec.bootstrap.recovery.recoveryTarget.targetTime = \"${t1}\" |
        .spec.externalClusters = [{\"name\": \"origin\", \"barmanObjectStore\": {
          \"destinationPath\": \"s3://immich-pg/\", \"endpointURL\": \"${BK_S3_GUEST}\", \"serverName\": \"immich-pg\",
          \"s3Credentials\": {\"accessKeyId\": {\"name\": \"immich-pg-s3\", \"key\": \"ACCESS_KEY_ID\"},
                              \"secretAccessKey\": {\"name\": \"immich-pg-s3\", \"key\": \"ACCESS_SECRET_KEY\"}}}}]"
} | kubectl -n homeserver apply -f - >/dev/null
bk_wait_cluster immich-pg-restore

rows_t1="$(bk_psql immich-pg-restore "select count(*) from pitr")"
later="$(bk_psql immich-pg-restore "select count(*) from pitr where batch = 2")"
ident="$(bk_psql immich-pg-restore "select current_database() || '|' || (select rolname from pg_roles where oid = (select datdba from pg_database where datname = current_database()))")"

if [[ "$rows_t1" == "100" && "$later" == "0" && "$rows_all" == "200" && "$ident" == "immich|immich" ]]; then
  tal_report "CNPG pitr PASS ROWS_AT_T1=${rows_t1} ROWS_ALL=${rows_all}"
  tal_finding CNPG-PITR PASS "recovery to T1 returned exactly the first batch; database and owner are immich"
else
  tal_report "CNPG pitr FAIL ROWS_AT_T1=${rows_t1} ROWS_ALL=${rows_all} later=${later} ident=${ident}"
  kubectl -n homeserver logs -l cnpg.io/cluster=immich-pg-restore --all-containers --tail=40 || true
  exit 1
fi
