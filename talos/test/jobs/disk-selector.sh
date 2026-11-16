#!/usr/bin/env bash
# talos-job: kvm=yes timeout=45
# G1 row M4: the install disk is chosen by the committed diskSelector (nvme,
# at least 200 GB), never by a device path. A 256 GB NVMe target, a 128 GB NVMe
# decoy and a 100 GB virtio decoy holding a marker are attached; the install
# must land on the target and leave both decoys untouched. Negative case: a
# selector that matches nothing (at least 300 GB) must not install anywhere.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"

tal_prepare_runner
tal_secrets
iso="$(tal_fetch base)"
tal_gen_talosconfig 10.0.2.15

allocated() { # allocated <qcow2>: bytes of allocated data in the image
  qemu-img map -U --output=json "$1" | jq '[.[] | select(.data == true) | .length] | add // 0'
}

make_disks() { # make_disks <prefix>
  qemu-img create -q -f qcow2 "$TAL_WORK/$1-sys.qcow2" 100G
  qemu-img create -q -f qcow2 "$TAL_WORK/$1-target.qcow2" 256G
  qemu-img create -q -f qcow2 "$TAL_WORK/$1-decoy.qcow2" 128G
  # A recognisable marker on the virtio decoy: 4 MiB of 0xa5 at offset 1 MiB.
  qemu-io -c 'write -P 0xa5 1M 4M' "$TAL_WORK/$1-sys.qcow2" >/dev/null
}

render_case() { # render_case <label> <size-expr> -> rendered file path
  local label="$1" size="$2"
  bash "$TAL_ROOT/render.sh" mini01 --secrets "$TAL_WORK/secrets.yaml" --out "$TAL_WORK/r-$label" \
    --schematic base --no-extras --set ENDPOINT_HOST=10.0.2.15 --set "DISK_SIZE_EXPR=$size" >/dev/null
  tal_patch_node "$TAL_WORK/r-$label/mini01.yaml" "$TAL_ROOT/test/patches/ci-selector.yaml" "$TAL_WORK/r-$label/final.yaml"
  echo "$TAL_WORK/r-$label/final.yaml"
}

boot_case() { # boot_case <prefix>
  tal_boot "$TAL_WORK/$1-sys.qcow2" "disk-selector-$1" --iso "$iso" --boot-nvme \
    --nvme "$TAL_WORK/$1-target.qcow2" --nvme "$TAL_WORK/$1-decoy.qcow2"
}

# ------------------------------------------------------------ positive case ----
make_disks pos
cfg="$(render_case pos '>= 200GB')"
boot_case pos
tal_apply "$TAL_APID_PORT" "$cfg"
tal_wait_api 900
tal_bootstrap
tal_kubeconfig
tal_wait_ready 600

target_bytes="$(allocated "$TAL_WORK/pos-target.qcow2")"
decoy_bytes="$(allocated "$TAL_WORK/pos-decoy.qcow2")"
((target_bytes > 100 * 1024 * 1024)) || tal_die "the 256 GB NVMe has only $target_bytes allocated bytes: Talos did not install on it"
((decoy_bytes == 0)) || tal_die "the 128 GB NVMe decoy was written to ($decoy_bytes bytes)"

# Secondary evidence from the node itself; the resource shapes are probed, an
# unexpected shape is reported as UNKNOWN and does not fail the job.
if devpath="$(tal_ctl get systemdisk -o json 2>/dev/null | jq -r '.spec.dev_path // .spec.devPath // empty')" && [[ -n "$devpath" ]]; then
  tal_report "SYSTEM_DISK_DEV=$devpath"
  if [[ "$devpath" == /dev/nvme* ]]; then
    tal_finding DISK-SELECT-NODE PASS "the node reports an NVMe system disk"
  else
    tal_die "the node reports system disk $devpath, expected an NVMe disk"
  fi
else
  tal_finding DISK-SELECT-NODE UNKNOWN "no systemdisk resource on this Talos version; the qcow2 allocation check above is the proof"
fi
tal_stop disk-selector-pos
# The marker on the virtio decoy must be intact.
qemu-io -r -c 'read -P 0xa5 1M 4M' "$TAL_WORK/pos-sys.qcow2" >/dev/null || tal_die "the marker on the virtio decoy changed"
tal_report "DISK_SELECTOR=ok"
tal_finding DISK-SELECT PASS "installed on the 256 GB NVMe chosen by the selector; both decoys untouched"

# ------------------------------------------------------------ negative case ----
make_disks neg
cfg="$(render_case neg '>= 300GB')"
boot_case neg
tal_apply "$TAL_APID_PORT" "$cfg"
sleep 180
# In Talos 1.14 a node booted from the ISO answers its secure API once it has accepted the
# config, even when it could not install. What matters is that nothing was written to a disk.
if tal_ctl version >/dev/null 2>&1; then
  tal_finding DISK-SELECT-NEG-API UNKNOWN "the live ISO answers its secure API with an unmatched selector; the disk check below is the proof"
fi
neg_bytes="$(allocated "$TAL_WORK/neg-target.qcow2")"
((neg_bytes < 4 * 1024 * 1024)) || tal_die "something was written to the target ($neg_bytes bytes) although no disk matched the selector"
tal_stop disk-selector-neg
tal_report "DISK_SELECTOR_NEGATIVE=ok"
tal_finding DISK-SELECT-NEGATIVE PASS "a selector matching no disk installs nothing"
