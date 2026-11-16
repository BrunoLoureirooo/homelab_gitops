#!/usr/bin/env bash
# talos-job: kvm=yes timeout=30
# Plan 15-05 Task 2: csi-driver-smb on Talos. Needs CIFS in the Talos kernel; the
# job measures that first. If CIFS is missing it records the fallback instead of
# failing the plan (the decision file then takes the NFS or in-pod mount route).
#
# Needs the 15-01 harness and the Samba pod from nas-lib.sh.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
talos_dir="$(cd "$here/../.." && pwd)"
# shellcheck source=/dev/null
. "$talos_dir/test/lib.sh"
# shellcheck source=/dev/null
. "$talos_dir/test/nas-lib.sh"
# shellcheck source=/dev/null
. "$talos_dir/storage/pins.env"

name=csi-smb
trap 'talos_ci_down "$name" || true' EXIT
talos_ci_up "$name"

work="${TAL_WORK:?}"
kc=(kubectl --kubeconfig "$work/kubeconfig")
export TALOSCONFIG="${TALOSCONFIG:-$work/cfg/talosconfig}"

# 1. Is CIFS in the kernel? (the answer 15-04 also records)
filesystems="$(talosctl --nodes 127.0.0.1 --endpoints "127.0.0.1:${TAL_APID_PORT:-50000}" read /proc/filesystems 2>/dev/null || true)"
if ! grep -qw cifs <<<"$filesystems"; then
  tal_report "CIFS=missing"
  tal_report "ASSERT cifs-missing-recorded PASS"
  tal_finding CSI-SMB FAIL "CIFS is not in the Talos kernel; plan 15-05 takes the NFS / in-pod mount fallback"
  exit 0
fi
tal_report "CIFS=present"

# 2. Samba pod, then the CSI driver from the pinned chart.
nas_up
helm repo add csi-driver-smb "$CSI_SMB_CHART_REPO" >/dev/null
helm repo update >/dev/null
helm install csi-driver-smb csi-driver-smb/csi-driver-smb --version "$CSI_SMB_CHART_VERSION" \
  --namespace kube-system --wait --timeout 5m --kubeconfig "$work/kubeconfig" >/dev/null

# 3. A PV/PVC against the share, and a pod that writes through it.
"${kc[@]}" -n default create secret generic smb-creds \
  --from-literal=username="$NAS_USER" --from-literal=password="$NAS_PASS" >/dev/null
"${kc[@]}" apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: smb-ci
spec:
  capacity: {storage: 1Gi}
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  mountOptions: ["dir_mode=0777", "file_mode=0777", "uid=1000", "gid=1000", "noperm"]
  csi:
    driver: smb.csi.k8s.io
    volumeHandle: smb-ci-media
    volumeAttributes:
      source: //samba-nas.nas.svc.cluster.local/media
    nodeStageSecretRef: {name: smb-creds, namespace: default}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: smb-ci, namespace: default}
spec:
  accessModes: [ReadWriteMany]
  resources: {requests: {storage: 1Gi}}
  volumeName: smb-ci
  storageClassName: ""
EOF
token="csi-$(date +%s)-$$"
json="$(jq -nc --arg s "echo $token > /d/csi-check.txt && cat /d/csi-check.txt" '{spec:{containers:[{name:"c",image:"docker.io/library/busybox:1.37",command:["sh","-c",$s],volumeMounts:[{name:"d",mountPath:"/d"}]}],volumes:[{name:"d",persistentVolumeClaim:{claimName:"smb-ci"}}]}}')"
"${kc[@]}" run csi-writer --restart=Never --image=docker.io/library/busybox:1.37 --overrides="$json" >/dev/null
"${kc[@]}" wait --for=jsonpath='{.status.phase}'=Succeeded pod/csi-writer --timeout=240s >/dev/null 2>&1 || true
written="$("${kc[@]}" logs csi-writer 2>/dev/null || true)"
if ! grep -qx "$token" <<<"$written"; then
  tal_report "ASSERT csi-write FAIL"
  tal_finding CSI-SMB FAIL "pod could not write through the SMB PV"
  exit 1
fi

# 4. The file is visible through SMB too (written once, read by a second client).
out="$(nas_client nas-verify "get csi-check.txt /tmp/back.txt; !cat /tmp/back.txt")"
if grep -qx "$token" <<<"$out"; then
  tal_report "ASSERT csi-write PASS"
  tal_finding CSI-SMB PASS "csi-driver-smb mounts the share and writes land on the Samba pod"
else
  tal_report "ASSERT csi-write FAIL"
  tal_finding CSI-SMB FAIL "file written through the CSI volume is not visible over SMB"
  exit 1
fi
