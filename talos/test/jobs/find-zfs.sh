#!/usr/bin/env bash
# talos-job: kvm=yes timeout=60 heavy=yes
# G1 findings ZFS-LOADS, ZFS-MIRROR, ZFS-REBOOT-IMPORT, ZFS-DEGRADED-READ (mini02):
# the zfs extension loads, a two-disk mirror holds data, comes back after a
# reboot without a manual import, and is still readable with one disk missing.
# The pod scripts below are single-quoted on purpose (they run inside the pod).
# shellcheck disable=SC2016
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"
# shellcheck source=talos/test/lib-find.sh
. "$here/../lib-find.sh"

TAL_FIND_TAG=find-zfs
# the REAL mini02 schematic (it lists the zfs extension), two 10 GB data disks
tal_find_cluster mini02 --data-disk 10G --data-disk 10G --patch "$TAL_ROOT/test/patches/find-zfs-modules.yaml"
tal_report "ZFS_DISKS_ATTACHED_FIRST=2"

# zpool runs in the host's root through a privileged pod: / at /host, /dev at /host/dev.
HOSTCMD='chroot /host env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
zfs_pod() { # zfs_pod <name> <script> -> log on stdout
  tal_run_pod "$1" "$TAL_ALPINE" yes "HOSTCMD='${HOSTCMD}'
$2" /=/host /dev=/host/dev
}

# The scripts below run inside the pod, so single quotes and unexpanded $ are intentional.
# shellcheck disable=SC2016
create_script='set -e
$HOSTCMD zpool version | head -n 2
grep -q "^zfs " /proc/modules && echo "ZFS-MODULE=yes" || echo "ZFS-MODULE=no"
disks=""
for d in /sys/block/vd*; do
  [ "$(cat $d/size)" = "20971520" ] && disks="$disks /dev/$(basename $d)"
done
set -- $disks
[ $# -eq 2 ] || { echo "WANT-2-DISKS-GOT-$#"; exit 4; }
$HOSTCMD zpool create -f -o ashift=12 -m /var/zfs-test tank mirror $1 $2
$HOSTCMD zpool status tank
echo "HEALTH=$($HOSTCMD zpool list -H -o health tank)"
mkdir -p /host/var/zfs-test
yes TALOS-MARKER | head -c 4194304 > /host/var/zfs-test/marker.bin
sync
echo "SHA=$(sha256sum /host/var/zfs-test/marker.bin | cut -d" " -f1)"
echo ZFS-CREATED'
create_rc=0
zfs_pod zfs-create "$create_script" >"$TAL_WORK/zfs-create.out" || create_rc=$?

# `set -e` in the pod script stops before the module line if `zpool version` fails.
if grep -q '^ZFS-MODULE=yes' "$TAL_WORK/zfs-create.out"; then
  tal_finding ZFS-LOADS PASS "zpool version works from the host root and the module is loaded"
else
  tal_finding ZFS-LOADS FAIL "zpool or the zfs module is not available: $(tail -n 3 "$TAL_WORK/zfs-create.out" | tr '\n' ' ' | head -c 250)"
fi

want_sha="$(tal_marker_sha)"
if grep -q '^ZFS-CREATED' "$TAL_WORK/zfs-create.out" && grep -q '^HEALTH=ONLINE' "$TAL_WORK/zfs-create.out" && grep -q "^SHA=${want_sha}" "$TAL_WORK/zfs-create.out"; then
  tal_finding ZFS-MIRROR PASS "a two-disk mirror is ONLINE and holds a 4 MiB marker"
else
  tal_finding ZFS-MIRROR FAIL "mirror creation or the marker failed (rc=${create_rc}): $(tail -n 4 "$TAL_WORK/zfs-create.out" | tr '\n' ' ' | head -c 250)"
fi

verify_script='set -e
$HOSTCMD zpool list -H -o name,health
test -f /host/var/zfs-test/marker.bin || { echo "MARKER-MISSING"; exit 5; }
echo "SHA=$(sha256sum /host/var/zfs-test/marker.bin | cut -d" " -f1)"'

# --- reboot: the pool must be imported again without a manual step -------------
tal_ctl reboot >/dev/null 2>&1 || true
sleep 20
tal_wait_api 900
tal_wait_ready 900
# shellcheck disable=SC2016
verify_rc=0
zfs_pod zfs-verify "$verify_script" >"$TAL_WORK/zfs-verify.out" || verify_rc=$?
if [[ "$verify_rc" -eq 0 ]] && grep -q 'tank[[:space:]]*ONLINE' "$TAL_WORK/zfs-verify.out" && grep -q "^SHA=${want_sha}" "$TAL_WORK/zfs-verify.out"; then
  tal_finding ZFS-REBOOT-IMPORT PASS "after a reboot the pool imported by itself and the marker verified"
else
  tal_finding ZFS-REBOOT-IMPORT FAIL "after a reboot: $(tail -n 4 "$TAL_WORK/zfs-verify.out" | tr '\n' ' ' | head -c 250)"
fi

# --- degraded read: one of the two disks gone -----------------------------------
tal_stop find-zfs
tal_boot "$TAL_WORK/find-zfs.qcow2" find-zfs --data-disk "$TAL_WORK/find-zfs-data1.qcow2"
tal_report "ZFS_DISKS_ATTACHED_DEGRADED=1"
tal_wait_api 900
tal_wait_ready 900
# shellcheck disable=SC2016
degraded_script='set -e
$HOSTCMD zpool list -H -o name,health tank 2>/dev/null || true
# a pool with a missing mirror member is not always imported by itself: try the import
$HOSTCMD zpool import -d /dev tank 2>&1 || true
$HOSTCMD zpool list -H -o name,health tank
test -f /host/var/zfs-test/marker.bin || { echo "MARKER-MISSING"; exit 5; }
echo "SHA=$(sha256sum /host/var/zfs-test/marker.bin | cut -d" " -f1)"'
degraded_rc=0
zfs_pod zfs-degraded "$degraded_script" >"$TAL_WORK/zfs-degraded.out" || degraded_rc=$?
if [[ "$degraded_rc" -eq 0 ]] && grep -q 'tank[[:space:]]*DEGRADED' "$TAL_WORK/zfs-degraded.out" && grep -q "^SHA=${want_sha}" "$TAL_WORK/zfs-degraded.out"; then
  tal_finding ZFS-DEGRADED-READ PASS "with one disk missing the pool is DEGRADED and the marker still verifies"
else
  tal_finding ZFS-DEGRADED-READ FAIL "with one disk missing: $(tail -n 4 "$TAL_WORK/zfs-degraded.out" | tr '\n' ' ' | head -c 250)"
fi
tal_report "ZFS_DETAIL=$(grep -E 'tank[[:space:]]' "$TAL_WORK/zfs-degraded.out" | head -n1 | tr -s ' ')"

tal_summary
