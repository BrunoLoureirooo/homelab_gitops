#!/usr/bin/env bash
# talos-job: kvm=yes timeout=75
# G1 finding EMPTY-CLUSTER (plan 15-03 task 4): an EMPTY Talos CI cluster syncs
# the whole generated app set in the scripted order of bootstrap-argocd.sh, and
# the observed sync and health of every Application match the ratchet file
# talos/test/empty-cluster-expectations.txt, in both directions.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"
# shellcheck source=talos/test/lib-platform.sh
. "$here/../lib-platform.sh"

expect="$TAL_ROOT/test/empty-cluster-expectations.txt"
[[ -f "$expect" ]] || tal_die "no ratchet file $expect"

tal_platform_up
tal_throwaway_sealing_key "$TAL_WORK/sealing-key.yaml"

# the same order the cutover runbook uses (plan 15-07); CI skips the two restore pauses
bash "$TAL_ROOT/bootstrap-argocd.sh" --ci --yes --revision "$TAL_REVISION" --sealing-key "$TAL_WORK/sealing-key.yaml" |
  tee "$TAL_WORK/bootstrap.out" | sed -n '/^STEP\|^SKIP\|^PAUSE\|^bootstrap-argocd/p'

# --- observed states -------------------------------------------------------------------------
tal_kubectl -n argocd get applications -o json |
  jq -r '.items | sort_by(.metadata.name)[] | "\(.metadata.name) \(.status.sync.status // "Unknown") \(.status.health.status // "Unknown")"' >"$TAL_WORK/observed.txt"
while read -r app sync health; do
  tal_report "APP ${app} ${sync} ${health}"
done <"$TAL_WORK/observed.txt"

# --- the ratchet, both directions ------------------------------------------------------------
bad=0
expected_apps="$TAL_WORK/expected-apps.txt"
grep -v '^#' "$expect" | sed 's/#.*//' | awk 'NF >= 3 { print $1, $2, $3 }' >"$TAL_WORK/expected.txt"
awk '{ print $1 }' "$TAL_WORK/expected.txt" | sort >"$expected_apps"

while read -r app esync ehealth; do
  line="$(grep -m1 "^${app} " "$TAL_WORK/observed.txt" || true)"
  if [[ -z "$line" ]]; then
    echo "RATCHET ${app} expected ${esync}/${ehealth} got missing"
    bad=1
    continue
  fi
  read -r _ gsync ghealth <<<"$line"
  if [[ "$esync" != '*' && "$esync" != "$gsync" ]]; then
    echo "RATCHET ${app} expected sync ${esync} got ${gsync}"
    bad=1
  fi
  if [[ "$ehealth" != '*' && "$ehealth" != "$ghealth" ]]; then
    echo "RATCHET ${app} expected health ${ehealth} got ${ghealth}"
    bad=1
  fi
done <"$TAL_WORK/expected.txt"
# an Application nobody wrote an expectation for
while read -r app _; do
  grep -qx "$app" "$expected_apps" || {
    echo "RATCHET ${app} expected nothing (no line in the ratchet file) got an Application"
    bad=1
  }
done <"$TAL_WORK/observed.txt"

if ((bad)); then
  tal_finding EMPTY-CLUSTER FAIL "the observed states differ from empty-cluster-expectations.txt (see RATCHET lines in the job log)"
else
  tal_finding EMPTY-CLUSTER PASS "$(wc -l <"$TAL_WORK/observed.txt" | tr -d ' ') Applications synced from empty in the scripted order and match the ratchet"
fi
tal_summary
exit "$bad"
