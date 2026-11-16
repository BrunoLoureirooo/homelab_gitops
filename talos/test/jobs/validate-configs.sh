#!/usr/bin/env bash
# talos-job: kvm=no timeout=15
# G1 row M3: both nodes render from the committed patches, every render passes
# `talosctl validate --mode metal`, the hostname is the one in the node file, and
# the validation is not vacuous (a mutated config is rejected).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TAL_NEEDS_KVM=no
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"

tal_prepare_runner
out="$TAL_WORK/render"
mkdir -p "$out"

for node in mini01 mini02 mini03; do
  bash "$TAL_ROOT/render.sh" "$node" --ci --out "$out" >/dev/null
  talosctl validate --config "$out/$node.yaml" --mode metal
  want="$(sed -n 's/^HOSTNAME=//p' "$TAL_ROOT/nodes/$node.env")"
  got="$(yq -r 'select(.kind == "HostnameConfig") | .hostname' "$out/$node.yaml" | head -n1)"
  [[ "$got" == "$want" ]] || tal_die "$node renders hostname '$got', expected '$want'"
done
tal_report "VALIDATE=ok"
tal_finding VALIDATE PASS "mini01, mini02 and mini03 renders pass talosctl validate --mode metal"
tal_finding RENDER-HOSTNAME PASS "rendered hostnames equal the node files"

# --- negative proof: a broken config must be rejected -----------------------
rejected=0
sed 's/^  type: controlplane$/  type: bogus/' "$out/mini01.yaml" >"$out/mut-type.yaml"
if ! talosctl validate --config "$out/mut-type.yaml" --mode metal >/dev/null 2>&1; then
  rejected=$((rejected + 1))
  tal_report "VALIDATE_REJECTED_BAD_TYPE=yes"
fi
{
  echo "bogusKey: 1"
  cat "$out/mini01.yaml"
} >"$out/mut-key.yaml"
if ! talosctl validate --config "$out/mut-key.yaml" --mode metal >/dev/null 2>&1; then
  rejected=$((rejected + 1))
  tal_report "VALIDATE_REJECTED_UNKNOWN_KEY=yes"
fi
((rejected >= 1)) || tal_die "talosctl validate accepted every mutated config: the validation is vacuous"
tal_report "VALIDATE_NEGATIVE=ok"
