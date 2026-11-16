#!/usr/bin/env bash
# CI guardrail: fail the build if an argocd/apps/*.yaml Application turns on
# automated sync (prune/selfHeal) without a deliberate, human-written marker
# comment on the line directly above it. This repo's whole adoption safety
# model (argocd/README.md Section 3, 8) rests on every app starting manual-
# sync and only earning `automated:` in its own reviewed follow-up commit -
# this check makes "someone pastes a syncPolicy from an example and it
# quietly starts auto-pruning a live app" fail CI instead of merging.
#
# The fix, if this fails on a real PR: either remove the `automated:` block
# (the app isn't ready for it yet), or - only once that's a genuinely
# reviewed, deliberate decision - add a `# automated-sync: reviewed ...`
# comment immediately above the `automated:` line explaining why it's safe
# (see apps/root.yaml or apps/sealed-secrets.yaml for real examples).
set -uo pipefail

violations=0

while IFS= read -r -d '' f; do
  if ! awk -v file="$f" '
    # A contiguous run of comment lines counts as one block: the marker can
    # be anywhere in it, not only the single line touching "automated:".
    /^[[:space:]]*#/ {
      if (/automated-sync: reviewed/) { marked = 1 }
      next
    }
    /^[[:space:]]*automated:[[:space:]]*$/ {
      if (!marked) {
        print "::error file=" file ",line=" NR "::syncPolicy.automated found with no \x27# automated-sync: reviewed ...\x27 marker comment in the comment block directly above it. This enables auto-prune/self-heal - a deliberate, per-app decision only, not a default. See argocd/README.md Section 3."
        found = 1
      }
    }
    { marked = 0 }
    END { exit found ? 1 : 0 }
  ' "$f"; then
    violations=1
  fi
done < <(find argocd/apps -name '*.yaml' -print0)

if [ "$violations" -ne 0 ]; then
  echo "FAILED: unreviewed automated sync policy found - see errors above."
  exit 1
fi
echo "OK: every automated sync policy in argocd/apps/ is explicitly marked reviewed."
