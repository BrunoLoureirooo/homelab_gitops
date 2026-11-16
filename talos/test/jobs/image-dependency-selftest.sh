#!/usr/bin/env bash
# talos-job: kvm=no timeout=5
# check-no-image-dependency.sh on fixture trees: clean passes; a mention of the
# Debian image directory fails; a reference to a file that only the (unmerged)
# image PR has fails; a reference to a file that exists on main passes.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"

w="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$w"' EXIT
guard="$TAL_ROOT/scripts/check-no-image-dependency.sh"

mkdir -p "$w/talos" "$w/.github/scripts"
printf '%s\n' ".github/scripts/ci-wait.sh" "talos/a.sh" >"$w/base.txt"
printf '%s\n' ".github/scripts/ci-wait.sh" "talos/a.sh" "talos/b.md" >"$w/head.txt"
printf 'echo hi\nbash .github/scripts/ci-wait.sh\n' >"$w/talos/a.sh"
printf 'plain notes\n' >"$w/talos/b.md"

run() {
  ID_ROOT="$w" ID_BASE_LIST="$w/base.txt" ID_HEAD_LIST="$w/head.txt" bash "$guard"
}
fails=0
check() { # check <name> <expected rc>
  local rc=0
  run >"$w/out" 2>&1 || rc=$?
  if [[ "$rc" == "$2" ]]; then tal_finding "$1" PASS "rc=$rc"; else
    tal_finding "$1" FAIL "rc=$rc want=$2"
    cat "$w/out"
    fails=$((fails + 1))
  fi
}

check clean 0
printf 'cp images/debian-node/render.sh .\n' >>"$w/talos/b.md"
check mentions-image-dir 1
printf 'plain notes\n' >"$w/talos/b.md"
printf 'bash .github/scripts/check-render.sh\n' >>"$w/talos/a.sh"
check names-pr40-only-file 1

((fails == 0)) || tal_die "$fails image-dependency checks were wrong"
tal_report "IMAGE_DEPENDENCY_SELFTEST=pass"
