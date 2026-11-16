#!/usr/bin/env bash
# CI guardrail for the generated Talos app set (plan 15-03).
#   1  talos/apps/ and the generated manifest copies under talos/manifests/ equal
#      what talos/render-apps.sh produces now (no hand edit, no drift from
#      argocd/apps/ or talos/apps-overrides.yaml)
#
# Prints `TALOS-APPS <rule> <file>: <reason>`; never file contents.
# Env: TALOS_REPO_ROOT (default: this repository), used by the self-test.
set -uo pipefail

root="${TALOS_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$root" || exit 2

bad=0
viol() {
  echo "TALOS-APPS $1 $2: $3"
  bad=1
}

if [[ ! -d talos/apps ]]; then
  echo "OK (no talos/apps)"
  exit 0
fi
command -v yq >/dev/null || {
  echo "check-talos-apps: yq is required" >&2
  exit 2
}

# --- rule 1: regenerate and compare -------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if ! TALOS_REPO_ROOT="$root" bash talos/render-apps.sh --apps-out "$tmp/apps" --manifests-out "$tmp/manifests" >"$tmp/render.log" 2>&1; then
  viol 1 talos/render-apps.sh "the generator failed: $(tail -n 2 "$tmp/render.log" | tr '\n' ' ')"
else
  while IFS= read -r line; do
    [[ -n "$line" ]] && viol 1 "talos/apps" "$line"
  done < <(diff -rq talos/apps "$tmp/apps" 2>&1 | sed -E 's|^Files (.*) and .* differ$|differs: \1|; s|^Only in ([^:]*): (.*)$|only in \1: \2|' | sed "s|$tmp/||g")
  for d in "$tmp"/manifests/*/; do
    [[ -d "$d" ]] || continue
    n="$(basename "$d")"
    while IFS= read -r line; do
      [[ -n "$line" ]] && viol 1 "talos/manifests/$n" "$line"
    done < <(diff -rq "talos/manifests/$n" "$d" 2>&1 | sed -E 's|^Files (.*) and .* differ$|differs: \1|; s|^Only in ([^:]*): (.*)$|only in \1: \2|' | sed "s|$tmp/||g")
  done
fi

# --- rule 3: the empty-cluster ratchet has exactly one line per Application -----------------
exp=talos/test/empty-cluster-expectations.txt
if [[ -f "$exp" ]]; then
  want="$(find talos/apps -maxdepth 1 -name '*.yaml' | wc -l | tr -d ' ')"
  got="$(grep -v '^#' "$exp" | sed 's/#.*//' | awk 'NF >= 3' | wc -l | tr -d ' ')"
  if [[ "$want" != "$got" ]]; then
    viol 3 "$exp" "$got expectation lines for $want Applications in talos/apps"
  fi
  while IFS= read -r f; do
    app="$(yq -r '.metadata.name' "$f")"
    grep -v '^#' "$exp" | sed 's/#.*//' | awk -v a="$app" '$1 == a { found = 1 } END { exit found ? 0 : 1 }' ||
      viol 3 "$exp" "no expectation line for the Application $app"
  done < <(find talos/apps -maxdepth 1 -name '*.yaml' | sort)
fi

if ((bad)); then
  exit 1
fi
echo "OK: talos apps guard"
