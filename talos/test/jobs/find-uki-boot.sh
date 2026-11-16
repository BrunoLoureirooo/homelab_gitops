#!/usr/bin/env bash
# talos-job: kvm=yes timeout=60 heavy=yes
# G1 findings UKI-BOOT-SBOFF, UKI-BOOT-SBON-VM-ENROLL: does the Secure Boot (UKI)
# image of the mini01 schematic install and boot, first with Secure Boot not
# enforced, then with Secure Boot on and the firmware in setup mode (auto
# enrolment under virtualisation). Real hardware enrolment is a G2 item.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"
# shellcheck source=talos/test/lib-find.sh
. "$here/../lib-find.sh"

tal_require_pins
sb_iso="$(TAL_CACHE="${TAL_CACHE:-$PWD/.cache}" bash "$TAL_ROOT/fetch-assets.sh" mini01 iso-secureboot)"
sb_image="$(bash "$TAL_ROOT/fetch-assets.sh" mini01 installer-secureboot-ref)"
export TAL_FIND_ISO="$sb_iso" TAL_FIND_IMAGE="$sb_image"
tal_report "UKI_INSTALLER=${sb_image%%:*}"

# restart_from_disk <tag>: stop the VM and boot it again from its disk alone.
restart_from_disk() {
  tal_stop "$1"
  tal_boot "$TAL_WORK/$1.qcow2" "$1"
  tal_wait_api 600
  tal_wait_ready 600
}

# --- case 1: Secure Boot not enforced (the standard OVMF firmware) ---------------
TAL_FIND_TAG=find-uki-off
tal_find_cluster mini01
restart_from_disk find-uki-off
tal_finding UKI-BOOT-SBOFF PASS "the Secure Boot ISO and installer-secureboot install, bootstrap and restart from disk with Secure Boot not enforced"
tal_stop find-uki-off

# --- case 2: Secure Boot enforced, firmware in setup mode ------------------------
export TAL_FIND_REUSE_SECRETS=1
sbcode=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
sbvars=/usr/share/OVMF/OVMF_VARS_4M.fd # empty variable store: setup mode, no keys enrolled
if [[ ! -f "$sbcode" ]]; then
  tal_finding UKI-BOOT-SBON-VM-ENROLL UNKNOWN "the runner has no OVMF secboot firmware ($sbcode)"
  tal_summary
  exit 0
fi
export OVMF_CODE="$sbcode" OVMF_VARS="$sbvars"
export TAL_QEMU_EXTRA="-global driver=cfi.pflash01,property=secure,value=on"
TAL_FIND_TAG=find-uki-on
on_rc=0
(tal_find_cluster mini01) || on_rc=$?
if [[ "$on_rc" -ne 0 ]]; then
  fw="$(grep -aiE 'secure|verification|access denied|enroll|violation' "$TAL_LOGDIR/serial-find-uki-on.log" 2>/dev/null | head -n 3 | tr '\n' ' ' | head -c 250)"
  tal_finding UKI-BOOT-SBON-VM-ENROLL FAIL "no Ready node with Secure Boot on (firmware said: ${fw:-nothing})"
else
  state="$(tal_ctl get securitystate -o json 2>/dev/null | jq -rs '[.[] | .spec.secure_boot // .spec.secureBoot] | first // "unknown"' 2>/dev/null || echo unknown)"
  tal_report "SECUREBOOT_STATE=${state}"
  restart_from_disk find-uki-on
  if [[ "$state" == true ]]; then
    tal_finding UKI-BOOT-SBON-VM-ENROLL PASS "auto enrolment under the VM firmware worked: Secure Boot reported enabled and the node restarts from disk"
  else
    tal_finding UKI-BOOT-SBON-VM-ENROLL FAIL "the node is Ready but the security state does not report Secure Boot enabled (state=${state})"
  fi
fi

tal_summary
