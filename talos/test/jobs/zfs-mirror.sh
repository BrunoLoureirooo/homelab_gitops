#!/usr/bin/env bash
# talos-job: kvm=yes timeout=45 heavy=yes
# Plan 15-05 Task 1 (tracer): a two-disk ZFS mirror on a Talos QEMU node.
# Creates the pool with the production Job (talos/storage/zfs-pool-job.yaml),
# writes a 100 MiB file with a known sha256, reboots, then detaches one disk and
# reads the data from the degraded pool.
#
# Needs the 15-01 harness (talos/test/lib.sh, direct-boot.sh, fetch-assets.sh)
# and the `mini02` schematic with siderolabs/zfs from 15-02. Disk names inside
# the VM are /dev/vdb and /dev/vdc: the only place a device path is allowed is
# talos/test/. Reports ASSERT lines and findings ZFS-*.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
talos_dir="$(cd "$here/../.." && pwd)"
# shellcheck source=/dev/null
. "$talos_dir/test/lib.sh"

work="${TAL_WORK:-${RUNNER_TEMP:-/tmp}/tal}"
mkdir -p "$work"
trap 'tal_stop zfs1 >/dev/null 2>&1 || true' EXIT

FAILED=0
assert() { # assert <name> <command...>
  local n="$1"
  shift
  if "$@"; then
    tal_report "ASSERT $n PASS"
  else
    tal_report "ASSERT $n FAIL"
    FAILED=$((FAILED + 1))
  fi
}

tal_prepare_runner
tal_secrets
iso="$(tal_fetch mini02)"
installer="$(bash "$talos_dir/fetch-assets.sh" mini02 installer-ref)"

qemu-img create -f qcow2 "$work/zfs-sys.qcow2" 20G >/dev/null
qemu-img create -f qcow2 "$work/zfs-d1.qcow2" 2G >/dev/null
qemu-img create -f qcow2 "$work/zfs-d2.qcow2" 2G >/dev/null

tal_gen_config zfs-ci 10.0.2.15 "$installer" \
  "$talos_dir/test/patches/ci-single.yaml" \
  "$talos_dir/patches/volumes-mini02.yaml"

# First boot from the ISO to install, then restart from the disk only (as
# boot-single.sh does).
bash "$talos_dir/test/direct-boot.sh" "$work/zfs-sys.qcow2" zfs1 --iso "$iso" \
  --data-disk "$work/zfs-d1.qcow2" --data-disk "$work/zfs-d2.qcow2"
tal_apply "${TAL_APID_PORT:-50000}" "$work/cfg/controlplane.yaml"
tal_bootstrap
tal_kubeconfig
tal_wait_ready 600
tal_stop zfs1
bash "$talos_dir/test/direct-boot.sh" "$work/zfs-sys.qcow2" zfs1 \
  --data-disk "$work/zfs-d1.qcow2" --data-disk "$work/zfs-d2.qcow2"
tal_wait_ready 300

kc=(kubectl --kubeconfig "$work/kubeconfig")

# run_pod <name> <overrides-json>: run a throwaway busybox pod to completion,
# print its log, delete it. The JSON is built with jq so no quoting is needed.
run_pod() {
  "${kc[@]}" delete pod "$1" --now --ignore-not-found >/dev/null 2>&1
  "${kc[@]}" run "$1" --restart=Never --image=docker.io/library/busybox:1.37 --overrides="$2" >/dev/null
  "${kc[@]}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$1" --timeout=180s >/dev/null 2>&1 || true
  "${kc[@]}" logs "$1" 2>/dev/null || true
  "${kc[@]}" delete pod "$1" --now >/dev/null 2>&1 || true
}

# host_exec <binary> [args...]: run a host binary (the zfs userland comes from
# the extension) in the host mount namespace through a privileged pod. Talos has
# no host shell, so only direct binaries work here.
host_exec() {
  local json
  json="$(jq -nc --args '{spec:{hostPID:true,containers:[{name:"z",image:"docker.io/library/busybox:1.37",securityContext:{privileged:true},command:(["nsenter","-t","1","-m","--"] + $ARGS.positional)}]}}' "$@")"
  run_pod zshell "$json"
}

# pool_pod <script>: run a shell script in a pod with the pool directory at /d.
pool_pod() {
  local json
  json="$(jq -nc --arg s "$2" '{spec:{containers:[{name:"p",image:"docker.io/library/busybox:1.37",command:["sh","-c",$s],volumeMounts:[{name:"d",mountPath:"/d"}]}],volumes:[{name:"d",hostPath:{path:"/var/tank",type:"Directory"}}]}}')"
  run_pod "$1" "$json"
}

pool_job() { # apply the production Job with the nodeSelector removed for CI
  yq e 'select(.kind == "Job") | del(.spec.template.spec.nodeSelector)' \
    "$talos_dir/storage/zfs-pool-job.yaml" | "${kc[@]}" apply -f - >/dev/null
}

# Pool creation through the production Job, with the two CI disks substituted.
"${kc[@]}" create configmap zfs-pool-disks -n kube-system \
  --from-literal=DISK1=/dev/vdb --from-literal=DISK2=/dev/vdc >/dev/null
pool_job
"${kc[@]}" wait --for=condition=complete job/zfs-pool-create -n kube-system --timeout=300s >/dev/null 2>&1 || true
create_log="$("${kc[@]}" logs job/zfs-pool-create -n kube-system 2>&1 || true)"
assert pool-created grep -q 'ONLINE' <<<"$create_log"
tal_report "ZFS_VERSION=$(host_exec zfs version | head -n1 | tr -d '\r')"

# Idempotency: the Job again must exit 0 and not touch the pool.
"${kc[@]}" delete job zfs-pool-create -n kube-system --now >/dev/null
pool_job
"${kc[@]}" wait --for=condition=complete job/zfs-pool-create -n kube-system --timeout=120s >/dev/null 2>&1 || true
second_log="$("${kc[@]}" logs job/zfs-pool-create -n kube-system 2>&1 || true)"
assert job-idempotent grep -q 'already exists' <<<"$second_log"

# Write a known 100 MiB file through a hostPath pod.
pool_pod zwrite 'dd if=/dev/urandom of=/d/blob bs=1M count=100 2>/dev/null && sha256sum /d/blob | cut -d" " -f1 > /d/blob.sha256 && sync' >/dev/null

# shellcheck disable=SC2317,SC2329 # called indirectly through assert
check_hash() { # exit 0 when the stored hash still matches the file
  local out
  # shellcheck disable=SC2016 # the script runs inside the pod, not here
  out="$(pool_pod zread '[ "$(sha256sum /d/blob | cut -d" " -f1)" = "$(cat /d/blob.sha256)" ] && echo HASH-MATCH')"
  grep -q HASH-MATCH <<<"$out"
}
assert hash-before-reboot check_hash

# Reboot: does the pool come back without help?
talosctl --talosconfig "$work/cfg/talosconfig" --nodes 127.0.0.1 \
  --endpoints "127.0.0.1:${TAL_APID_PORT:-50000}" reboot --wait --timeout 10m >/dev/null 2>&1 || true
tal_wait_ready 300
status="$(host_exec zpool status tank 2>&1 || true)"
if grep -q 'state: ONLINE' <<<"$status"; then
  tal_report "IMPORT_ON_BOOT=auto"
  tal_report "ASSERT pool-online-after-reboot PASS"
else
  tal_report "IMPORT_ON_BOOT=manual-needed"
  tal_report "ASSERT pool-online-after-reboot FAIL"
  FAILED=$((FAILED + 1))
  # Continue the proof with an explicit import so the rest is still measured.
  host_exec zpool import tank >/dev/null 2>&1 || true
fi
assert hash-after-reboot check_hash

# Scrub once and record it.
host_exec zpool scrub tank >/dev/null 2>&1 || true
sleep 20
scrub_line="$(host_exec zpool status tank 2>&1 | grep -E 'scan:' | head -n1 | tr -d '\r' || true)"
tal_report "ZFS_SCRUB=${scrub_line:-unknown}"

# Lose one disk: restart with only the first data disk.
tal_stop zfs1
bash "$talos_dir/test/direct-boot.sh" "$work/zfs-sys.qcow2" zfs1 --data-disk "$work/zfs-d1.qcow2"
tal_wait_ready 300
host_exec zpool import tank >/dev/null 2>&1 || true
degraded="$(host_exec zpool status tank 2>&1 || true)"
if grep -q 'DEGRADED' <<<"$degraded"; then
  tal_report "ASSERT degraded-state-reported PASS"
else
  tal_report "ASSERT degraded-state-reported FAIL"
  FAILED=$((FAILED + 1))
fi
assert degraded-readable check_hash

if ((FAILED == 0)); then
  tal_report "ASSERT degraded-pool-imported PASS"
  tal_finding ZFS-MIRROR PASS "mirror survives reboot and the loss of one disk"
else
  tal_finding ZFS-MIRROR FAIL "see the ASSERT lines; option 2 of plan 15-05 applies"
fi
exit "$((FAILED > 0))"
