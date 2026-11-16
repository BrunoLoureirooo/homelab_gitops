#!/usr/bin/env bash
# Read-only hardware facts for the Talos cutover (plan 15-07 Task 3). Run it on
# the machine named in the argument; it prints only the values the plan needs,
# never serial numbers or MAC addresses, and changes nothing.
#
#   hw-capture.sh mini01   on the current Debian mini01 (NIC, GPU, TPM, disks)
#   hw-capture.sh victus   on victus (disks and where /srv/backup lives)
#
# Output is `HW-<key> <value>` lines to paste into talos/CUTOVER.md. A fact whose
# tool is missing prints `unavailable`. Some commands need root (dmesg, mokutil):
# the script uses sudo for them, so expect a password prompt.
set -uo pipefail

host="${1:-}"
[[ "$host" == mini01 || "$host" == victus ]] || {
  echo "usage: hw-capture.sh mini01|victus" >&2
  exit 2
}

has() { command -v "$1" >/dev/null 2>&1; }
out() { # out <key> <value...>
  printf 'HW-%s %s\n' "$1" "${*:2}"
}
# Print each line of a command's output as `HW-<key> <line>`, or `unavailable`.
lines() { # lines <key> <command...>
  local key="$1" any=0 line
  shift
  has "$1" || {
    out "$key" unavailable
    return
  }
  while IFS= read -r line; do
    any=1
    out "$key" "$line"
  done < <("$@" 2>/dev/null)
  ((any)) || out "$key" none
}
root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

# The disks, without serial numbers.
lines disks lsblk -d -o NAME,MODEL,SIZE,TRAN,ROTA

if [[ "$host" == victus ]]; then
  if has findmnt; then
    out backup-mount "$(findmnt -no TARGET,SOURCE /srv/backup 2>/dev/null || echo 'not a mount point')"
  else
    out backup-mount unavailable
  fi
  lines mounts findmnt -rno TARGET,SOURCE,FSTYPE -t ext4,xfs,btrfs
  # LVM: which physical volumes make up each volume group and where each logical
  # volume's extents sit. A volume group that spans the disk you are about to pull
  # (for example the backup volume) will not activate without it.
  if has pvs; then
    while IFS= read -r l; do out lvm-pv "$l"; done < <(root pvs --noheadings -o pv_name,vg_name,pv_size 2>/dev/null)
    while IFS= read -r l; do out lvm-lv "$l"; done < <(root lvs --noheadings -o lv_name,vg_name,devices 2>/dev/null)
  else
    out lvm unavailable
  fi
  exit 0
fi

# mini01: NIC chip family and firmware messages (chip names only, no addresses).
if has lspci; then
  while IFS= read -r l; do
    out nic "$(sed -E 's/^[^ ]+ //; s/\[[0-9a-f]{4}:[0-9a-f]{4}\]//g; s/ +/ /g' <<<"$l")"
  done < <(lspci -nn | grep -i ethernet)
  while IFS= read -r l; do
    out gpu "$(sed -E 's/^[^ ]+ //; s/\[[0-9a-f]{4}:[0-9a-f]{4}\]//g; s/ +/ /g' <<<"$l")"
  done < <(lspci -nn | grep -i -E 'vga|display')
else
  out nic unavailable
  out gpu unavailable
fi
if has dmesg; then
  fw="$(root dmesg 2>/dev/null | grep -i -E 'r8169|r8125|firmware: failed|failed to load' | sed -E 's/^\[[ 0-9.]+\] //' | head -n 8)"
  if [[ -n "$fw" ]]; then
    while IFS= read -r l; do out nic-fw "$l"; done <<<"$fw"
  else
    out nic-fw "no firmware messages"
  fi
fi

# The render and video group ids that own /dev/dri (for the Jellyfin patch).
if [[ -d /dev/dri ]]; then
  out dri "$(find /dev/dri -mindepth 1 -maxdepth 1 -exec basename {} \; | sort | tr '\n' ' ')"
else
  out dri "no /dev/dri"
fi
if has getent; then
  out gids "$(getent group render video | awk -F: '{printf "%s=%s ", $1, $3}')"
else
  out gids unavailable
fi

# TPM and Secure Boot state.
tpm=""
for t in /dev/tpm*; do
  [[ -e "$t" ]] && tpm="$tpm$t "
done
out tpm "${tpm:-none}"
if has mokutil; then
  out secureboot "$(root mokutil --sb-state 2>/dev/null | head -n1)"
else
  out secureboot unavailable
fi

# The Toshiba: filesystem listing and whether /srv/media holds anything. Names of
# files are not printed, only whether the directory is empty.
lines fs lsblk -f -o NAME,FSTYPE,SIZE,MOUNTPOINT
if [[ -d /srv/media ]]; then
  if [[ -z "$(find /srv/media -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then out toshiba empty; else out toshiba has-data; fi
  out toshiba-usage "$(df -h /srv/media 2>/dev/null | awk 'NR==2{print $2" size, "$3" used"}')"
else
  out toshiba "/srv/media not present"
fi
