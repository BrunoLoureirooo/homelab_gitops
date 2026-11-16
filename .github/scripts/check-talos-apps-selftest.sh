#!/usr/bin/env bash
# Self-test of check-talos-apps.sh (plan 15-03): the guard passes on the real
# tree and fails on a hand edit, a deleted override, an extra file and a drifted
# manifest copy, so it cannot be a rubber stamp. Works on a copy in a temp dir.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
guard="$here/check-talos-apps.sh"
[[ -d "$repo/talos/apps" ]] || {
  echo "OK (no talos/apps)"
  exit 0
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

fresh() { # fresh: a clean copy of the inputs and outputs in $tmp/r
  rm -rf "$tmp/r"
  mkdir -p "$tmp/r"
  cp -R "$repo/talos" "$repo/argocd" "$tmp/r/"
}
run_guard() { TALOS_REPO_ROOT="$tmp/r" bash "$guard" >"$tmp/out.txt" 2>&1; }
expect_fail() { # expect_fail <label>
  if run_guard; then
    echo "SELFTEST FAIL: $1: the guard passed but must fail"
    fail=1
  elif ! grep -q '^TALOS-APPS' "$tmp/out.txt"; then
    echo "SELFTEST FAIL: $1: the guard failed without a TALOS-APPS line"
    fail=1
  fi
}

fresh
if ! run_guard; then
  echo "SELFTEST FAIL: the guard fails on an untouched copy"
  cat "$tmp/out.txt"
  fail=1
fi

fresh
sed -i.bak 's/^# GENERATED/# EDITED/' "$tmp/r/talos/apps/cluster-baseline.yaml"
rm -f "$tmp/r/talos/apps/cluster-baseline.yaml.bak"
expect_fail "hand edit of a generated Application"

fresh
sed -i.bak '/^  secrets: sealed-secrets-set/d' "$tmp/r/talos/apps-overrides.yaml"
rm -f "$tmp/r/talos/apps-overrides.yaml.bak"
expect_fail "a deleted rename override"

fresh
cp "$tmp/r/talos/apps/sealed-secrets-set.yaml" "$tmp/r/talos/apps/extra.yaml"
expect_fail "an extra file in talos/apps"

fresh
echo "# drift" >>"$tmp/r/talos/manifests/cluster-baseline/limit-range.yaml"
expect_fail "a drifted manifest copy"

if ((fail)); then
  exit 1
fi
echo "OK: talos apps guard self-test"
