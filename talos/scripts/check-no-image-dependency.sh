#!/usr/bin/env bash
# Prove the Talos set does not depend on the Debian image route (plan 15-09, run
# before PR #40 is closed unmerged). Fails if a file under talos/ or the talos*
# workflows
#   1. mentions images/debian-node, or
#   2. names a repository file (under .github/, scripts/, docs/, argocd/, ansible/
#      or images/) that exists neither on the base branch nor in this branch:
#      that is a file only PR #40 (or nobody) has.
#
#   check-no-image-dependency.sh
#
# Meant for the MERGED state of the Talos stack: on a branch that does not yet
# carry every Talos plan it also lists the files other plans will add. Prints
# `IMAGE-DEP <file>: <reason>` per finding and exits 1; exits 0 when clean.
#
# Env: ID_BASE_REF (default origin/main, then main); ID_BASE_LIST and ID_HEAD_LIST
# (files with one path per line) replace the two git listings, for the self-test;
# ID_ROOT (default: the repository root) is the tree to scan.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${ID_ROOT:-$(cd "$here/../.." && pwd)}"
cd "$root" || exit 2

base_list="$(mktemp)"
head_list="$(mktemp)"
trap 'rm -f "$base_list" "$head_list"' EXIT

if [[ -n "${ID_BASE_LIST:-}" ]]; then
  cp "$ID_BASE_LIST" "$base_list"
else
  ref="${ID_BASE_REF:-origin/main}"
  git rev-parse --verify -q "$ref" >/dev/null || ref=main
  git ls-tree -r --name-only "$ref" >"$base_list" 2>/dev/null || {
    echo "cannot list the base branch" >&2
    exit 2
  }
fi
if [[ -n "${ID_HEAD_LIST:-}" ]]; then
  cp "$ID_HEAD_LIST" "$head_list"
else
  git ls-files >"$head_list"
fi

# Files to scan: everything under talos/ except this script, the notes and the
# planning rewrite (which describe the image route on purpose), plus the talos
# workflows.
files=()
while IFS= read -r f; do
  case "$f" in
    talos/scripts/check-no-image-dependency.sh | talos/test/jobs/image-dependency-selftest.sh | talos/IMPLEMENTATION-NOTES* | talos/UNRUN-CHECKS* | talos/planning-rewrite/* | talos/POST-G2.md) continue ;;
    talos/* | .github/workflows/talos*.yaml) [[ -f "$f" ]] && files+=("$f") ;;
  esac
done <"$head_list"

bad=0
for f in "${files[@]}"; do
  if grep -q 'images/debian-node' "$f"; then
    echo "IMAGE-DEP $f: mentions images/debian-node"
    bad=1
  fi
  while IFS= read -r p; do
    p="${p%.}"
    case "$p" in
      *.sh | *.yaml | *.yml | *.md | *.env) ;;
      *) continue ;;
    esac
    if ! grep -qxF "$p" "$base_list" && ! grep -qxF "$p" "$head_list"; then
      echo "IMAGE-DEP $f: names $p, which is neither on the base branch nor in this branch"
      bad=1
    fi
  done < <(grep -ohE '(^|[^A-Za-z0-9_./-])(\.github|scripts|docs|argocd|ansible|images)/[A-Za-z0-9_./-]+' "$f" | sed -E 's/^[^A-Za-z.]//' | sort -u)
done

if ((bad)); then exit 1; fi
echo "OK: the Talos set does not depend on the image route"
