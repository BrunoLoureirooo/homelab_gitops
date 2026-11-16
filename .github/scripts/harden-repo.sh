#!/usr/bin/env bash
# Apply the repo hardening settings with `gh api`. Idempotent: every call is a PUT/PATCH to a
# desired state, and the ruleset is updated in place when it already exists.
# Usage: .github/scripts/harden-repo.sh [OWNER/REPO]   (default BrunoLoureirooo/homelab_gitops)
# Needs: gh (authenticated as a repo admin), jq. Run it by hand at cutover; CI never runs it.
set -euo pipefail

REPO="${1:-BrunoLoureirooo/homelab_gitops}"
OWNER="${REPO%%/*}"
step() { printf '\n==> %s\n' "$*"; }
api() { gh api -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }

# ---------------------------------------------------------------------------------------------
step "a. Repo settings (no wiki/projects, squash-only, delete branch on merge)"
api -X PATCH "repos/$REPO" --input - >/dev/null <<'JSON'
{
  "has_wiki": false,
  "has_projects": false,
  "allow_squash_merge": true,
  "allow_merge_commit": false,
  "allow_rebase_merge": false,
  "delete_branch_on_merge": true,
  "allow_auto_merge": false,
  "allow_update_branch": true
}
JSON

# ---------------------------------------------------------------------------------------------
step "b. Security features"
# Secret scanning and push protection: free on public repos; on a private repo they need
# GitHub Secret Protection (paid), so this call can 422 while the repo is still private.
api -X PATCH "repos/$REPO" --input - >/dev/null <<'JSON'
{
  "security_and_analysis": {
    "secret_scanning": {"status": "enabled"},
    "secret_scanning_push_protection": {"status": "enabled"}
  }
}
JSON
echo "dependabot alerts"
api -X PUT "repos/$REPO/vulnerability-alerts"
echo "private vulnerability reporting"
api -X PUT "repos/$REPO/private-vulnerability-reporting"

# ---------------------------------------------------------------------------------------------
step "c. Actions"
echo "default token permissions: read, Actions cannot approve PRs"
api -X PUT "repos/$REPO/actions/permissions/workflow" \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
echo "fork PR approval: all external contributors"
api -X PUT "repos/$REPO/actions/permissions/fork-pr-contributor-approval" \
  -f approval_policy=all_external_contributors
echo "allowed actions: selected"
api -X PUT "repos/$REPO/actions/permissions" -F enabled=true -f allowed_actions=selected
# Third-party actions used by .github/workflows/*.y*ml (everything else is GitHub-owned):
#   tailscale/github-action  (deploy.yml, talos-deploy.yaml)
#   azure/setup-helm         (validate.yaml)
#   gitleaks/gitleaks-action (lint.yaml)
# Re-check with: grep -hE '^\s*-?\s*uses:' .github/workflows/*.y*ml | sort -u
# NOTE: the docs say patterns_allowed only applies to public repositories.
api -X PUT "repos/$REPO/actions/permissions/selected-actions" --input - <<'JSON'
{
  "github_owned_allowed": true,
  "verified_allowed": false,
  "patterns_allowed": [
    "tailscale/github-action@*",
    "azure/setup-helm@*",
    "gitleaks/gitleaks-action@*"
  ]
}
JSON
# Require full-SHA pinning. The REST docs list sha_pinning_required on
# PUT /repos/{repo}/actions/permissions, but it makes every workflow with a tag-pinned
# `uses:` fail (validate.yaml and lint.yaml are still tag-pinned). Enable it only after those
# are pinned to 40-char SHAs, by uncommenting:
# api -X PUT "repos/$REPO/actions/permissions" -F enabled=true -f allowed_actions=selected \
#   -F sha_pinning_required=true

# ---------------------------------------------------------------------------------------------
step "d. Ruleset main-protection on the default branch"
RULESET_NAME="main-protection"
RULESET_BODY="$(cat <<'JSON'
{
  "name": "main-protection",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "bypass_actors": [
    {"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request"}
  ],
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "require_code_owner_review": true,
        "dismiss_stale_reviews_on_push": true,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
      }
    }
  ]
}
JSON
)"
# No required status checks yet. To add the guards check later, append this to "rules" above
# (job name from .github/workflows/guards.yaml; add it only once it is stable):
#   ,{"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": false,
#     "required_status_checks": [{"context": "guards"}]}}
RULESET_ID="$(api "repos/$REPO/rulesets" --jq ".[] | select(.name==\"$RULESET_NAME\") | .id" | head -n1)"
if [ -n "$RULESET_ID" ]; then
  echo "updating ruleset $RULESET_ID"
  printf '%s' "$RULESET_BODY" | api -X PUT "repos/$REPO/rulesets/$RULESET_ID" --input - >/dev/null
else
  echo "creating ruleset"
  printf '%s' "$RULESET_BODY" | api -X POST "repos/$REPO/rulesets" --input - >/dev/null
fi

# ---------------------------------------------------------------------------------------------
step "e. Environments (read from the workflows: victus, talos-apply, talos-check)"
OWNER_ID="$(api "users/$OWNER" --jq .id)"
# env_setup NAME WITH_REVIEWER(true|false)
env_setup() {
  local name="$1" reviewer="$2" reviewers='[]'
  if [ "$reviewer" = true ]; then
    reviewers="[{\"type\":\"User\",\"id\":$OWNER_ID}]"
  fi
  echo "environment $name (reviewer: $reviewer)"
  jq -n --argjson r "$reviewers" \
    '{reviewers: $r, deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}}' |
    api -X PUT "repos/$REPO/environments/$name" --input - >/dev/null
  if ! api "repos/$REPO/environments/$name/deployment-branch-policies" \
    --jq '.branch_policies[].name' | grep -qx main; then
    api -X POST "repos/$REPO/environments/$name/deployment-branch-policies" \
      -f name=main -f type=branch >/dev/null
  fi
}
# victus: deploy.yml, manual apply to the backup/desktop host; holds its become password.
env_setup victus true
# talos-apply: talos-deploy.yaml on push to main and mode=apply; changes the live nodes.
env_setup talos-apply true
# talos-check: talos-deploy.yaml mode=check; read-only diff, so no reviewer (a gate here would
# only block previews). It still holds the secrets, hence the main-only branch policy.
env_setup talos-check false

# ---------------------------------------------------------------------------------------------
step "f. Read-back"
api "repos/$REPO" --jq '{visibility, has_wiki, has_projects, allow_squash_merge, allow_merge_commit,
  allow_rebase_merge, delete_branch_on_merge, allow_auto_merge, allow_update_branch,
  security_and_analysis}'
api "repos/$REPO/actions/permissions"
api "repos/$REPO/actions/permissions/selected-actions"
api "repos/$REPO/actions/permissions/workflow"
api "repos/$REPO/actions/permissions/fork-pr-contributor-approval"
api "repos/$REPO/rulesets" --jq '.[] | {id, name, enforcement}'
api "repos/$REPO/environments" --jq '.environments[] | {name, deployment_branch_policy,
  reviewers: [.protection_rules[]? | select(.type=="required_reviewers") | .reviewers[]?.reviewer.login]}'
if api "repos/$REPO/vulnerability-alerts" >/dev/null 2>&1; then echo "dependabot alerts: enabled"; fi
api "repos/$REPO/private-vulnerability-reporting" --jq '"private vulnerability reporting: \(.enabled)"'
