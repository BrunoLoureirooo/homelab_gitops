#!/usr/bin/env bash
# CI guardrail: prove the deploy.yml push path filter selects what it should.
# deploy.yml auto-APPLIES to live mini04 on every merge touching what mini04.yml
# reads, so docs, *.example files and other hosts' roles must NOT trigger it,
# while mini04.yml, its roles, inventory and the encrypted vault.yml MUST. This evaluates the
# real `on.push.paths` list (read with yq) against a fixture table, using
# GitHub's order semantics: the LAST pattern that matches a path decides.
# GitHub-side proof of the same behaviour is recorded in the PR (probe branch).
#
# Env: DEPLOY_WORKFLOW (default .github/workflows/deploy.yml), used by tests
# to feed a mutated copy.
set -euo pipefail

wf="${DEPLOY_WORKFLOW:-.github/workflows/deploy.yml}"

# Glob -> anchored regex. Only the metacharacters GitHub documents that we
# use are supported; anything else fails closed instead of silently
# mis-evaluating.
glob_to_regex() {
  local g="$1" out="^" i c
  for ((i = 0; i < ${#g}; i++)); do
    c="${g:i:1}"
    case "$c" in
      '*')
        if [[ "${g:i+1:2}" == '*/' ]]; then
          # `**/` matches zero or more directories (ansible/**/*.md also
          # matches ansible/README.md).
          out+='(.*/)?'
          i=$((i + 2))
        elif [[ "${g:i+1:1}" == '*' ]]; then
          out+='.*'
          i=$((i + 1))
        else
          out+='[^/]*'
        fi
        ;;
      '?') out+='[^/]' ;;
      '.') out+='\.' ;;
      '/' | '-' | '_' | [A-Za-z0-9]) out+="$c" ;;
      *) out+="\\$c" ;;
    esac
  done
  printf '%s$' "$out"
}

patterns=()
while IFS= read -r line; do
  patterns+=("$line")
done < <(yq -r '.on.push.paths[]' "$wf")
if [[ ${#patterns[@]} -eq 0 ]]; then
  echo "FAIL no on.push.paths in $wf"
  exit 1
fi

for p in "${patterns[@]}"; do
  if [[ "$p" == *'['* || "$p" == *']'* || "$p" == *'{'* || "$p" == *'}'* || "$p" == *'+'* ]]; then
    echo "unsupported glob metacharacter in pattern: $p" >&2
    exit 2
  fi
done

# Prints "run" if the path is selected by the filter, else "skip".
selected() {
  local path="$1" result="skip" p neg re
  for p in "${patterns[@]}"; do
    neg=0
    if [[ "$p" == '!'* ]]; then
      neg=1
      p="${p:1}"
    fi
    re="$(glob_to_regex "$p")"
    if [[ "$path" =~ $re ]]; then
      if ((neg)); then result="skip"; else result="run"; fi
    fi
  done
  printf '%s' "$result"
}

fail=0
check() {
  local expected="$1" got
  shift
  # A push deploys when ANY changed file is selected.
  got="skip"
  for f in "$@"; do
    if [[ "$(selected "$f")" == "run" ]]; then got="run"; fi
  done
  if [[ "$got" == "$expected" ]]; then
    echo "PASS $* $expected"
  else
    echo "FAIL $* expected=$expected got=$got"
    fail=1
  fi
}

check skip ansible/README.md
check skip ansible/STORAGE.md
check skip ansible/group_vars/all/vault.yml.example
check skip ansible/vars/luks_recovery.vault.yml.example
check skip ansible/roles/kiosk/README.md
check skip ansible/roles/host_config/README.md
check skip ansible/victus.yml
check skip ansible/roles/host_config_victus/tasks/main.yml
check skip ansible/roles/k3s_host_prep/tasks/main.yml
check skip .github/workflows/deploy.yml
check skip docs/rebuild-node.md
check run ansible/mini04.yml
check run ansible/roles/kiosk/tasks/main.yml
check run ansible/roles/host_config/tasks/main.yml
check run ansible/inventory.yml
check run ansible/group_vars/all/vault.yml
check skip ansible/group_vars/svc_jellyfin.yml
check run ansible/README.md ansible/roles/kiosk/tasks/main.yml

exit "$fail"
