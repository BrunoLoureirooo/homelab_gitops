#!/usr/bin/env bash
# Evaluate gate G1 for a finished Talos workflow run (plan 15-04). Needs a
# machine with GitHub access and `gh`.
#
#   run-g1.sh <run-id> [--out DIR]
#
# Downloads the talos-* artifacts of the run, merges the findings
# (collect.sh) and prints the gate result (g1-gate.sh). The workflow itself has
# no aggregating job: it would need a pinned download action and an extra
# permission, and the repo's workflow-safety rule T forbids job permissions.
# Each job also writes its findings into its own job summary.
# Exit status is the gate's: 0 go, 1 no-go, 2 incomplete.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run="${1:?usage: run-g1.sh <run-id> [--out DIR]}"
out="${here}/last-run"
if [[ "${2:-}" == --out ]]; then
  out="${3:?--out needs a directory}"
fi
mkdir -p "$out/artifacts"
gh run download "$run" --dir "$out/artifacts" --pattern 'talos-*'
bash "$here/collect.sh" --out "$out" "$out/artifacts"
rc=0
bash "$here/../g1-gate.sh" "$out/findings.txt" | tee "$out/g1.txt" || rc=$?
echo "wrote $out/findings.txt, $out/FINDINGS-ci.md and $out/g1.txt"
exit "$rc"
