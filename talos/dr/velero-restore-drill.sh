#!/usr/bin/env bash
# Restore a Velero backup into a SCRATCH namespace and check the data (plan 15-06).
#
#   velero-restore-drill.sh --backup NAME (--ci | --live CONTEXT) [options]
#
# Options
#   --source-ns NS    namespace inside the backup (default homeserver)
#   --target-ns NS    scratch namespace to restore into (default restore-drill)
#   --pvc NAME        PVC to check; repeatable; default: every PVC restored into the target
#   --sqlite PATH     path inside a checked volume to run `PRAGMA integrity_check` on
#                     (for example data/db.sqlite3); repeatable
#   --selector EXPR   label selector passed to `velero restore create` (for example '!cnpg.io/cluster')
#   --cleanup         delete the scratch namespace at the end (default: leave it)
#
# Safety
#   * never touches the source namespace; restores only through a namespace mapping
#   * refuses unless the context is the Talos CI context (--ci) or the context is
#     typed back (--live CONTEXT)
#   * refuses if the scratch namespace already exists
#   * resource allow-list: workloads, claims, secrets and config only (no ingresses,
#     services or CronJobs, so nothing in the scratch namespace takes traffic or runs a job)
#   * prints only FILES, BYTES, SQLITE and the verdict, never file names or values
#
# Exit: 0 DRILL PASS, 1 DRILL FAIL, 3 refused (context), 4 refused (target exists),
#       5 precondition (backup not Completed, tool missing).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/dr/common.sh
source "$here/common.sh"
# shellcheck source=/dev/null
source "$here/images.env"

backup=""
mode=""
live_ctx=""
source_ns="homeserver"
target_ns="restore-drill"
cleanup=0
selector=""
pvcs=()
sqlites=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup) backup="${2:?}"; shift 2 ;;
    --ci) mode=ci; shift ;;
    --live) mode=live; live_ctx="${2:-}"; shift 2 || shift ;;
    --source-ns) source_ns="${2:?}"; shift 2 ;;
    --target-ns) target_ns="${2:?}"; shift 2 ;;
    --pvc) pvcs+=("${2:?}"); shift 2 ;;
    --sqlite) sqlites+=("${2:?}"); shift 2 ;;
    --selector) selector="${2:?}"; shift 2 ;;
    --cleanup) cleanup=1; shift ;;
    *) dr_die 1 "unknown argument: $1" ;;
  esac
done

[[ -n "$backup" ]] || dr_die 1 "usage: velero-restore-drill.sh --backup NAME (--ci | --live CONTEXT)"
[[ "$source_ns" != "$target_ns" ]] || dr_die 3 "refused: source and target namespace are the same"

dr_need kubectl velero
dr_guard_context "$mode" "$live_ctx"

if kubectl get namespace "$target_ns" >/dev/null 2>&1; then
  dr_die 4 "refused: namespace $target_ns already exists; delete it first"
fi

phase="$(velero backup get "$backup" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[[ "$phase" == "Completed" ]] || dr_die 5 "backup $backup is not Completed (phase: ${phase:-unknown})"

drill_image="${DRILL_IMAGE_REPO}:${DRILL_IMAGE_TAG}"
[[ -z "${DRILL_IMAGE_DIGEST:-}" ]] || drill_image="${DRILL_IMAGE_REPO}@${DRILL_IMAGE_DIGEST}"

restore_name="drill-$(date -u +%Y%m%d%H%M%S)"
echo "restoring $backup into $target_ns as $restore_name"
restore_args=(
  --from-backup "$backup"
  --namespace-mappings "${source_ns}:${target_ns}"
  --include-resources "pods,deployments,replicasets,persistentvolumeclaims,secrets,configmaps,serviceaccounts"
)
# --selector keeps objects out by label (plan 15-07 restores everything except the CNPG volume
# with '!cnpg.io/cluster').
[[ -z "$selector" ]] || restore_args+=(--selector "$selector")
velero restore create "$restore_name" "${restore_args[@]}" --wait >/dev/null

rphase="$(velero restore get "$restore_name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [[ "$rphase" != "Completed" ]]; then
  echo "SQLITE not-run"
  echo "DRILL FAIL restore phase ${rphase:-unknown}"
  exit 1
fi

# The restored workloads only existed to carry the data back (Velero fills a volume
# through an init container on the restored pod). Remove them so the checker pods can
# mount the claims without competing, and so nothing in the scratch namespace runs.
kubectl -n "$target_ns" delete deployments,replicasets,pods --all --wait=true >/dev/null 2>&1 || true

if [[ ${#pvcs[@]} -eq 0 ]]; then
  while IFS= read -r p; do
    [[ -n "$p" ]] && pvcs+=("$p")
  done < <(kubectl -n "$target_ns" get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
fi
[[ ${#pvcs[@]} -gt 0 ]] || {
  echo "SQLITE not-run"
  echo "DRILL FAIL no claims restored"
  exit 1
}

# One checker pod per claim: counts files and bytes, optionally integrity-checks SQLite.
total_files=0
total_bytes=0
sqlite_state="not-requested"
fail=0
idx=0
for pvc in "${pvcs[@]}"; do
  idx=$((idx + 1))
  pod="drill-check-$idx"
  sql_cmds=""
  for s in "${sqlites[@]:-}"; do
    [[ -n "$s" ]] || continue
    sql_cmds="${sql_cmds}if [ -f /v/$s ]; then echo \"SQLITE=\$(sqlite3 /v/$s 'PRAGMA integrity_check;' | head -n1)\"; fi; "
  done
  kubectl -n "$target_ns" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  labels: { drill/check: "true" }
spec:
  restartPolicy: Never
  containers:
    - name: check
      image: $drill_image
      command: ["sh", "-c"]
      args:
        - |
          set -e
          ${sql_cmds:+apk add --no-cache sqlite >/dev/null 2>&1}
          echo "FILES=\$(find /v -type f | wc -l)"
          echo "BYTES=\$(du -sk /v | cut -f1)000"
          ${sql_cmds}
          echo DONE
      volumeMounts: [{ name: v, mountPath: /v, readOnly: true }]
  volumes:
    - name: v
      persistentVolumeClaim: { claimName: $pvc, readOnly: true }
EOF
  if ! kubectl -n "$target_ns" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" --timeout=300s >/dev/null 2>&1; then
    fail=1
    continue
  fi
  out="$(kubectl -n "$target_ns" logs "$pod" 2>/dev/null || true)"
  f="$(sed -n 's/^FILES=//p' <<<"$out" | head -n1)"
  b="$(sed -n 's/^BYTES=//p' <<<"$out" | head -n1)"
  total_files=$((total_files + ${f:-0}))
  total_bytes=$((total_bytes + ${b:-0}))
  while IFS= read -r line; do
    r="${line#SQLITE=}"
    if [[ "$r" == "ok" ]]; then
      [[ "$sqlite_state" == "error" ]] || sqlite_state="ok"
    else
      sqlite_state="error"
      fail=1
    fi
  done < <(grep '^SQLITE=' <<<"$out" || true)
  [[ "${f:-0}" -gt 0 ]] || fail=1
done

echo "FILES $total_files"
echo "BYTES $total_bytes"
if [[ "$sqlite_state" == "ok" ]]; then
  echo "SQLITE integrity_check ok"
else
  echo "SQLITE integrity_check $sqlite_state"
fi

if [[ "$cleanup" -eq 1 ]]; then
  kubectl delete namespace "$target_ns" --wait=false >/dev/null 2>&1 || true
fi

if [[ "$fail" -eq 0 ]]; then
  echo "DRILL PASS"
  exit 0
fi
echo "DRILL FAIL"
exit 1
