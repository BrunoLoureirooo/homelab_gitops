#!/usr/bin/env bash
# Wait for the workflow run of HEAD on the current branch and exit non-zero
# unless it succeeded. Used as the automated verify step of later plans.
# Deliberately NOT named check-*.sh: guards.yaml auto-runs every check-*.sh
# and this one needs `gh` auth and a pushed branch.
#
# Usage: ci-wait.sh <workflow-file> [job-name]
set -euo pipefail

wf="${1:?usage: ci-wait.sh <workflow-file> [job-name]}"
job="${2:-}"

sha="$(git rev-parse HEAD)"
branch="$(git rev-parse --abbrev-ref HEAD)"
conclusion="none"

report() {
  echo "ci-wait: workflow=$wf job=${job:-all} conclusion=$conclusion"
}

id=""
deadline=$((SECONDS + 1200))
while ((SECONDS < deadline)); do
  id="$(gh run list --workflow "$wf" --branch "$branch" \
    --json databaseId,headSha --jq ".[] | select(.headSha==\"$sha\") | .databaseId" | head -n1)"
  [[ -n "$id" ]] && break
  sleep 15
done

if [[ -z "$id" ]]; then
  conclusion="no-run-found"
  report
  exit 1
fi

gh run watch "$id" --exit-status >/dev/null 2>&1 || true

if [[ -n "$job" ]]; then
  conclusion="$(gh run view "$id" --json jobs \
    --jq ".jobs[] | select(.name==\"$job\") | .conclusion")"
else
  conclusion="$(gh run view "$id" --json conclusion --jq .conclusion)"
fi
conclusion="${conclusion:-unknown}"

report
[[ "$conclusion" == "success" ]]
