#!/usr/bin/env bash
# talos-job: kvm=yes timeout=45
# G1 findings EXT-I915, EXT-UCODE, EXT-REALTEK, EXT-TAILSCALE-SERVICE and the
# informational DRI-DEVICE, TAILSCALE-JOIN, MEM_USED_MB: the extensions of the
# REAL mini01 schematic load on the pinned Talos. A VM has no Intel GPU and CI
# has no Tailscale auth key, so /dev/dri and the tailnet join are HARDWARE-ONLY
# (closed at gate G2, plan 15-07).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"
# shellcheck source=talos/test/lib-find.sh
. "$here/../lib-find.sh"

TAL_FIND_TAG=find-extensions
tal_require_pins

# The Tailscale extension service config WITHOUT any auth key: the committed
# patch with the hostname token filled in.
mkdir -p "$TAL_WORK"
sed 's/@@HOSTNAME@@/tal-ci/' "$TAL_ROOT/patches/tailscale.yaml" >"$TAL_WORK/tailscale-nokey.yaml"
if grep -q 'TS_AUTHKEY' "$TAL_WORK/tailscale-nokey.yaml"; then
  tal_die "the CI tailscale patch must not carry an auth key"
fi

tal_find_cluster mini01 --volume-patch "$TAL_WORK/tailscale-nokey.yaml"

# the schematic that booted is the committed one (a copy would prove nothing)
want_id="${SCHEMATIC_MINI01_ID}"
got_ref="$(tal_installer_ref mini01)"
[[ "$got_ref" == *"$want_id"* ]] || tal_die "the installer reference does not carry SCHEMATIC_MINI01_ID"
tal_report "SCHEMATIC_MINI01_ID=${want_id}"

exts="$(tal_ctl get extensions 2>&1 || true)"
echo "$exts" >"$TAL_WORK/extensions.out"
has_ext() { grep -qi -- "$1" "$TAL_WORK/extensions.out"; }
modtree="$(tal_ctl ls -r /usr/lib/modules 2>/dev/null || true)
$(tal_ctl ls -r /lib/modules 2>/dev/null || true)"
fwtree="$(tal_ctl ls /usr/lib/firmware/rtl_nic 2>/dev/null || true)
$(tal_ctl ls /lib/firmware/rtl_nic 2>/dev/null || true)"

# --- i915 (and whether xe is present too) ---------------------------------------
gpu=none
grep -q 'i915\.ko' <<<"$modtree" && gpu=i915
if grep -q 'xe\.ko' <<<"$modtree"; then
  if [[ "$gpu" == i915 ]]; then gpu=both; else gpu=xe; fi
fi
tal_report "GPU_DRIVERS=${gpu}"
if has_ext i915 && [[ "$gpu" == i915 || "$gpu" == both ]]; then
  tal_finding EXT-I915 PASS "the i915 extension is listed and its module file is present (GPU_DRIVERS=${gpu})"
elif has_ext i915; then
  tal_finding EXT-I915 FAIL "the i915 extension is listed but no i915.ko was found in the module tree"
else
  tal_finding EXT-I915 FAIL "the i915 extension is not listed: $(head -c 200 "$TAL_WORK/extensions.out" | tr '\n' ' ')"
fi

# --- microcode and Realtek firmware ---------------------------------------------
if has_ext intel-ucode; then
  tal_finding EXT-UCODE PASS "intel-ucode is listed"
else
  tal_finding EXT-UCODE FAIL "intel-ucode is not listed"
fi
if has_ext realtek-firmware && grep -q 'rtl' <<<"$fwtree"; then
  tal_finding EXT-REALTEK PASS "realtek-firmware is listed and rtl_nic firmware files are present"
else
  tal_finding EXT-REALTEK FAIL "realtek-firmware not listed or no rtl_nic firmware directory (extensions: $(grep -ci realtek "$TAL_WORK/extensions.out") match)"
fi

# --- the Tailscale extension service, without a login ---------------------------
svc=""
for _ in $(seq 1 24); do
  svc="$(tal_ctl services 2>&1 || true)"
  grep -qi 'ext-tailscale\|tailscale' <<<"$svc" && break
  sleep 5
done
echo "$svc" >"$TAL_WORK/services.out"
logs="$(tal_ctl logs ext-tailscale 2>&1 | head -n 40 || true)"
if grep -qi 'tailscale' "$TAL_WORK/services.out" && grep -qi 'tailscaled\|tailscale' <<<"$logs"; then
  tal_finding EXT-TAILSCALE-SERVICE PASS "the tailscale extension service is registered and tailscaled started (no auth key, so it waits for a login)"
else
  tal_finding EXT-TAILSCALE-SERVICE FAIL "no tailscale extension service or no tailscaled log: $(head -c 200 "$TAL_WORK/services.out" | tr '\n' ' ')"
fi

# --- what a VM cannot prove ------------------------------------------------------
tal_finding DRI-DEVICE HARDWARE-ONLY "closed at gate G2 (plan 15-07): /dev/dri needs the real Intel GPU"
tal_finding TAILSCALE-JOIN HARDWARE-ONLY "closed at gate G2 (plan 15-07): joining the tailnet needs a real auth key"

read -r mem_total mem_avail <<<"$(tal_mem)"
tal_report "MEM_USED_MB=$((mem_total - mem_avail))"
tal_finding MEM_USED_MB PASS "$((mem_total - mem_avail)) MB used of ${mem_total} MB with the mini01 extensions"

tal_summary
