#!/usr/bin/env bash
# Prove the mini03 backup replica is usable (docs/dr/mini03.md, "Restore from the replica").
#
#   replica-restore-drill.sh --check            look only: tools, cluster, secret, replica pod. Changes nothing.
#   replica-restore-drill.sh --live CONTEXT     run the drill
#
# What it proves, read-only against the production data:
#   A. COMPARE  every bucket on the replica against the primary (object count and bytes), and every Velero
#               backup the primary has had for more than 26 hours exists on the replica (velero-backup.json).
#   B. RESTORE  the Vaultwarden database is restored from the replica's `litestream` bucket into an empty
#               volume in a SCRATCH namespace (litestream restore), then `PRAGMA integrity_check` and a count
#               of the tables are run on it.
#
# Why not `velero restore --from-backup` against the replica: Velero names a Backup object after the backup;
# the replica holds the same names as the primary, so a second BackupStorageLocation would be skipped by
# Velero's sync ("exists with a different storage location") and the restore would silently read the
# PRIMARY. Restoring the data straight from the replica's buckets is the honest test.
#
# Safety
#   * the primary is only read (mc du/find/stat as the read-only user replica-reader)
#   * the replica is only read here, through the replica-writer login that the mirror already uses
#   * production namespaces are never written: the only objects created are the scratch namespace
#     `replica-drill`, one Secret, one ConfigMap and one Pod in it; all removed at the end
#   * refuses unless the typed context equals the current one; refuses if the scratch namespace exists
#   * the logins are read from Secret velero/backup-replica-mirror at run time; nothing is printed, written to
#     disk (apart from a temp dir removed on exit) or put on a command line
#   * prints counts, sizes and PASS/FAIL only, never object names or values
#
# Exit: 0 DRILL PASS, 1 DRILL FAIL, 3 refused (context), 4 refused (scratch namespace exists),
#       5 precondition (tool missing, cluster/replica not ready).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/dr/common.sh
source "$here/common.sh"
# shellcheck source=/dev/null
source "$here/images.env"

mode=""
live_ctx=""
check_only=0
scratch="replica-drill"
ns=velero
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) check_only=1; shift ;;
    --live) mode=live; live_ctx="${2:-}"; shift 2 || shift ;;
    *) dr_die 1 "usage: replica-restore-drill.sh --check | --live CONTEXT" ;;
  esac
done
if [[ "$check_only" -eq 1 && -z "$mode" ]]; then
  mode=live
  live_ctx="$(kubectl config current-context 2>/dev/null || true)"
fi

dr_need kubectl mc curl base64
dr_guard_context "$mode" "$live_ctx"
k() { kubectl "$@"; }

echo "== checks"
k -n "$ns" get secret backup-replica-mirror >/dev/null 2>&1 || dr_die 5 "Secret $ns/backup-replica-mirror not found"
ready="$(k -n "$ns" get deploy minio-replica -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
[[ "${ready:-0}" -ge 1 ]] || dr_die 5 "Deployment minio-replica is not ready"
k -n "$ns" get svc velero-backup-target velero-backup-replica >/dev/null 2>&1 || dr_die 5 "replica or primary Service missing"
if k get namespace "$scratch" >/dev/null 2>&1; then
  dr_die 4 "refused: namespace $scratch already exists; delete it first"
fi
echo "   tools, cluster, Secret and the replica pod are in place; $scratch does not exist"
if [[ "$check_only" -eq 1 ]]; then
  echo "check only: nothing changed"
  exit 0
fi

tmp="$(mktemp -d)"
pf_pids=()
created=0
# shellcheck disable=SC2329,SC2317
cleanup() {
  for p in "${pf_pids[@]:-}"; do
    if [[ -n "$p" ]]; then kill "$p" 2>/dev/null || true; fi
  done
  if [[ "$created" -eq 1 ]]; then
    k delete namespace "$scratch" --wait=false >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
  unset MC_HOST_pri MC_HOST_rep src_pri src_rep 2>/dev/null || true
}
trap cleanup EXIT

# Logins: the in-cluster URLs sealed in backup-replica-mirror; rewritten to the local port-forwards.
read_key() { k -n "$ns" get secret backup-replica-mirror -o "jsonpath={.data.$1}" | base64 -d; }
src_pri="$(read_key MC_HOST_primary)"
src_rep="$(read_key MC_HOST_replica)"
[[ -n "$src_pri" && -n "$src_rep" ]] || dr_die 5 "the mirror Secret is missing a key"

k -n "$ns" port-forward svc/velero-backup-target 19000:9000 >/dev/null 2>&1 &
pf_pids+=("$!")
k -n "$ns" port-forward svc/velero-backup-replica 19001:9000 >/dev/null 2>&1 &
pf_pids+=("$!")
for port in 19000 19001; do
  ok=0
  for _ in $(seq 1 30); do
    if curl -fsS "http://localhost:$port/minio/health/live" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 1
  done
  [[ "$ok" -eq 1 ]] || dr_die 5 "MinIO on port $port did not answer"
done
export MC_CONFIG_DIR="$tmp/mc"
export MC_HOST_pri="${src_pri/@velero-backup-target.${ns}.svc.cluster.local:9000/@localhost:19000}"
export MC_HOST_rep="${src_rep/@velero-backup-replica.${ns}.svc.cluster.local:9000/@localhost:19001}"

fail=0

echo "== A. compare replica with primary"
for b in velero-backups litestream immich-pg; do
  p_json="$(mc du --json "pri/$b" 2>/dev/null || true)"
  r_json="$(mc du --json "rep/$b" 2>/dev/null || true)"
  p_obj="$(sed -n 's/.*"objects":\([0-9]*\).*/\1/p' <<<"$p_json" | head -n1)"
  r_obj="$(sed -n 's/.*"objects":\([0-9]*\).*/\1/p' <<<"$r_json" | head -n1)"
  p_size="$(sed -n 's/.*"size":\([0-9]*\).*/\1/p' <<<"$p_json" | head -n1)"
  r_size="$(sed -n 's/.*"size":\([0-9]*\).*/\1/p' <<<"$r_json" | head -n1)"
  if [[ -z "$p_obj" || -z "$r_obj" || -z "$p_size" || -z "$r_size" ]]; then
    echo "   FAIL $b: could not read sizes"
    fail=1
    continue
  fi
  # The primary keeps changing between mirror runs, so allow the replica to trail by 10%.
  if [[ "$r_obj" -gt 0 && $((r_size * 10)) -ge $((p_size * 9)) ]]; then
    echo "   PASS $b: replica $r_obj objects / $r_size bytes, primary $p_obj / $p_size"
  else
    echo "   FAIL $b: replica $r_obj objects / $r_size bytes, primary $p_obj / $p_size"
    fail=1
  fi
done
missing=0
checked=0
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  checked=$((checked + 1))
  rel="${line#pri/}"
  mc stat "rep/$rel" >/dev/null 2>&1 || missing=$((missing + 1))
done < <(mc find pri/velero-backups/backups --name velero-backup.json --older-than 26h 2>/dev/null || true)
if [[ "$checked" -gt 0 && "$missing" -eq 0 ]]; then
  echo "   PASS all $checked Velero backups older than 26 h are on the replica"
else
  echo "   FAIL Velero backups: checked $checked, missing on the replica $missing"
  fail=1
fi

echo "== B. restore Vaultwarden from the replica into $scratch"
k create namespace "$scratch" >/dev/null
created=1
# The mirror login for the replica carries user and password; litestream gets them as env.
rep_creds="${src_rep#http://}"
rep_creds="${rep_creds%%@*}"
rep_user="${rep_creds%%:*}"
rep_pass="${rep_creds#*:}"
k -n "$scratch" create secret generic replica-drill-s3 \
  --from-literal=access-key-id="$rep_user" --from-literal=secret-access-key="$rep_pass" >/dev/null
unset rep_creds rep_user rep_pass
k -n "$scratch" apply -f - >/dev/null <<EOT
apiVersion: v1
kind: ConfigMap
metadata: { name: replica-drill-litestream }
data:
  litestream.yml: |
    dbs:
      - path: /data/db.sqlite3
        replicas:
          - type: s3
            bucket: litestream
            path: vaultwarden
            endpoint: http://velero-backup-replica.${ns}.svc.cluster.local:9000
            force-path-style: true
---
apiVersion: v1
kind: Pod
metadata: { name: replica-drill-restore }
spec:
  restartPolicy: Never
  nodeSelector: { kubernetes.io/hostname: mini03 }
  tolerations:
    - { key: node-role.homeserver/tier, operator: Equal, value: mobile, effect: NoSchedule }
  initContainers:
    - name: restore
      image: ${LITESTREAM_IMAGE_REPO}@${LITESTREAM_IMAGE_DIGEST}
      args: ["restore", "-config", "/etc/litestream.yml", "/data/db.sqlite3"]
      env:
        - name: LITESTREAM_ACCESS_KEY_ID
          valueFrom: { secretKeyRef: { name: replica-drill-s3, key: access-key-id } }
        - name: LITESTREAM_SECRET_ACCESS_KEY
          valueFrom: { secretKeyRef: { name: replica-drill-s3, key: secret-access-key } }
      volumeMounts:
        - { name: data, mountPath: /data }
        - { name: cfg, mountPath: /etc/litestream.yml, subPath: litestream.yml }
  containers:
    - name: check
      image: ${DRILL_IMAGE_REPO}:${DRILL_IMAGE_TAG}
      command: ["sh", "-c"]
      args:
        - |
          apk add --no-cache sqlite >/dev/null 2>&1
          cp /data/db.sqlite3 /tmp/d.db
          echo "SQLITE=\$(sqlite3 /tmp/d.db 'PRAGMA integrity_check;' | head -n1)"
          echo "TABLES=\$(sqlite3 /tmp/d.db "select count(*) from sqlite_master where type='table';")"
          echo "BYTES=\$(wc -c < /data/db.sqlite3)"
      volumeMounts: [{ name: data, mountPath: /data, readOnly: true }]
  volumes:
    - { name: data, emptyDir: {} }
    - { name: cfg, configMap: { name: replica-drill-litestream } }
EOT
if k -n "$scratch" wait --for=jsonpath='{.status.phase}'=Succeeded pod/replica-drill-restore --timeout=300s >/dev/null 2>&1; then
  out="$(k -n "$scratch" logs replica-drill-restore -c check 2>/dev/null || true)"
  s="$(sed -n 's/^SQLITE=//p' <<<"$out" | head -n1)"
  t="$(sed -n 's/^TABLES=//p' <<<"$out" | head -n1)"
  b="$(sed -n 's/^BYTES=//p' <<<"$out" | head -n1)"
  if [[ "$s" == "ok" && "${t:-0}" -gt 0 && "${b:-0}" -gt 0 ]]; then
    echo "   PASS database restored from the replica: integrity_check ok, $t tables, $b bytes"
  else
    echo "   FAIL restored database: integrity_check '${s:-none}', tables ${t:-0}, bytes ${b:-0}"
    fail=1
  fi
else
  echo "   FAIL the restore pod did not finish (kubectl -n $scratch describe pod replica-drill-restore)"
  fail=1
fi

echo "== cleanup"
if k delete namespace "$scratch" --wait=false >/dev/null 2>&1; then
  created=0
  echo "   namespace $scratch deleted"
fi

if [[ "$fail" -eq 0 ]]; then
  echo "DRILL PASS"
  exit 0
fi
echo "DRILL FAIL"
exit 1
