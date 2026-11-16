#!/usr/bin/env bash
# Run every check-*.sh the way guards.yaml does and print OK/FAIL per script, so
# a contributor can reproduce the CI guard run locally. Not named check-*.sh on
# purpose: guards.yaml would run it recursively.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/../.." || exit 2

rc=0
for s in .github/scripts/check-*.sh; do
  out="$(mktemp)"
  if bash "$s" >"$out" 2>&1; then
    echo "OK   $s"
  else
    echo "FAIL $s"
    sed 's/^/     /' "$out" | head -20
    rc=1
  fi
  rm -f "$out"
done
exit "$rc"
