#!/usr/bin/env bash
# talos-job: kvm=no timeout=15
# G1 row M3: rendering the same inputs twice gives byte-identical output, or the
# only differences are the documented VOLATILE_PATHS that render.sh --normalize
# removes. The config applied to a node must not depend on volatile paths.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TAL_NEEDS_KVM=no
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"

tal_prepare_runner
bundle="$TAL_WORK/bundle.yaml"
talosctl gen secrets --force -o "$bundle" >/dev/null

result=identical
for node in mini01 mini02 mini03; do
  for n in 1 2; do
    bash "$TAL_ROOT/render.sh" "$node" --secrets "$bundle" --out "$TAL_WORK/det$n" >/dev/null
  done
  if cmp -s "$TAL_WORK/det1/$node.yaml" "$TAL_WORK/det2/$node.yaml"; then
    continue
  fi
  # Differences: print only the key paths, never the values.
  echo "$node: renders differ at these paths:"
  diff <(yq -o=props "$TAL_WORK/det1/$node.yaml") <(yq -o=props "$TAL_WORK/det2/$node.yaml") |
    grep '^[<>]' | cut -c3- | sed 's/ *=.*//' | sort -u || true
  volatile="$(bash "$TAL_ROOT/render.sh" --print-volatile)"
  [[ -n "$volatile" ]] || tal_die "$node renders are not byte-identical and VOLATILE_PATHS in render.sh is empty: list the paths printed above"
  for n in 1 2; do
    bash "$TAL_ROOT/render.sh" "$node" --secrets "$bundle" --normalize --force --out "$TAL_WORK/det$n" >/dev/null
  done
  cmp -s "$TAL_WORK/det1/$node.yaml" "$TAL_WORK/det2/$node.yaml" || tal_die "$node renders still differ after --normalize: the volatile list is incomplete"
  result=normalized
done

tal_report "RENDER_DET=$result"
tal_finding RENDER-DET PASS "two renders of the same inputs are $result"
