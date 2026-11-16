#!/usr/bin/env bash
# talos-job: kvm=yes timeout=60 heavy=yes
# Plan 15-08 Task 2: Talos upgrade from the previous patch release to the
# pinned one with the production upgrade.sh. Proves a marker file on the node
# and (when the cluster has a default StorageClass) a PVC survive, with and
# without --preserve, which answers "does an upgrade lose data on one node".
#
# Depends on the 15-01 harness (talos_ci_up honouring TAL_INSTALL_IMAGE
# when set, see IMPLEMENTATION-NOTES-05-08.md) and 15-03 (a default
# StorageClass, optional here). Reports
#   UPGRADE talos PASS|FAIL DATA_PRESERVE_FLAG=survives|lost DATA_DEFAULT=survives|lost
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
talos_dir="$(cd "$here/../.." && pwd)"
# shellcheck source=/dev/null
. "$talos_dir/test/lib.sh"
# shellcheck source=/dev/null
. "$talos_dir/versions.env"

name=deploy-upgrade
cleanup() { talos_ci_down "$name" || true; }
trap cleanup EXIT

# Previous patch release of the pinned version (vX.Y.Z -> vX.Y.Z-1).
patch="${TALOS_VERSION##*.}"
if [[ "$patch" -lt 1 ]]; then
  tal_finding DEPLOY-UPGRADE UNKNOWN "pinned version has patch 0: no previous patch release to start from"
  tal_report "UPGRADE talos SKIP no-previous-patch"
  exit 0
fi
prev="${TALOS_VERSION%.*}.$((patch - 1))"
# The base schematic has no extensions; the installer image decides the
# installed version, so the pinned ISO can still be used to install `prev`.
export TAL_INSTALL_IMAGE="${FACTORY_URL#https://}/installer/${SCHEMATIC_BASE_ID}:${prev}"

talos_ci_up "$name"
work="${TAL_WORK:?}"
export TALOSCONFIG="${TALOSCONFIG:-$work/cfg/talosconfig}"
ep="127.0.0.1:${TAL_APID_PORT:-50000}"
export TALOS_NODES="tal-ci=$ep"
export TALOS_CI=1
export TALOS_DEPLOY_LOG="$work/upgrade-subcommands.log"
: >"$TALOS_DEPLOY_LOG"

kc=(kubectl --kubeconfig "$work/kubeconfig")
token="marker-$(date +%s)"

# pod_run <name> <volume-json-fragment> <shell command>: run a busybox pod with
# the volume at /d, wait for it to finish, print its log, delete it.
pod_run() {
  local pname="$1" vol="$2" cmd="$3" spec
  spec="{\"spec\":{\"containers\":[{\"name\":\"c\",\"image\":\"docker.io/library/busybox:1.37\",\"command\":[\"sh\",\"-c\",\"$cmd\"],\"volumeMounts\":[{\"name\":\"v\",\"mountPath\":\"/d\"}]}],\"volumes\":[{\"name\":\"v\",$vol}]}}"
  "${kc[@]}" delete pod "$pname" --now --ignore-not-found >/dev/null 2>&1
  "${kc[@]}" run "$pname" --restart=Never --image=docker.io/library/busybox:1.37 --overrides="$spec" >/dev/null
  "${kc[@]}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pname" --timeout=180s >/dev/null 2>&1 || true
  "${kc[@]}" logs "$pname" 2>/dev/null || true
  "${kc[@]}" delete pod "$pname" --now >/dev/null 2>&1 || true
}
hostvol='"hostPath":{"path":"/var/lib/deploy-upgrade-marker.d","type":"DirectoryOrCreate"}'
pvcvol='"persistentVolumeClaim":{"claimName":"upgrade-pvc"}'

pvc_ok=no
if "${kc[@]}" get storageclass -o json | jq -e '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true")' >/dev/null 2>&1; then
  pvc_ok=yes
fi

write_marker() {
  pod_run marker-writer "$hostvol" "echo $token > /d/marker" >/dev/null
  if [[ "$pvc_ok" == yes ]]; then
    "${kc[@]}" apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: upgrade-pvc, namespace: default}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 64Mi}}}
EOF
    pod_run pvc-writer "$pvcvol" "echo $token > /d/marker" >/dev/null
  fi
}
read_marker() { pod_run marker-reader "$hostvol" "cat /d/marker"; }
read_pvc() {
  if [[ "$pvc_ok" == yes ]]; then
    pod_run pvc-reader "$pvcvol" "cat /d/marker"
  else
    echo "$token"
  fi
}

write_marker
if [[ "$(read_marker)" != "$token" || "$(read_pvc)" != "$token" ]]; then
  tal_report "UPGRADE talos FAIL marker-not-written"
  exit 1
fi

# Pass 1: with --preserve (the documented flag).
bash "$talos_dir/deploy/upgrade.sh" --talos --yes >"$work/upgrade-1.out"
grep -q 'result=UPGRADED' "$work/upgrade-1.out" || {
  tal_report "UPGRADE talos FAIL pass1"
  exit 1
}
"${kc[@]}" wait --for=condition=Ready node --all --timeout=300s >/dev/null
if [[ "$(read_marker)" == "$token" && "$(read_pvc)" == "$token" ]]; then
  preserve=survives
else
  preserve=lost
fi

# Pass 2: without --preserve. Start again from `prev`; the cluster is rebuilt.
# The default behaviour is recorded, not required to survive.
talos_ci_down "$name"
talos_ci_up "$name"
write_marker
bash "$talos_dir/deploy/upgrade.sh" --talos --yes --no-preserve >"$work/upgrade-2.out" || true
"${kc[@]}" wait --for=condition=Ready node --all --timeout=300s >/dev/null 2>&1 || true
if [[ "$(read_marker)" == "$token" && "$(read_pvc)" == "$token" ]]; then
  default=survives
else
  default=lost
fi

# Kubernetes plan only (the real k8s upgrade is exercised on hardware).
bash "$talos_dir/deploy/upgrade.sh" --k8s --dry-run | grep -q 'result=PLANNED' || {
  tal_report "UPGRADE talos FAIL k8s-dry-run"
  exit 1
}

if [[ "$preserve" == survives ]]; then
  tal_report "UPGRADE talos PASS DATA_PRESERVE_FLAG=$preserve DATA_DEFAULT=$default PVC_CHECKED=$pvc_ok"
  tal_finding UPGRADE-KEEPS-DATA PASS "UPGRADE_KEEPS_DATA=yes flag=--preserve default=$default"
else
  tal_report "UPGRADE talos FAIL DATA_PRESERVE_FLAG=$preserve DATA_DEFAULT=$default PVC_CHECKED=$pvc_ok"
  exit 1
fi
