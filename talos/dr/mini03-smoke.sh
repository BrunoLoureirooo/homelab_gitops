#!/usr/bin/env bash
# Smoke test for the mini03 worker (plan docs/plans/mini03-vm.md, WP8).
#
#   mini03-smoke.sh --check [CONTEXT]        read-only: node labels, taint, storage class
#   mini03-smoke.sh --run CONTEXT CONTEXT    create a throwaway pod on mini03, write and read the
#                                            data volume, prove the taint blocks a pod without a
#                                            toleration, then delete everything it created
#
# --run changes the cluster (a scratch namespace) and cleans up after itself; the context
# must be typed twice. Exit: 0 PASS, 1 FAIL, 3 refused, 5 precondition/usage.
set -euo pipefail

NS=mini03-smoke
NODE=mini03
IMG="docker.io/library/alpine:3.22"
mode="${1:-}"
ctx="${2:-admin@homelab-ts}"
k() { kubectl --context "$ctx" "$@"; }
fail=0
ok() { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fail=1; }

check() {
  local tier pool host taint sc
  tier="$(k get node "$NODE" -o jsonpath='{.metadata.labels.node-role\.homeserver/tier}')"
  pool="$(k get node "$NODE" -o jsonpath='{.metadata.labels.node-role\.homeserver/pool}')"
  host="$(k get node "$NODE" -o jsonpath='{.metadata.labels.kubernetes\.io/hostname}')"
  taint="$(k get node "$NODE" -o jsonpath='{.spec.taints[0].key}={.spec.taints[0].value}:{.spec.taints[0].effect}')"
  if [ "$tier" = mobile ]; then ok "label tier=mobile"; else bad "label tier is '$tier'"; fi
  if [ "$pool" = media-backup ]; then ok "label pool=media-backup"; else bad "label pool is '$pool'"; fi
  if [ "$host" = "$NODE" ]; then ok "hostname label"; else bad "hostname label is '$host'"; fi
  if [ "$taint" = "node-role.homeserver/tier=mobile:NoSchedule" ]; then ok "taint present"; else bad "taint is '$taint'"; fi
  sc="$(k get sc topolvm-fast -o name 2>/dev/null || true)"
  if [ -n "$sc" ]; then ok "storage class topolvm-fast exists"; else bad "storage class topolvm-fast missing"; fi
}

manifest() {
  cat <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    pod-security.kubernetes.io/enforce: baseline
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: smoke-data, namespace: $NS}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: topolvm-fast
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: smoke, namespace: $NS}
spec:
  nodeSelector: {kubernetes.io/hostname: $NODE}
  tolerations:
    - {key: node-role.homeserver/tier, operator: Equal, value: mobile, effect: NoSchedule}
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: smoke
      image: $IMG
      command: ["sh", "-c", "echo ok > /data/probe && cat /data/probe && sleep 600"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
      resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 100m, memory: 64Mi}}
      volumeMounts: [{name: data, mountPath: /data}]
  volumes:
    - name: data
      persistentVolumeClaim: {claimName: smoke-data}
---
apiVersion: v1
kind: Pod
metadata: {name: smoke-no-tol, namespace: $NS}
spec:
  nodeSelector: {kubernetes.io/hostname: $NODE}
  securityContext: {runAsNonRoot: true, runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: smoke
      image: $IMG
      command: ["sleep", "60"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
YAML
}

cleanup() {
  local pv
  pv="$(k get pvc smoke-data -n "$NS" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
  k delete namespace "$NS" --wait=true --ignore-not-found >/dev/null 2>&1 || true
  # the class reclaims with Retain: the volume object stays Released, so remove it by name
  if [ -n "$pv" ]; then k delete pv "$pv" --ignore-not-found >/dev/null 2>&1 || true; fi
  echo "cleanup: namespace $NS and its volume object removed"
}

run() {
  if [ "${3:-}" != "$ctx" ]; then
    echo "refused: type the context twice: --run CONTEXT CONTEXT" >&2
    exit 3
  fi
  if k get namespace "$NS" >/dev/null 2>&1; then
    echo "refused: namespace $NS already exists" >&2
    exit 5
  fi
  check
  trap cleanup EXIT
  manifest | k apply -f - >/dev/null
  if k -n "$NS" wait --for=condition=Ready pod/smoke --timeout=180s >/dev/null 2>&1; then
    ok "pod smoke Running"
  else
    bad "pod smoke not Ready in 180s"
  fi
  if [ "$(k -n "$NS" get pod smoke -o jsonpath='{.spec.nodeName}')" = "$NODE" ]; then ok "ran on $NODE"; else bad "not on $NODE"; fi
  if [ "$(k -n "$NS" logs smoke 2>/dev/null | head -1)" = ok ]; then ok "wrote and read the data volume"; else bad "volume read-back failed"; fi
  if [ "$(k -n "$NS" get pvc smoke-data -o jsonpath='{.status.phase}')" = Bound ]; then ok "claim Bound"; else bad "claim not Bound"; fi
  sleep 15
  if [ "$(k -n "$NS" get pod smoke-no-tol -o jsonpath='{.status.phase}')" = Pending ]; then
    ok "pod without toleration stays Pending (taint works)"
  else
    bad "pod without toleration was scheduled"
  fi
}

case "$mode" in
  --check) check ;;
  --run) run "$@" ;;
  *) sed -n 2,10p "$0"; exit 5 ;;
esac
if [ "$fail" = 0 ]; then echo "SMOKE PASS"; else
  echo "SMOKE FAIL"
  exit 1
fi
