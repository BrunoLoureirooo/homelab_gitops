#!/usr/bin/env bash
# talos-job: kvm=yes timeout=75 heavy=yes
# Plan 15-06 Task 1: Velero on a Talos CI cluster. Back up three volume shapes, destroy the
# WHOLE cluster, bring up a new one against the same external MinIO, restore into a scratch
# namespace, compare checksums. Also proves the `!cnpg.io/cluster` selector plan 15-07 uses.
#
# Report lines: VELERO talos roundtrip PASS|FAIL, DRILL PASS|FAIL, SQLITE integrity_check ok,
# PVB_COUNT, SCHEDULE_HOURLY, SELECTOR_CNPG_EXCLUDED.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
# shellcheck source=/dev/null
source "$repo/talos/test/lib.sh"
# shellcheck source=talos/test/backup-lib.sh
source "$here/../backup-lib.sh"

trap 'bk_cleanup_all; talos_ci_down talos-ci >/dev/null 2>&1 || true' EXIT

bk_minio_start
bk_install_velero_cli

# ---- cluster A: create data, back it up ---------------------------------------------------------
talos_ci_up talos-ci
bk_storage
bk_ns homeserver privileged
bk_helm_install_velero
bk_wait_backup_location

# The scripts below run inside the workload Pods, so $-expressions must stay unexpanded here.
# shellcheck disable=SC2016
vw='apk add --no-cache sqlite >/dev/null; sqlite3 /data/db.sqlite3 "PRAGMA journal_mode=WAL; create table t(i integer primary key, v text); with recursive c(i) as (select 1 union all select i+1 from c where i<1000) insert into t select i, hex(randomblob(16)) from c;"'
# shellcheck disable=SC2016
bot='mkdir -p /data/wa-auth; for i in 1 2 3 4 5; do head -c 8192 /dev/urandom > /data/wa-auth/k$i; done; echo "{}" > /data/state.json'
# shellcheck disable=SC2016
lib='for d in a b c; do mkdir -p /data/$d/x/y; for i in 1 2 3 4 5 6 7 8 9 10; do dd if=/dev/urandom of=/data/$d/x/y/f$i bs=1M count=10 2>/dev/null; done; done'

bk_make_workload vw-like vw-pvc 1Gi "$vw"
bk_make_workload bot-like bot-pvc 100Mi "$bot"
bk_make_workload lib-like lib-pvc 1Gi "$lib"
# A volume labelled like the CNPG one: the selector test must leave it out.
bk_make_workload cnpg-like cnpg-pvc 100Mi 'echo cnpg > /data/marker'
kubectl -n homeserver label pvc/cnpg-pvc pod/cnpg-like cnpg.io/cluster=immich-pg --overwrite >/dev/null

for p in vw-like bot-like lib-like cnpg-like; do bk_wait_ready_file "$p"; done

sum_vw="$(bk_sha_listing homeserver vw-pvc)"
sum_bot="$(bk_sha_listing homeserver bot-pvc)"
sum_lib="$(bk_sha_listing homeserver lib-pvc)"
rows_vw="$(kubectl -n homeserver exec vw-like -- sqlite3 /data/db.sqlite3 'select count(*) from t')"
[[ "$rows_vw" == "1000" ]] || {
  echo "::error::vw-like row count $rows_vw"
  exit 1
}

velero backup create rt-1 --include-namespaces homeserver --wait >/dev/null
phase="$(kubectl -n velero get backup rt-1 -o jsonpath='{.status.phase}')"
pvb_total="$(kubectl -n velero get podvolumebackups -o json | jq '.items | length')"
pvb_ok="$(kubectl -n velero get podvolumebackups -o json | jq '[.items[] | select(.status.phase=="Completed")] | length')"
tal_report "PVB_COUNT=${pvb_total}"
if [[ "$phase" != "Completed" || "$pvb_total" -lt 4 || "$pvb_total" != "$pvb_ok" ]]; then
  # On Talos this is where a node-agent failure shows (it reads /var/lib/kubelet/pods).
  echo "::error::backup phase=${phase} podvolumebackups=${pvb_ok}/${pvb_total}"
  kubectl -n velero logs ds/node-agent --tail=60 || true
  tal_report "VELERO talos roundtrip FAIL"
  exit 1
fi

if velero schedule get homeserver-hourly >/dev/null 2>&1; then
  tal_report "SCHEDULE_HOURLY=present"
else
  tal_report "SCHEDULE_HOURLY=missing"
  exit 1
fi

# ---- destroy cluster A entirely ----------------------------------------------------------------
talos_ci_down talos-ci

# ---- cluster B: new cluster, same MinIO ---------------------------------------------------------
talos_ci_up talos-ci
bk_storage
bk_helm_install_velero
bk_wait_backup_location
for _ in $(seq 1 60); do
  velero backup get rt-1 >/dev/null 2>&1 && break
  sleep 5
done
velero backup get rt-1 >/dev/null

drill_out="$(bash "$repo/talos/dr/velero-restore-drill.sh" --backup rt-1 --ci \
  --pvc vw-pvc --pvc bot-pvc --pvc lib-pvc --sqlite db.sqlite3 --selector '!cnpg.io/cluster' 2>&1)" || true
echo "$drill_out"
if grep -q '^DRILL PASS$' <<<"$drill_out"; then
  tal_report "DRILL PASS"
else
  tal_report "DRILL FAIL"
  exit 1
fi
if grep -q 'SQLITE integrity_check ok' <<<"$drill_out"; then
  tal_report "SQLITE integrity_check ok"
else
  tal_report "SQLITE integrity_check FAIL"
  exit 1
fi

# The CNPG-labelled volume must NOT have come back; the other three must have.
if kubectl -n restore-drill get pvc cnpg-pvc >/dev/null 2>&1; then
  tal_report "SELECTOR_CNPG_EXCLUDED=no"
  echo "::error::selector '!cnpg.io/cluster' did not exclude the labelled volume (use a label-matching alternative and update plan 15-07 step 12)"
  exit 1
fi
tal_report "SELECTOR_CNPG_EXCLUDED=yes"

[[ "$(bk_sha_listing restore-drill vw-pvc)" == "$sum_vw" ]] || {
  tal_report "VELERO talos roundtrip FAIL vw checksum"
  exit 1
}
[[ "$(bk_sha_listing restore-drill bot-pvc)" == "$sum_bot" ]] || {
  tal_report "VELERO talos roundtrip FAIL bot checksum"
  exit 1
}
[[ "$(bk_sha_listing restore-drill lib-pvc)" == "$sum_lib" ]] || {
  tal_report "VELERO talos roundtrip FAIL lib checksum"
  exit 1
}

tal_report "VELERO talos roundtrip PASS"
tal_finding VELERO-ROUNDTRIP PASS "three volume shapes restored with matching checksums after losing the cluster"
