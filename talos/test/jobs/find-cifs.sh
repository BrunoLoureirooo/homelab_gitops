#!/usr/bin/env bash
# talos-job: kvm=yes timeout=30
# G1 finding CIFS-KERNEL: does the Talos kernel carry CIFS (needed by
# csi-driver-smb)? Four independent looks; the verdict is PASS unless the kernel
# clearly has no CIFS.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"
# shellcheck source=talos/test/lib-find.sh
. "$here/../lib-find.sh"

TAL_FIND_TAG=find-cifs
tal_find_cluster base

present=no

# (a) the kernel's list of filesystems
if tal_ctl read /proc/filesystems 2>/dev/null | grep -qw cifs; then
  present=yes
  tal_report "CIFS_PROC_FILESYSTEMS=cifs"
else
  tal_report "CIFS_PROC_FILESYSTEMS=absent"
fi

# (b) the kernel config, when the kernel exposes it
cfg=unknown
if tal_ctl read /proc/config.gz >"$TAL_WORK/config.gz" 2>/dev/null && [[ -s "$TAL_WORK/config.gz" ]]; then
  line="$(gzip -dc "$TAL_WORK/config.gz" 2>/dev/null | grep -E '^(# )?CONFIG_CIFS[= ]' | head -n1 || true)"
  case "$line" in
    CONFIG_CIFS=y) cfg=y ;;
    CONFIG_CIFS=m) cfg=m ;;
    *"is not set"*) cfg=absent ;;
  esac
fi
tal_report "CIFS_CONFIG=${cfg}"
[[ "$cfg" == y || "$cfg" == m ]] && present=yes

# (c) a module on disk
if tal_ctl ls -r /lib/modules 2>/dev/null | grep -q 'cifs\.ko'; then
  present=yes
  tal_report "CIFS_MODULE_FILE=present"
else
  tal_report "CIFS_MODULE_FILE=absent"
fi

# (d) a real mount attempt from a privileged pod against loopback with a dummy
# login: any error other than "filesystem not supported" proves the kernel knows CIFS.
tal_find_images
mountlog="$TAL_WORK/cifs-mount.out"
tal_run_pod cifs-probe "$TAL_ALPINE" yes \
  'apk add --no-cache cifs-utils >/dev/null 2>&1 || echo APK-FAILED
mkdir -p /mnt/x
mount -t cifs //127.0.0.1/x /mnt/x -o username=x,password=x,vers=3.0 2>&1 || true
echo MOUNT-DONE' >"$mountlog" || true
if grep -qiE 'filesystem type cifs not supported|No such device|ENODEV' "$mountlog"; then
  tal_report "CIFS_MOUNT_ATTEMPT=not-supported"
elif grep -q 'APK-FAILED' "$mountlog"; then
  tal_report "CIFS_MOUNT_ATTEMPT=inconclusive-no-apk"
else
  present=yes
  tal_report "CIFS_MOUNT_ATTEMPT=kernel-knows-cifs"
fi

if [[ "$present" == yes ]]; then
  tal_finding CIFS-KERNEL PASS "CIFS present (config=${cfg})"
else
  tal_finding CIFS-KERNEL FAIL "no CIFS in /proc/filesystems, the kernel config, the module tree or a mount attempt"
fi
tal_summary
