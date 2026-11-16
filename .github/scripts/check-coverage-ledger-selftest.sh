#!/usr/bin/env bash
# Negative proof for check-coverage-ledger.sh (plan 15-09): one injected problem
# per rule in a scratch copy must fail the guard and be named; the clean copy and
# a ledger whose RESTORED row has a PASS drill must pass.
# Prints `SELFTEST <name> PASS|FAIL`; exit 1 on any FAIL.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
guard="$here/check-coverage-ledger.sh"
[[ -f "$repo/docs/mini01-coverage.md" ]] || {
  echo "OK (no ledger)"
  exit 0
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail=0

fresh() { # fresh <name> -> a scratch root with the ledger and the runbook
  local d="$scratch/$1"
  mkdir -p "$d/docs"
  cp "$repo/docs/mini01-coverage.md" "$repo/docs/rebuild-node.md" "$d/docs/"
  echo "$d"
}
expect() { # expect <name> <want rc> <pattern> <root> [env...]
  local name="$1" want="$2" pat="$3" d="$4" out rc
  shift 4
  out="$(env CL_ROOT="$d" "$@" bash "$guard" 2>&1)"
  rc=$?
  if [[ "$rc" == "$want" && "$out" == *$pat* ]]; then echo "SELFTEST $name PASS"; else
    echo "SELFTEST $name FAIL (rc=$rc)"
    fail=1
  fi
}
row() { printf '%s\n' "$1" >>"$2/docs/mini01-coverage.md"; }

d="$(fresh clean)"
expect clean 0 "OK: coverage ledger" "$d"

d="$(fresh uncovered)"
row "| Mystery item | host-userland | UNCOVERED | | |" "$d"
expect uncovered 1 "UNCOVERED" "$d"

d="$(fresh restored-without-pass)"
row "| Vaultwarden again | cluster-data | RESTORED | | D-VW |" "$d"
expect restored-without-pass 1 "PASS drill record" "$d"

d="$(fresh restored-with-pass)"
row "| Vaultwarden again | cluster-data | RESTORED | | D-VW |" "$d"
sed -i.bak 's/^| D-VW | PENDING /| D-VW | PASS /' "$d/docs/rebuild-node.md" && rm -f "$d/docs/rebuild-node.md.bak"
expect restored-with-pass 0 "OK: coverage ledger" "$d"

d="$(fresh pending-unknown-drill)"
row "| Something | cluster-data | DRILL-PENDING | | D-NOPE |" "$d"
expect pending-unknown-drill 1 "catalogue" "$d"

d="$(fresh ephemeral-short)"
row "| Short | host-userland | EPHEMERAL | not needed | |" "$d"
expect ephemeral-short 1 "five words" "$d"

d="$(fresh bad-anchor)"
row "| Anchored | accepted-risks | MANUAL-DOCUMENTED | docs/rebuild-node.md#no-such-heading | |" "$d"
expect bad-anchor 1 "anchor not found" "$d"

d="$(fresh declared-missing-strict)"
row "| Declared | machine-config | DECLARED | talos/does-not-exist.yaml | |" "$d"
expect declared-missing-strict 1 "does not exist" "$d" LEDGER_STRICT=1
expect declared-missing-lenient 0 "LEDGER-WARN" "$d"

d="$(fresh address)"
printf 'The host is at %s.%s.%s.%s.\n' 10 20 30 40 >>"$d/docs/mini01-coverage.md"
expect address 1 "address-shaped" "$d"

exit "$fail"
