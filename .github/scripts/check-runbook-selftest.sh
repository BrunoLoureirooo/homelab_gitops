#!/usr/bin/env bash
# Negative proof for check-runbook.sh (plan 15-09): injects one problem per rule
# into a scratch copy and requires the guard to fail and name it; the clean copy
# must pass. Prints `SELFTEST <name> PASS|FAIL`; exit 1 on any FAIL.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
guard="$here/check-runbook.sh"
[[ -f "$repo/docs/rebuild-node.md" ]] || {
  echo "OK (no runbook)"
  exit 0
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail=0

fresh() { # fresh <name> -> a scratch root with the runbook and README
  local d="$scratch/$1"
  mkdir -p "$d/docs"
  cp "$repo/docs/rebuild-node.md" "$d/docs/"
  cp "$repo/README.md" "$d/README.md"
  echo "$d"
}
expect() { # expect <name> <want rc> <pattern> <root> [env...]
  local name="$1" want="$2" pat="$3" d="$4" out rc
  shift 4
  out="$(env RB_ROOT="$d" "$@" bash "$guard" 2>&1)"
  rc=$?
  if [[ "$rc" == "$want" && "$out" == *$pat* ]]; then echo "SELFTEST $name PASS"; else
    echo "SELFTEST $name FAIL (rc=$rc)"
    fail=1
  fi
}

d="$(fresh clean)"
expect clean 0 "OK: runbook" "$d"

d="$(fresh install-above-preflight)"
awk '/^## Pre-flight$/ {print "## Install first"; print ""} {print}' "$d/docs/rebuild-node.md" >"$d/docs/new.md" && mv "$d/docs/new.md" "$d/docs/rebuild-node.md"
expect install-above-preflight 1 "second H2" "$d"

d="$(fresh hash-literal)"
printf '\nThe hash is %s.\n' "$(printf 'ab%.0s' $(seq 1 32))" >>"$d/docs/rebuild-node.md"
expect hash-literal 1 "64-hex" "$d"

d="$(fresh bad-verb)"
# shellcheck disable=SC2016 # literal Markdown backticks
printf '\nRun `talosctl -n <node> wipe disk` now.\n' >>"$d/docs/rebuild-node.md"
expect bad-verb 1 "'wipe'" "$d"

d="$(fresh no-readme-link)"
grep -v 'docs/rebuild-node.md' "$d/README.md" >"$d/README.new" && mv "$d/README.new" "$d/README.md"
expect no-readme-link 1 "README" "$d"

d="$(fresh missing-path-strict)"
# shellcheck disable=SC2016 # literal Markdown backticks
printf '\nSee `docs/does-not-exist.md`.\n' >>"$d/docs/rebuild-node.md"
expect missing-path-strict 1 "does not exist" "$d" RUNBOOK_STRICT=1
expect missing-path-lenient 0 "RUNBOOK-WARN" "$d"

d="$(fresh ledger-drill-missing)"
printf '| row | RESTORED | D-NOPE |\n' >"$d/docs/mini01-coverage.md"
expect ledger-drill-missing 1 "D-NOPE" "$d"

exit "$fail"
