#!/usr/bin/env bash
# Keep docs/rebuild-node.md honest (plan 15-09, adapted from the Phase 1 runbook
# check). Prints `RUNBOOK-BAD <reason>` per problem and exits 1:
#   1  the first two H2 headings are not `## Warning: this erases the target disk`
#      and `## Pre-flight`
#   2  a 64-hex literal appears (hashes are referenced through talos/versions.env,
#      never copied), or talos/versions.env is not mentioned
#   3  a talosctl verb is outside the allow-list
#      (apply-config bootstrap kubeconfig get upgrade rollback etcd reset version
#       mounts dmesg health)
#   4  a drill id used in the coverage ledger is missing from the drill catalogue
#   5  the root README does not link docs/rebuild-node.md
#   6  a backticked repository path or script does not exist (STRICT only)
#
# Rule 6 is enforced once talos/G2-PASSED exists (the stack of Talos plans is then
# merged and every named file exists) or when RUNBOOK_STRICT=1; before that a
# missing path is printed as `RUNBOOK-WARN` and does not fail the guard.
#
# Env: RB_ROOT (repository root, default: this repository), used by the self-test.
set -uo pipefail

root="${RB_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
rb="$root/docs/rebuild-node.md"
ledger="$root/docs/mini01-coverage.md"
readme="$root/README.md"

if [[ ! -f "$rb" ]]; then
  echo "OK (no docs/rebuild-node.md)"
  exit 0
fi

bad=0
flag() {
  echo "RUNBOOK-BAD $*"
  bad=1
}

strict=0
[[ -e "$root/talos/G2-PASSED" || "${RUNBOOK_STRICT:-0}" == 1 ]] && strict=1

# 1. the first two H2 headings
h2_first="$(grep -E '^## ' "$rb" | sed -n 1p)"
h2_second="$(grep -E '^## ' "$rb" | sed -n 2p)"
[[ "$h2_first" == "## Warning: this erases the target disk" ]] || flag "the first H2 must be '## Warning: this erases the target disk' (found: ${h2_first:-none})"
[[ "$h2_second" == "## Pre-flight" ]] || flag "the second H2 must be '## Pre-flight' (found: ${h2_second:-none})"

# 2. no hash literal, versions.env referenced
grep -qE '[0-9a-f]{64}' "$rb" && flag "a 64-hex literal appears: reference talos/versions.env instead of copying a hash"
grep -q 'talos/versions.env' "$rb" || flag "talos/versions.env is not referenced"

# 3. talosctl verbs
allowed=" apply-config bootstrap kubeconfig get upgrade rollback etcd reset version mounts dmesg health "
while IFS= read -r line; do
  # Take the words after `talosctl`, skip flags and the value of the flags that take one.
  read -r -a words <<<"${line#*talosctl}"
  verb=""
  skip=0
  for w in "${words[@]}"; do
    if ((skip)); then
      skip=0
      continue
    fi
    case "$w" in
      -n | -e | --nodes | --endpoints | --talosconfig | --context | --image)
        skip=1
        continue
        ;;
      -*) continue ;;
    esac
    # Strip a leading backtick and anything after the verb word (punctuation).
    w="${w#\`}"
    verb="${w%%[^a-z-]*}"
    break
  done
  [[ -n "$verb" ]] || continue
  [[ "$allowed" == *" $verb "* ]] || flag "talosctl verb '$verb' is not in the allow-list"
done < <(grep -E 'talosctl ' "$rb")

# 4. drill ids
if [[ -f "$ledger" ]]; then
  while IFS= read -r id; do
    grep -qE "^- $id:" "$rb" || flag "drill id $id is used in the coverage ledger but is not in the drill catalogue"
  done < <(grep -oE 'D-[A-Z0-9]+' "$ledger" | sort -u)
fi

# 5. README link
grep -q 'docs/rebuild-node.md' "$readme" 2>/dev/null || flag "the root README does not link docs/rebuild-node.md"

# 6. named paths exist
# shellcheck disable=SC2016 # the backticks are literal Markdown, not a substitution
while IFS= read -r p; do
  [[ -e "$root/$p" ]] && continue
  if ((strict)); then flag "named path does not exist: $p"; else echo "RUNBOOK-WARN named path does not exist yet: $p"; fi
done < <(grep -oE '`[^` ]*(talos|docs|argocd|\.github)/[A-Za-z0-9_./-]+[^` ]*`' "$rb" | tr -d '`' | grep -E '^(talos|docs|argocd|\.github)/' | grep -E '\.(sh|yaml|yml|md|env)$' | grep -v '<' | sort -u)

if ((bad)); then exit 1; fi
echo "OK: runbook"
