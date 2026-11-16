#!/usr/bin/env bash
# talos-job: kvm=yes timeout=90 heavy=yes
# G1 findings RESET-DATA-SEPARATE-DISK, RESET-DATA-SYSTEM-DISK, RESET-DATA-DEFAULT,
# RESET-NEGATIVE-CONTROL: what `talosctl reset` does to a user data volume, on a
# separate disk (L1) and on the system disk (L2). The negative control wipes the
# data disk on purpose and requires the marker to be GONE, so a PASS elsewhere
# proves the marker check can fail.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"
# shellcheck source=talos/test/lib-find.sh
. "$here/../lib-find.sh"

# apply_when_maintenance: after a reset the node comes back in maintenance mode
# (or from the ISO when the system disk was wiped); apply the SAME config again.
apply_when_maintenance() {
  local deadline=$((SECONDS + 420))
  while ((SECONDS < deadline)); do
    if talosctl apply-config --insecure --nodes 127.0.0.1 --endpoints "127.0.0.1:${TAL_APID_PORT}" --file "$TAL_FIND_CONFIG" >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
  done
  tal_die "the node did not accept the configuration again within 420 s after the reset"
}

rebuild_after_reset() {
  apply_when_maintenance
  tal_wait_api 900
  tal_bootstrap
  tal_kubeconfig
  tal_wait_ready 900
}

# volume identity (best effort): the filesystem UUIDs Talos has discovered
volume_ids() {
  tal_ctl get discoveredvolumes -o json 2>/dev/null | jq -rs '[.[] | select(.spec.name == "xfs") | .spec.uuid // empty] | sort | join(",")' 2>/dev/null || true
}

wait_mounted() {
  local i
  for i in $(seq 1 40); do
    tal_assert_mounted data && return 0
    sleep 5
  done
  return 1
}

# --- L1: data volume on a separate disk ---------------------------------------
TAL_FIND_TAG=find-reset-l1
tal_find_cluster base --data-disk 20G --volume-patch "$TAL_ROOT/test/patches/find-data-volume.yaml"
wait_mounted || tal_die "L1: the data volume is not mounted"
tal_marker_write data
tal_marker_verify data || tal_die "L1: the marker does not verify right after writing it"
before="$(volume_ids)"
tal_report "L1_VOLUME_IDS_BEFORE=${before:-unknown}"

# R1: reset that wipes STATE and EPHEMERAL only (the labelled system partitions)
tal_ctl reset --graceful=false --reboot --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL >"$TAL_WORK/reset-r1.out" 2>&1 || true
rebuild_after_reset
wait_mounted || true
after="$(volume_ids)"
tal_report "L1_VOLUME_IDS_AFTER=${after:-unknown}"
if [[ -n "$before" && "$before" == "$after" ]]; then
  tal_report "L1_VOLUME_ADOPTED=same-uuid"
elif [[ -n "$before" ]]; then
  tal_report "L1_VOLUME_ADOPTED=changed-uuid"
fi
if tal_marker_verify data; then
  tal_finding RESET-DATA-SEPARATE-DISK PASS "marker survived a reset that wipes STATE and EPHEMERAL (volume ids: ${before:-unknown} -> ${after:-unknown})"
else
  tal_finding RESET-DATA-SEPARATE-DISK FAIL "marker lost by a reset that wipes STATE and EPHEMERAL; restore the data from Velero after a reset"
fi

# R2: plain reset (the default wipe, which also removes the OS from the system disk)
tal_marker_verify data || tal_marker_write data
tal_ctl reset --graceful=false --reboot >"$TAL_WORK/reset-r2.out" 2>&1 || true
rebuild_after_reset
wait_mounted || true
if tal_marker_verify data; then
  tal_finding RESET-DATA-DEFAULT PASS "marker survived a plain reset (default wipe)"
else
  tal_finding RESET-DATA-DEFAULT FAIL "marker lost by a plain reset (default wipe)"
fi

# Negative control: wipe the data disk on purpose, reboot, and require the marker
# to be GONE. The wipe is done from a privileged pod so it does not depend on the
# exact talosctl wipe flags.
tal_marker_verify data || tal_marker_write data
tal_find_images
# The script runs inside the pod: single quotes are intentional.
# shellcheck disable=SC2016
tal_run_pod wipe-data "$TAL_ALPINE" yes \
  'set -e
apk add --no-cache util-linux >/dev/null 2>&1 || true
disk=""
for d in /sys/block/vd*; do
  [ "$(cat $d/size)" = "41943040" ] && disk="/dev/$(basename $d)"
done
[ -n "$disk" ] || { echo "NO-20G-DISK"; exit 4; }
umount "${disk}"* 2>/dev/null || true
dd if=/dev/zero of="$disk" bs=1M count=64 conv=fsync 2>/dev/null
echo WIPED' /dev=/dev >"$TAL_WORK/wipe-data.out" || true
tal_report "NEGATIVE_WIPE=$(grep -c '^WIPED' "$TAL_WORK/wipe-data.out" || true)"
tal_ctl reboot >/dev/null 2>&1 || true
tal_wait_api 900
tal_wait_ready 900
wait_mounted || true
if tal_marker_verify data; then
  tal_finding RESET-NEGATIVE-CONTROL FAIL "the marker still verified after the data disk was wiped on purpose: the marker check cannot fail, so no data-safety result can be trusted"
else
  tal_finding RESET-NEGATIVE-CONTROL PASS "the marker is gone after wiping the data disk on purpose (the check can fail)"
fi
tal_stop find-reset-l1

# --- L2: data volume on the system disk ---------------------------------------
export TAL_FIND_REUSE_SECRETS=1
TAL_FIND_TAG=find-reset-l2
l2rc=0
TAL_FIND_SOFT_VALIDATE=1 tal_find_cluster base --volume-patch "$TAL_ROOT/test/patches/find-data-volume-system.yaml" || l2rc=$?
if [[ "$l2rc" -eq 3 ]]; then
  tal_finding RESET-DATA-SYSTEM-DISK FAIL "the data volume on the system disk cannot be expressed on ${TALOS_VERSION}: $(head -c 200 "$TAL_WORK/validate.out" | tr '\n' ' '); mini01 data then lives on a separate disk or is restored from Velero"
else
  wait_mounted || tal_die "L2: the data volume on the system disk is not mounted"
  tal_marker_write data
  tal_marker_verify data || tal_die "L2: the marker does not verify right after writing it"
  tal_ctl reset --graceful=false --reboot --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL >"$TAL_WORK/reset-l2.out" 2>&1 || true
  rebuild_after_reset
  wait_mounted || true
  if tal_marker_verify data; then
    tal_finding RESET-DATA-SYSTEM-DISK PASS "marker on a system-disk data volume survived a reset that wipes STATE and EPHEMERAL"
  else
    tal_finding RESET-DATA-SYSTEM-DISK FAIL "marker on a system-disk data volume was lost by a reset that wipes STATE and EPHEMERAL"
  fi
fi

tal_summary
