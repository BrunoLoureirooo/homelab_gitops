#!/usr/bin/env bash
# The one QEMU driver of the Talos harness (plan 15-01). Starts a daemonized
# q35 VM under KVM with OVMF (UEFI, like the real hardware).
#
#   direct-boot.sh <qcow2> <tag> [--iso FILE] [--data-disk FILE]... [--nvme FILE]...
#                  [--socket listen=PORT|connect=PORT] [--mac MAC] [--mem MB]
#
#   <qcow2>        system disk (created at TAL_DISK_SIZE, default 40G, if missing)
#   --iso          attach the Talos ISO as a disc. The system disk keeps boot
#                  index 0: a blank disk has no bootloader so the firmware falls
#                  through to the disc, and after the install the disk boots first
#                  (so the installed system never loops back into the installer).
#   --data-disk    extra virtio-blk disk (qcow2), repeatable
#   --nvme         extra NVMe disk (qcow2, serial NVME000<n>), repeatable
#   --boot-nvme    the first NVMe disk (not the positional disk) is the install
#                  target and gets boot index 0; the positional disk is then a
#                  low-priority decoy. Used by the disk-selector and volumes jobs.
#   --socket       second NIC joined to a private point-to-point socket network
#                  (two-node jobs); a socket netdev is used instead of multicast
#                  because hosted runners may have no multicast route
#   --mac          MAC of that second NIC
#   --mem          guest memory in MB (default 4096)
#
# The user-mode NIC forwards the Talos API to 127.0.0.1:TAL_APID_PORT (default
# 50000) and the Kubernetes API to 127.0.0.1:TAL_K8S_PORT (default 6443).
# Serial output goes to serial-<tag>.log in TAL_LOGDIR (default: cwd); the pid to
# <tag>.pid in the same place.
set -euo pipefail

usage() {
  echo "usage: direct-boot.sh <qcow2> <tag> [--iso FILE] [--data-disk FILE]... [--nvme FILE]... [--boot-nvme] [--socket listen=PORT|connect=PORT] [--mac MAC] [--mem MB]" >&2
  exit 2
}

qcow2="${1:-}"
tag="${2:-}"
[[ -n "$qcow2" && -n "$tag" ]] || usage
shift 2

iso=""
socket=""
mac="52:54:00:12:00:99"
mem=4096
boot_nvme=0
data=()
nvme=()
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --boot-nvme ]]; then
    boot_nvme=1
    shift
    continue
  fi
  [[ $# -ge 2 ]] || usage
  case "$1" in
    --iso) iso="$2" ;;
    --data-disk) data+=("$2") ;;
    --nvme) nvme+=("$2") ;;
    --socket) socket="$2" ;;
    --mac) mac="$2" ;;
    --mem) mem="$2" ;;
    *) usage ;;
  esac
  shift 2
done

[[ "$tag" =~ ^[a-z0-9-]+$ ]] || {
  echo "bad tag" >&2
  exit 2
}
if [[ ! -w /dev/kvm ]]; then
  echo "::error::/dev/kvm missing" >&2
  exit 1
fi

logdir="${TAL_LOGDIR:-$PWD}"
mkdir -p "$logdir"
code="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
vars_src="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
vars="$logdir/${tag}-efivars.fd"
# The firmware variables persist across restarts of the same tag, like NVRAM.
[[ -f "$vars" ]] || cp "$vars_src" "$vars"

if [[ ! -f "$qcow2" ]]; then
  qemu-img create -q -f qcow2 "$qcow2" "${TAL_DISK_SIZE:-40G}"
fi

sys_boot=0
nvme_boot=""
if ((boot_nvme)); then
  sys_boot=2
  nvme_boot=",bootindex=0"
fi
args=(
  -machine q35 -accel kvm -cpu host -smp 2 -m "$mem"
  -drive "if=pflash,format=raw,unit=0,readonly=on,file=$code"
  -drive "if=pflash,format=raw,unit=1,file=$vars"
  -drive "file=$qcow2,if=none,id=sys,format=qcow2"
  -device "virtio-blk-pci,drive=sys,bootindex=$sys_boot,serial=SYSDISK"
)
if [[ -n "$iso" ]]; then
  args+=(-drive "file=$iso,if=none,id=cd,media=cdrom,readonly=on,format=raw" -device "ide-cd,drive=cd,bootindex=1")
fi
n=0
for f in "${data[@]+"${data[@]}"}"; do
  [[ -z "$f" ]] && continue
  n=$((n + 1))
  args+=(-drive "file=$f,if=none,id=data$n,format=qcow2" -device "virtio-blk-pci,drive=data$n,serial=DATA000$n")
done
n=0
for f in "${nvme[@]+"${nvme[@]}"}"; do
  [[ -z "$f" ]] && continue
  n=$((n + 1))
  extra=""
  [[ $n -eq 1 ]] && extra="$nvme_boot"
  args+=(-drive "file=$f,if=none,id=nvm$n,format=qcow2" -device "nvme,drive=nvm$n,serial=NVME000$n$extra")
done

args+=(
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${TAL_APID_PORT:-50000}-:50000,hostfwd=tcp:127.0.0.1:${TAL_K8S_PORT:-6443}-:6443"
  -device "virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56"
)
if [[ -n "$socket" ]]; then
  [[ "$socket" =~ ^(listen|connect)=[0-9]+$ ]] || usage
  args+=(-netdev "socket,id=lan,${socket%%=*}=127.0.0.1:${socket#*=}" -device "virtio-net-pci,netdev=lan,mac=$mac")
fi

# TAL_QEMU_EXTRA: extra QEMU arguments, space separated (plan 15-04: the
# Secure Boot case needs `-global driver=cfi.pflash01,property=secure,value=on`).
if [[ -n "${TAL_QEMU_EXTRA:-}" ]]; then
  read -ra extra_args <<<"$TAL_QEMU_EXTRA"
  args+=("${extra_args[@]}")
fi

args+=(
  -display none -monitor none
  -serial "file:$logdir/serial-${tag}.log"
  -daemonize -pidfile "$logdir/${tag}.pid"
)

exec qemu-system-x86_64 "${args[@]}"
