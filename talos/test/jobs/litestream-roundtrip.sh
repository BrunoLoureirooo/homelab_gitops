#!/usr/bin/env bash
# talos-job: kvm=yes timeout=45
# Plan 15-06 Task 3: Litestream replicates Vaultwarden's SQLite database to S3, and an EMPTY
# volume is rebuilt from the replica by the init container.
#
# The Deployment is rendered from the real chart and BOTH values files (the repo's and the
# Talos override), so what runs here is what Argo CD would deploy. Rows are written with
# sqlite3 from a throwaway pod on the same volume (Vaultwarden's alpine image has no sqlite3
# CLI; an API signup needs client-side crypto).
#
# Report line: LITESTREAM roundtrip PASS|FAIL JOURNAL_MODE=<mode> LAG_S=<n>
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
# shellcheck source=/dev/null
source "$repo/talos/test/lib.sh"
# shellcheck source=talos/test/backup-lib.sh
source "$here/../backup-lib.sh"

trap 'bk_cleanup_all; talos_ci_down talos-ci >/dev/null 2>&1 || true' EXIT

drill_image="$(bk_image_ref "$DRILL_IMAGE_REPO" "$DRILL_IMAGE_TAG" "$DRILL_IMAGE_DIGEST")"

bk_minio_start
talos_ci_up talos-ci
bk_storage
bk_ns homeserver privileged

# ---- secrets the Pod references (throwaway) and the claim ---------------------------------------
kubectl -n homeserver create secret generic vaultwarden-admin --from-literal=token="$(bk_random 32)" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n homeserver create secret generic litestream-s3 \
  --from-literal=access-key-id="$BK_ACCESS" --from-literal=secret-access-key="$BK_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

make_pvc() {
  kubectl -n homeserver apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: vaultwarden-pvc }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
EOF
}
make_pvc

# ---- render and apply the Deployment exactly as Argo CD would ----------------------------------------
helm repo add bjws https://bjw-s-labs.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update bjws >/dev/null
helm template vaultwarden bjws/app-template --version 5.2.1 --namespace homeserver \
  -f "$repo/argocd/values/vaultwarden.yaml" -f "$repo/talos/values/vaultwarden.yaml" \
  --set controllers.vaultwarden.containers.litestream.env.LITESTREAM_ENDPOINT="$BK_S3_GUEST" \
  --set controllers.vaultwarden.initContainers.litestream-restore.env.LITESTREAM_ENDPOINT="$BK_S3_GUEST" \
  >"${TAL_WORK:-${RUNNER_TEMP:-/tmp}}/vw-rendered.yaml"
yq -e 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "litestream")' \
  "${TAL_WORK:-${RUNNER_TEMP:-/tmp}}/vw-rendered.yaml" >/dev/null
yq 'select(.kind == "Deployment" or .kind == "ConfigMap" or .kind == "Service" or .kind == "ServiceAccount")' \
  "${TAL_WORK:-${RUNNER_TEMP:-/tmp}}/vw-rendered.yaml" | kubectl -n homeserver apply -f - >/dev/null
if ! kubectl -n homeserver rollout status deploy/vaultwarden --timeout=300s >/dev/null; then
  echo "--- vaultwarden did not roll out: pods and recent events"
  kubectl -n homeserver get pods -o wide 2>&1 | tail -n 10
  kubectl -n homeserver describe pod -l app.kubernetes.io/name=vaultwarden 2>&1 | tail -n 40
  kubectl -n homeserver get events --sort-by=.lastTimestamp 2>&1 | tail -n 15
  for c in litestream-restore litestream main; do
    echo "--- logs: $c"
    kubectl -n homeserver logs deploy/vaultwarden -c "$c" --tail=15 2>&1 | tail -n 15
  done
  echo "::error::vaultwarden did not roll out"; exit 1
fi

# sqlite_pod NAME SCRIPT: a throwaway pod on the same claim that runs SCRIPT and prints its output.
sqlite_run() {
  local pod="sq-$RANDOM" script="$1" out
  kubectl -n homeserver apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: { name: $pod }
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: $drill_image
      command: ["sh", "-c", "apk add --no-cache sqlite >/dev/null 2>&1; $script"]
      volumeMounts: [{ name: d, mountPath: /data }]
  volumes:
    - name: d
      persistentVolumeClaim: { claimName: vaultwarden-pvc }
EOF
  kubectl -n homeserver wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" --timeout=180s >/dev/null
  out="$(kubectl -n homeserver logs "$pod")"
  kubectl -n homeserver delete pod "$pod" --wait=false >/dev/null 2>&1 || true
  printf '%s\n' "$out"
}

# Wait for Vaultwarden to have created and migrated its own database.
for _ in $(seq 1 60); do
  mode="$(sqlite_run "test -f /data/db.sqlite3 && sqlite3 /data/db.sqlite3 'PRAGMA journal_mode;' || echo missing" | tail -n1)"
  [[ "$mode" != "missing" ]] && break
  sleep 5
done
tal_report "JOURNAL_MODE=${mode}"
if [[ "$mode" != "wal" ]]; then
  tal_report "LITESTREAM roundtrip FAIL JOURNAL_MODE=${mode}"
  echo "::error::Vaultwarden's database is in journal mode '${mode}', Litestream needs wal; do not trust Litestream for this image"
  exit 1
fi

# ---- write rows, measure the replica lag ---------------------------------------------------------------
sqlite_run "sqlite3 /data/db.sqlite3 'create table if not exists ci_rows(i integer primary key, v text); begin; with recursive c(i) as (select 1 union all select i+1 from c where i<500) insert into ci_rows select i, hex(randomblob(8)) from c; commit;'" >/dev/null
before="$(bk_mc ls --recursive ci/litestream/vaultwarden | wc -l | tr -d ' ')"
start="$SECONDS"
sqlite_run "sqlite3 /data/db.sqlite3 \"insert into ci_rows(i,v) values (501,'last-committed-row');\"" >/dev/null
lag=-1
for _ in $(seq 1 60); do
  after="$(bk_mc ls --recursive ci/litestream/vaultwarden | wc -l | tr -d ' ')"
  if [[ "$after" -gt "$before" ]]; then
    lag=$((SECONDS - start))
    break
  fi
  sleep 1
done
if [[ "$lag" -lt 0 || "$lag" -gt 10 ]]; then
  tal_report "LITESTREAM roundtrip FAIL JOURNAL_MODE=${mode} LAG_S=${lag}"
  kubectl -n homeserver logs deploy/vaultwarden -c litestream --tail=40 || true
  exit 1
fi

# ---- lose the Pod AND the claim, then recreate both ---------------------------------------------------
kubectl -n homeserver scale deploy/vaultwarden --replicas=0 >/dev/null
kubectl -n homeserver wait --for=delete pod -l app.kubernetes.io/name=vaultwarden --timeout=120s >/dev/null 2>&1 || true
kubectl -n homeserver delete pvc vaultwarden-pvc --wait=true >/dev/null
make_pvc
kubectl -n homeserver scale deploy/vaultwarden --replicas=1 >/dev/null
kubectl -n homeserver rollout status deploy/vaultwarden --timeout=300s >/dev/null

res="$(sqlite_run "sqlite3 /data/db.sqlite3 \"PRAGMA integrity_check;\"; sqlite3 /data/db.sqlite3 'PRAGMA journal_mode;'; sqlite3 /data/db.sqlite3 \"select v from ci_rows where i=501;\"")"
integrity="$(sed -n '1p' <<<"$res")"
mode2="$(sed -n '2p' <<<"$res")"
last="$(sed -n '3p' <<<"$res")"
if [[ "$integrity" == "ok" && "$mode2" == "wal" && "$last" == "last-committed-row" ]]; then
  tal_report "LITESTREAM roundtrip PASS JOURNAL_MODE=${mode2} LAG_S=${lag}"
  tal_finding LITESTREAM-VW PASS "replica rebuilt an empty volume; lag ${lag}s"
else
  tal_report "LITESTREAM roundtrip FAIL JOURNAL_MODE=${mode2} integrity=${integrity} last=${last}"
  kubectl -n homeserver logs deploy/vaultwarden -c litestream-restore --tail=40 || true
  exit 1
fi
