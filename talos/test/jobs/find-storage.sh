#!/usr/bin/env bash
# talos-job: kvm=yes timeout=60 heavy=yes
# G1 findings STORAGE-USERVOL-LOCALPATH, LVM-EXTENSION, LVM-IN-POD, TOPOLVM-ON-TALOS:
# what persistent storage works on Talos. A user volume on a second disk plus the
# local-path provisioner must bind a claim and keep data across a pod restart;
# LVM is probed from a privileged pod.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"
# shellcheck source=talos/test/lib-find.sh
. "$here/../lib-find.sh"

TAL_FIND_TAG=find-storage
# disk 1: 20 GB for the user volume `data`; disk 2: 6 GB left blank for the LVM probe
tal_find_cluster base --data-disk 20G --data-disk 6G --volume-patch "$TAL_ROOT/test/patches/find-data-volume.yaml"

# --- the user volume is mounted by Talos ------------------------------------
mounted=no
for _ in $(seq 1 30); do
  if tal_assert_mounted data; then
    mounted=yes
    break
  fi
  sleep 5
done
tal_report "USERVOL_MOUNTED=${mounted}"

# --- local-path provisioner on the user volume ------------------------------
lp_ok=no
lp_note="not attempted"
if [[ "$mounted" == yes ]]; then
  manifest="$TAL_WORK/local-path-storage.yaml"
  curl --fail --silent --show-error --retry 5 -L -o "$manifest" \
    "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCALPATH_VERSION}/deploy/local-path-storage.yaml"
  echo "${LOCALPATH_MANIFEST_SHA256}  ${manifest}" | sha256sum -c - >/dev/null || tal_die "sha256 mismatch for the local-path manifest"
  # nodePathMap: the provisioner stores volumes under the user volume
  sed -i 's|/opt/local-path-provisioner|/var/mnt/data/local-path|g' "$manifest"
  grep -q '/var/mnt/data/local-path' "$manifest" || tal_die "the local-path manifest has no nodePathMap to retarget (manifest layout changed)"
  tal_kubectl apply -f "$manifest" >/dev/null
  tal_psa_privileged local-path-storage # the helper pods mount hostPath
  tal_kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout=300s

  tal_psa_privileged "$TAL_FIND_NS"
  tal_kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: lp-claim, namespace: ${TAL_FIND_NS}}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: {requests: {storage: 1Gi}}
EOF
  pod_yaml() { # pod_yaml <name> <command>
    cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: ${TAL_FIND_NS}}
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: ${TAL_ALPINE}
      command: ["/bin/sh", "-c", "$2"]
      volumeMounts: [{name: v, mountPath: /data}]
  volumes: [{name: v, persistentVolumeClaim: {claimName: lp-claim}}]
EOF
  }
  want="$(printf 'storage-survives' | sha256sum | cut -d' ' -f1)"
  pod_yaml lp-w "printf storage-survives > /data/f && sync && sha256sum /data/f" | tal_kubectl apply -f - >/dev/null
  tal_kubectl -n "$TAL_FIND_NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/lp-w --timeout=300s
  tal_kubectl -n "$TAL_FIND_NS" delete pod lp-w --wait=true >/dev/null
  pod_yaml lp-r "sha256sum /data/f" | tal_kubectl apply -f - >/dev/null
  tal_kubectl -n "$TAL_FIND_NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/lp-r --timeout=300s
  got="$(tal_kubectl -n "$TAL_FIND_NS" logs lp-r | cut -d' ' -f1)"
  if [[ "$got" == "$want" ]]; then
    lp_ok=yes
    lp_note="claim bound on /var/mnt/data/local-path and the file survived a pod restart"
  else
    lp_note="the file did not survive a pod restart (got ${got:-nothing})"
  fi
  # and the bytes really live on the user volume, not on EPHEMERAL
  if tal_ctl ls -r /var/mnt/data/local-path 2>/dev/null | grep -q .; then
    tal_report "LOCALPATH_ON_USERVOL=yes"
  else
    tal_report "LOCALPATH_ON_USERVOL=no"
    if [[ "$lp_ok" == yes ]]; then
      lp_ok=no
      lp_note="the claim bound but nothing appeared under /var/mnt/data/local-path"
    fi
  fi
else
  lp_note="Talos did not mount the data volume at /var/mnt/data within 150 s"
fi
tal_report "STORAGE_LOCALPATH=${lp_ok}"
if [[ "$lp_ok" == yes ]]; then
  tal_finding STORAGE-USERVOL-LOCALPATH PASS "$lp_note"
else
  tal_finding STORAGE-USERVOL-LOCALPATH FAIL "$lp_note"
fi

# --- is there an official LVM extension? ------------------------------------
list="$TAL_WORK/extensions.json"
if curl --fail --silent --show-error --retry 3 -L -o "$list" "${FACTORY_URL}/version/${TALOS_VERSION}/extensions/official" 2>/dev/null && jq -e . "$list" >/dev/null 2>&1; then
  if jq -r '.. | strings' "$list" | grep -qi 'lvm'; then
    tal_finding LVM-EXTENSION PASS "an official extension name contains lvm"
  else
    tal_finding LVM-EXTENSION FAIL "no official extension name contains lvm for ${TALOS_VERSION}"
  fi
else
  tal_finding LVM-EXTENSION UNKNOWN "the factory endpoint listing official extensions did not answer; read github.com/siderolabs/extensions at ${TALOS_VERSION}"
fi

# --- LVM in a privileged pod on the blank 6 GB disk --------------------------
lvm_note=""
lvm_rc=0
# The script runs inside the pod: single quotes are intentional.
# shellcheck disable=SC2016
tal_run_pod lvm-probe "$TAL_ALPINE" yes \
  'set -e
apk add --no-cache lvm2 e2fsprogs >/dev/null 2>&1 || { echo "APK-FAILED"; exit 3; }
grep -q device-mapper /proc/misc && echo "DM-IN-PROC-MISC=yes" || echo "DM-IN-PROC-MISC=no"
disk=""
for d in /sys/block/vd*; do
  [ "$(cat $d/size)" = "12582912" ] && disk="/dev/$(basename $d)"
done
[ -n "$disk" ] || { echo "NO-6G-DISK"; exit 4; }
pvcreate -ff -y "$disk" >/dev/null
vgcreate tvg "$disk" >/dev/null
lvcreate -y -L 1G -n lv tvg >/dev/null
mkfs.ext4 -q /dev/tvg/lv
mkdir -p /mnt/lv && mount /dev/tvg/lv /mnt/lv
echo lvm-ok > /mnt/lv/f
sync
[ "$(cat /mnt/lv/f)" = lvm-ok ] && vgs --noheadings -o vg_name | grep -q tvg && echo "LVM-OK"' \
  /dev=/dev >"$TAL_WORK/lvm-probe.out" || lvm_rc=$?
if grep -q '^LVM-OK' "$TAL_WORK/lvm-probe.out"; then
  tal_finding LVM-IN-POD PASS "pvcreate, vgcreate, lvcreate, mkfs, mount and a file round trip worked in a privileged pod"
elif grep -q 'APK-FAILED' "$TAL_WORK/lvm-probe.out"; then
  tal_finding LVM-IN-POD UNKNOWN "the alpine lvm2 package could not be installed in the pod (no network?)"
else
  lvm_note="$(grep -v '^$' "$TAL_WORK/lvm-probe.out" | tail -n 3 | tr '\n' ' ' | head -c 300)"
  tal_finding LVM-IN-POD FAIL "LVM did not work in a pod (rc=${lvm_rc}): ${lvm_note}"
fi
tal_report "LVM_IN_POD_DETAIL=$(grep -E '^DM-IN-PROC-MISC=' "$TAL_WORK/lvm-probe.out" | head -n1)"

# --- TopoLVM on Talos: not attempted in CI ---------------------------------
# The chart needs cert-manager (webhooks) and a pinned chart; there is no official
# LVM extension today, so this stays UNKNOWN and STORAGE_VERDICT never says
# `topolvm` until a plan adds the attempt (see IMPLEMENTATION-NOTES.md).
tal_finding TOPOLVM-ON-TALOS UNKNOWN "not attempted in CI (needs cert-manager and the topolvm chart); LVM-IN-POD is the precondition"

tal_summary
