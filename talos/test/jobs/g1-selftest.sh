#!/usr/bin/env bash
# talos-job: kvm=no timeout=10
# Proves the G1 gate and the findings collector are not vacuous: an all-PASS set
# is go, and each way of going wrong gives the verdict the plan promises.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"

gate="$TAL_ROOT/g1-gate.sh"
collect="$TAL_ROOT/findings/collect.sh"
criteria="$TAL_ROOT/g1-criteria.tsv"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
nopins="$tmp/no-such-file"

fail() { tal_die "g1-selftest: $*"; }

# An all-PASS findings file built from the criteria, so the test cannot drift
# from the table.
allpass="$tmp/allpass.txt"
grep -v '^#' "$criteria" | awk -F'\t' 'NR > 1 {
    if ($5 != "") { split($5, m, ","); print "FINDING " m[1] " PASS fixture" }
    else print "FINDING " $1 " PASS fixture"
  }' | sort -u >"$allpass"

# run <findings> -> sets rc and out
run() {
  rc=0
  out="$(G1_PINS_PENDING_FILE="${PINS:-$nopins}" bash "$gate" "$1" 2>&1)" || rc=$?
}
expect() { # expect <label> <exit-code> <G1 word>
  [[ "$rc" -eq "$2" ]] || fail "$1: exit $rc, wanted $2: $(tail -n 3 <<<"$out" | tr '\n' ' ')"
  grep -qx "G1=$3" <<<"$out" || fail "$1: wanted G1=$3, got: $(grep '^G1=' <<<"$out")"
}
mutate() { # mutate <out> <sed-expression>: edit a copy of the all-pass file
  sed "$2" "$allpass" >"$1"
}

# 1. everything passes -> go
run "$allpass"
expect "all pass" 0 go

# 2. a must row fails -> no-go
mutate "$tmp/f2.txt" 's/^FINDING BOOT-SINGLE PASS/FINDING BOOT-SINGLE FAIL/'
run "$tmp/f2.txt"
expect "must FAIL" 1 no-go
grep -q 'BOOT-SINGLE FAILED' <<<"$out" || fail "must FAIL: no reason printed"

# 3. a known row is UNKNOWN -> incomplete
mutate "$tmp/f3.txt" 's/^FINDING RESET-DATA-SYSTEM-DISK PASS/FINDING RESET-DATA-SYSTEM-DISK UNKNOWN/'
run "$tmp/f3.txt"
expect "known UNKNOWN" 2 incomplete

# 4. a known row FAIL is allowed (design relies on Velero) -> still go
mutate "$tmp/f4.txt" 's/^FINDING RESET-DATA-SYSTEM-DISK PASS/FINDING RESET-DATA-SYSTEM-DISK FAIL/'
run "$tmp/f4.txt"
expect "known FAIL (allowed)" 0 go

# 5. the negative control is not PASS -> incomplete (the data results cannot be trusted)
mutate "$tmp/f5.txt" 's/^FINDING RESET-NEGATIVE-CONTROL PASS/FINDING RESET-NEGATIVE-CONTROL FAIL/'
run "$tmp/f5.txt"
expect "negative control FAIL" 2 incomplete

# 6. a should row fails -> go, with a consequence line
mutate "$tmp/f6.txt" 's/^FINDING CIFS-KERNEL PASS/FINDING CIFS-KERNEL FAIL/'
run "$tmp/f6.txt"
expect "should FAIL" 0 go
grep -q '^G1-CONSEQUENCE CIFS-KERNEL' <<<"$out" || fail "should FAIL: no consequence line"

# 7. any-of group: one member PASS is enough, both FAIL is no-go
{
  grep -v '^FINDING UPGRADE-PRESERVE-DATA ' "$allpass"
  echo "FINDING UPGRADE-PRESERVE-DATA FAIL fixture"
  echo "FINDING UPGRADE-NOPRESERVE-DATA PASS fixture"
} >"$tmp/f7a.txt"
run "$tmp/f7a.txt"
expect "any-of one PASS" 0 go
{
  grep -v '^FINDING UPGRADE-PRESERVE-DATA ' "$allpass"
  echo "FINDING UPGRADE-PRESERVE-DATA FAIL fixture"
  echo "FINDING UPGRADE-NOPRESERVE-DATA FAIL fixture"
} >"$tmp/f7b.txt"
run "$tmp/f7b.txt"
expect "any-of both FAIL" 1 no-go

# 8. the last line of an id wins
{
  cat "$allpass"
  echo "FINDING BOOT-SINGLE FAIL first-run"
  echo "FINDING BOOT-SINGLE PASS rerun"
} >"$tmp/f8a.txt"
run "$tmp/f8a.txt"
expect "last wins (PASS)" 0 go
{
  cat "$allpass"
  echo "FINDING BOOT-SINGLE PASS first-run"
  echo "FINDING BOOT-SINGLE FAIL rerun"
} >"$tmp/f8b.txt"
run "$tmp/f8b.txt"
expect "last wins (FAIL)" 1 no-go

# 9. a missing must row and an empty file are incomplete, never go
grep -v '^FINDING VALIDATE ' "$allpass" >"$tmp/f9.txt"
run "$tmp/f9.txt"
expect "missing must row" 2 incomplete
: >"$tmp/f9b.txt"
run "$tmp/f9b.txt"
expect "empty findings" 2 incomplete

# 10. a HARDWARE-ONLY verdict on a must row is incomplete
mutate "$tmp/f10.txt" 's/^FINDING EXT-I915 PASS/FINDING EXT-I915 HARDWARE-ONLY/'
run "$tmp/f10.txt"
expect "must HARDWARE-ONLY" 2 incomplete

# 11. pending pins: even an all-PASS file is incomplete
: >"$tmp/pins-pending"
PINS="$tmp/pins-pending" run "$allpass"
expect "pins pending" 2 incomplete
grep -q 'PINS-PENDING' <<<"$out" || fail "pins pending: no reason printed"

# 12. unknown ids are reported
{
  cat "$allpass"
  echo "FINDING SOMETHING-NEW PASS x"
} >"$tmp/f12.txt"
run "$tmp/f12.txt"
grep -q '^G1-EXTRA SOMETHING-NEW' <<<"$out" || fail "extra id not reported"

# 13. the collector feeds the gate to the same results
mkdir -p "$tmp/art/talos-a" "$tmp/art/talos-b"
head -n 20 "$allpass" | sed 's/ PASS fixture/ PASS fixture-a/' >"$tmp/art/talos-a/findings-job-a.txt"
tail -n +21 "$allpass" >"$tmp/art/talos-b/findings-job-b.txt"
bash "$collect" --out "$tmp/merged" "$tmp/art" >/dev/null
run "$tmp/merged/findings.txt"
expect "collector all pass" 0 go
grep -q '^| BOOT-SINGLE | must | PASS' "$tmp/merged/FINDINGS-ci.md" || fail "collector table lacks the BOOT-SINGLE row"
# a duplicate across jobs: the later file (sorted) wins
echo "FINDING BOOT-SINGLE FAIL later-job" >"$tmp/art/talos-b/findings-job-c.txt"
bash "$collect" --out "$tmp/merged2" "$tmp/art" >/dev/null
run "$tmp/merged2/findings.txt"
expect "collector last wins" 1 no-go

# 14. STORAGE_VERDICT derivation
sv() { grep '^STORAGE_VERDICT=' "$1/findings.txt"; }
[[ "$(sv "$tmp/merged")" == STORAGE_VERDICT=topolvm ]] || fail "storage verdict: LVM and TopoLVM PASS should give topolvm, got $(sv "$tmp/merged")"
mkdir -p "$tmp/art2"
{
  echo "FINDING STORAGE-USERVOL-LOCALPATH PASS x"
  echo "FINDING LVM-IN-POD FAIL x"
  echo "FINDING TOPOLVM-ON-TALOS FAIL x"
} >"$tmp/art2/findings-s.txt"
bash "$collect" --out "$tmp/m3" "$tmp/art2" >/dev/null
[[ "$(sv "$tmp/m3")" == STORAGE_VERDICT=local-path ]] || fail "storage verdict: expected local-path, got $(sv "$tmp/m3")"
mkdir -p "$tmp/art3"
echo "FINDING STORAGE-USERVOL-LOCALPATH FAIL x" >"$tmp/art3/findings-s.txt"
bash "$collect" --out "$tmp/m4" "$tmp/art3" >/dev/null
[[ "$(sv "$tmp/m4")" == STORAGE_VERDICT=none ]] || fail "storage verdict: expected none, got $(sv "$tmp/m4")"

tal_report "G1_SELFTEST=ok"
tal_summary
