#!/usr/bin/env bash
# CI guardrail (SPEC R6/R21 prohibitions) for GitHub workflows.
#   A  no workflow triggers on pull_request_target (parsed `on:` keys, so a
#      comment that merely mentions it, as deploy.yml's does, is fine)
#   B  no workflow may use self-hosted runners (deploy.yml runs on GitHub-hosted
#      runners over Tailscale since the self-hosted victus runner was retired)
#   G  deploy.yml (applies to live hosts) has no pull_request trigger of any kind
#   C  phase-1 workflows: read-only permissions, job timeouts, actions
#      pinned by full commit SHA, no secrets other than GITHUB_TOKEN
#   D  upload-artifact paths are limited to serial*.log and *report*.txt/md
#   F  (plan 15-08) the Talos deploy path: `id-token: write` exists only in
#      talos-deploy.yaml (top level) and as job-level permissions in deploy.yml
#      (Tailscale OIDC; never top level there); talos-deploy*.yaml has no pull_request or
#      pull_request_target trigger and no self-hosted label, pins every
#      action by commit SHA, and holds exactly contents: read and
#      id-token: write (top level only, no job-level permissions)
#
# Prints `RULE <A-G> <file>: <reason>` per violation.
# Env: CHECK_ROOT (default .), used by tests to scan a planted fixture.
# `--self-test` plants fixtures in a temp directory and proves rule F fails
# on each of its violations and passes on a compliant workflow.
set -uo pipefail

if [[ "${1:-}" == "--self-test" ]]; then
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  fails=0
  good='name: Talos deploy
on:
  push:
    branches: [main]
  workflow_dispatch: {}
permissions:
  contents: read
  id-token: write
jobs:
  deploy:
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
'
  plant() { # plant <case> <talos-deploy.yaml content> [<other.yaml content>]
    mkdir -p "$tmp/$1/.github/workflows"
    printf '%s' "$2" >"$tmp/$1/.github/workflows/talos-deploy.yaml"
    if [[ -n "${3:-}" ]]; then printf '%s' "$3" >"$tmp/$1/.github/workflows/other.yaml"; fi
  }
  expect() { # expect <case> pass|fail
    local out rc=0
    out="$(CHECK_ROOT="$tmp/$1" bash "$self" 2>&1)" || rc=$?
    if [[ "$2" == pass && "$rc" == 0 ]] || [[ "$2" == fail && "$rc" != 0 && "$out" == *"RULE F"* ]]; then
      echo "SELFTEST F $1 PASS"
    else
      echo "SELFTEST F $1 FAIL (rc=$rc)"
      fails=$((fails + 1))
    fi
  }
  plant compliant "$good"
  expect compliant pass
  plant id-token-elsewhere "$good" 'name: Other
on: [workflow_dispatch]
permissions:
  contents: read
  id-token: write
jobs:
  j:
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    steps:
      - run: echo hi
'
  expect id-token-elsewhere fail
  plant pull-request-trigger "${good/branches: \[main\]/branches: [main]
  pull_request:}"
  expect pull-request-trigger fail
  plant unpinned-action "${good/3d3c42e5aac5ba805825da76410c181273ba90b1/v4}"
  expect unpinned-action fail
  plant extra-permission "${good/contents: read/contents: write}"
  expect extra-permission fail
  plant job-level-permissions "${good/    timeout-minutes: 5/    timeout-minutes: 5
    permissions:
      contents: read}"
  expect job-level-permissions fail
  deploy_job='name: Deploy
on: [workflow_dispatch]
permissions:
  contents: read
jobs:
  j:
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    permissions:
      contents: read
      id-token: write
    steps:
      - run: echo hi
'
  plant deploy-job-level "$good" "$deploy_job"
  mv "$tmp/deploy-job-level/.github/workflows/other.yaml" "$tmp/deploy-job-level/.github/workflows/deploy.yml"
  expect deploy-job-level pass
  plant deploy-top-level "$good" "${deploy_job/permissions:
  contents: read/permissions:
  contents: read
  id-token: write}"
  mv "$tmp/deploy-top-level/.github/workflows/other.yaml" "$tmp/deploy-top-level/.github/workflows/deploy.yml"
  expect deploy-top-level fail
  plant other-job-level "$good" "$deploy_job"
  expect other-job-level fail
  if ((fails)); then
    echo "self-test: $fails failure(s)"
    exit 1
  fi
  echo "OK: workflow safety rule F self-test"
  exit 0
fi

root="${CHECK_ROOT:-.}"
cd "$root" || exit 2

bad=0
violation() {
  echo "RULE $1 $2: $3"
  bad=1
}

shopt -s nullglob
all=(.github/workflows/*.yml .github/workflows/*.yaml)
if [[ ${#all[@]} -eq 0 ]]; then
  echo "skip: no workflows"
  exit 0
fi

# Rule A and B apply to every workflow.
for f in "${all[@]}"; do
  base="$(basename "$f")"
  # Serialise the parsed `on:` value (string, list or map) and look for the
  # trigger name in it; comments are gone after parsing.
  if yq -o=json -I=0 '.on' "$f" | grep -q '"pull_request_target"'; then
    violation A "$f" "pull_request_target trigger"
  fi
  if yq -r '.jobs[]."runs-on" | (select(type == "!!seq") | .[]), (select(type == "!!str"))' "$f" 2>/dev/null |
    grep -qE 'self-hosted|mini01|victus'; then
    violation B "$f" "self-hosted runner"
  fi
  if [[ "$base" == "deploy.yml" ]] && yq -o=json -I=0 '.on' "$f" | grep -q '"pull_request'; then
    violation G "$f" "pull_request trigger on a workflow that deploys to live hosts"
  fi
done

# Rule F: the Talos deploy path (plan 15-08).
for f in "${all[@]}"; do
  base="$(basename "$f")"
  # (i) `id-token: write` only in talos-deploy.yaml, plus job-level (never top
  # level) in deploy.yml, whose jobs join the tailnet by OIDC.
  idt="$(yq -r '[.permissions, (.jobs[].permissions)] | map(select(tag == "!!map") | ."id-token") | map(select(. == "write")) | length' "$f" 2>/dev/null || echo 0)"
  idtop="$(yq -r '[.permissions] | map(select(tag == "!!map") | ."id-token") | map(select(. == "write")) | length' "$f" 2>/dev/null || echo 0)"
  if [[ "$base" == "deploy.yml" ]]; then
    if [[ "${idtop:-0}" != 0 ]]; then
      violation F "$f" "id-token: write at top level of deploy.yml (job level only)"
    fi
  elif [[ "${idt:-0}" != 0 && "$base" != "talos-deploy.yaml" ]]; then
    violation F "$f" "id-token: write outside talos-deploy.yaml and deploy.yml"
  fi
  [[ "$base" == talos-deploy* ]] || continue
  # (ii) never reachable from a pull request, never self-hosted.
  if yq -o=json -I=0 '.on' "$f" | grep -q '"pull_request'; then
    violation F "$f" "pull_request or pull_request_target trigger"
  fi
  if yq -r '.jobs[]."runs-on" | (select(type == "!!seq") | .[]), (select(type == "!!str"))' "$f" 2>/dev/null |
    grep -qE 'self-hosted|mini01|victus'; then
    violation F "$f" "self-hosted runner"
  fi
  # (iii) every action pinned by a 40-hex commit SHA.
  while IFS= read -r use; do
    [[ -z "$use" || "$use" == ./* ]] && continue
    if ! [[ "$use" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+@[0-9a-f]{40}$ ]]; then
      violation F "$f" "action not pinned by commit SHA: $use"
    fi
  done < <(yq -r '.jobs[].steps[]?.uses // ""' "$f")
  # (iv) permissions are exactly contents: read and id-token: write, and only
  # at the top level.
  perms="$(yq -r '.permissions | select(tag == "!!map") | to_entries | map(.key + "=" + (.value | tostring)) | sort | join(",")' "$f" 2>/dev/null || true)"
  if [[ "$perms" != "contents=read,id-token=write" ]]; then
    violation F "$f" "permissions must be exactly contents: read and id-token: write"
  fi
  jobperms="$(yq -r '[.jobs[].permissions] | map(select(. != null)) | length' "$f" 2>/dev/null || echo 0)"
  if [[ "${jobperms:-0}" != 0 ]]; then
    violation F "$f" "job-level permissions are not allowed"
  fi
done

# Rules C and D apply to the phase-1 workflows that exist.
phase1=()
for f in "${all[@]}"; do
  case "$(basename "$f")" in
    guards.yaml | dr.yaml | role-tests.yaml | image-spike.yaml | image*.yaml)
      phase1+=("$f") ;;
  esac
done


if [[ ${#phase1[@]} -eq 0 ]]; then
  echo "skip: no phase-1 workflows present for rules C/D"
fi

for f in "${phase1[@]+"${phase1[@]}"}"; do
  [[ -z "$f" ]] && continue
  if [[ "$(yq -r '.permissions.contents // ""' "$f")" != "read" ]]; then
    violation C "$f" "top-level permissions.contents must be read"
  fi
  while IFS= read -r job; do
    [[ -z "$job" ]] && continue
    if [[ "$(yq -r ".jobs.\"$job\".\"timeout-minutes\" // \"\"" "$f")" == "" ]]; then
      violation C "$f" "job $job has no timeout-minutes"
    fi
  done < <(yq -r '.jobs | keys | .[]' "$f")
  while IFS= read -r use; do
    [[ -z "$use" ]] && continue
    [[ "$use" == ./* ]] && continue
    if ! [[ "$use" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+@[0-9a-f]{40}$ ]]; then
      violation C "$f" "action not pinned by commit SHA: $use"
    fi
  done < <(yq -r '.jobs[].steps[]?.uses // ""' "$f")
  # Strip comments so an explanatory comment cannot trip the secrets rule.
  if sed 's/#.*$//' "$f" | grep -oE 'secrets\.[A-Za-z0-9_]+' | grep -vqx 'secrets.GITHUB_TOKEN'; then
    violation C "$f" "references a secret other than GITHUB_TOKEN"
  fi
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    while IFS= read -r line; do
      line="${line#"${line%%[![:space:]]*}"}"
      [[ -z "$line" ]] && continue
      case "$(basename "$line")" in
        serial*.log | *report*.txt | *report*.md) ;;
        findings-*.txt | versions.env.proposed) violation D "$f" "artifact path not on the allow-list: $line" ;;
        *) violation D "$f" "artifact path not on the allow-list: $line" ;;
      esac
    done <<<"$p"
  done < <(yq -r '.jobs[].steps[]? | select((.uses // "") | test("^actions/upload-artifact@")) | .with.path // ""' "$f")
done

if ((bad)); then
  exit 1
fi
echo "OK: workflow safety rules"
