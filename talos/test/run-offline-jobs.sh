#!/usr/bin/env bash
# Run the offline jobs of plans 15-07 and 15-09 (no network, no cluster, no
# hardware) and print OK or FAIL per job. For a quick local check before a push;
# CI runs the same scripts through talos.yaml.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
rc=0
for j in fetch-assets-negative disk256-copy cutover-scripts freeze-selftest image-dependency-selftest; do
  if (cd "$work" && TAL_WORK="$work/tal" TAL_LOGDIR="$work" TAL_REPORT="$work/report-$j.txt" bash "$here/jobs/$j.sh") >"$work/$j.log" 2>&1; then
    echo "OK   $j"
  else
    echo "FAIL $j"
    tail -5 "$work/$j.log"
    rc=1
  fi
done
exit "$rc"
