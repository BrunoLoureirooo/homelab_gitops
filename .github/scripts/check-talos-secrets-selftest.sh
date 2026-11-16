#!/usr/bin/env bash
# Negative proof for check-talos-secrets.sh (plan 15-09): fixture trees with one
# injected problem per rule must fail and name the rule; a clean tree and the
# allowed role patches must pass. Prints `SELFTEST <name> PASS|FAIL`.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="$here/check-talos-secrets.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail=0

fresh() { # fresh <name> -> a clean fixture root
  local d="$scratch/$1"
  mkdir -p "$d/talos/patches" "$d/talos/secrets" "$d/.github/workflows"
  printf 'out/\nlocal/\n' >"$d/talos/.gitignore"
  printf 'machine:\n  type: controlplane\n' >"$d/talos/patches/controlplane.yaml"
  printf 'machine:\n  type: worker\n' >"$d/talos/patches/worker.yaml"
  printf 'data: ENC[x]\nsops:\n  version: 3\n' >"$d/talos/secrets/secrets.sops.yaml"
  printf 'name: ci\non: push\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo hi\n' >"$d/.github/workflows/ci.yaml"
  echo "$d"
}
expect() { # expect <name> <want rc> <pattern> <root>
  local d="$4" out rc
  (cd "$d" && find . -type f | sed 's#^\./##' | sort >"$d/.list")
  out="$(TS_ROOT="$d" TS_FILELIST="$d/.list" bash "$guard" 2>&1)"
  rc=$?
  if [[ "$rc" == "$2" && "$out" == *$3* ]]; then echo "SELFTEST $1 PASS"; else
    echo "SELFTEST $1 FAIL (rc=$rc)"
    fail=1
  fi
}

d="$(fresh clean)"
expect clean 0 "OK: talos secrets sweep" "$d"

d="$(fresh plaintext-secrets)"
printf 'cluster:\n  secret: x\n' >"$d/talos/secrets/secrets.yaml"
expect plaintext-secrets 1 "TALOS-SECRETS a" "$d"

d="$(fresh talosconfig)"
printf 'context: x\n' >"$d/talosconfig"
expect talosconfig 1 "TALOS-SECRETS a" "$d"

d="$(fresh sops-without-metadata)"
printf 'data: plain\n' >"$d/talos/secrets/other.sops.yaml"
expect sops-without-metadata 1 "TALOS-SECRETS b" "$d"

d="$(fresh age-key)"
printf '%s%s\n' 'AGE-SECRET-''KEY-' '1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ' >"$d/note.txt"
expect age-key 1 "TALOS-SECRETS c" "$d"

d="$(fresh tailscale-key)"
printf 'key: %s%s\n' 'tskey''-' 'auth-abcdefgh12345' >"$d/note.txt"
expect tailscale-key 1 "TALOS-SECRETS c" "$d"

# A documentation placeholder is not a key.
d="$(fresh tailscale-placeholder)"
printf 'run: tailscale up --authkey=%s%s\n' 'tskey''-' '...' >"$d/note.txt"
expect tailscale-placeholder 0 "OK: talos secrets sweep" "$d"
d="$(fresh tailscale-key-again)"
printf 'key: %s%s\n' 'tskey''-' 'auth-abcdefgh12345' >"$d/note.txt"
expect tailscale-key 1 "TALOS-SECRETS c" "$d"

d="$(fresh bootstrap-token)"
printf 'token: abcdef.0123456789abcdef\n' >"$d/note.yaml"
expect bootstrap-token 1 "TALOS-SECRETS c" "$d"

d="$(fresh gitignore)"
printf 'out/\n' >"$d/talos/.gitignore"
expect gitignore 1 "TALOS-SECRETS d" "$d"

d="$(fresh echo-secret)"
# shellcheck disable=SC2016 # a literal workflow expression
printf 'jobs:\n  a:\n    steps:\n      - run: echo "${{ secrets.TOKEN }}"\n' >"$d/.github/workflows/bad.yaml"
expect echo-secret 1 "TALOS-SECRETS e" "$d"

d="$(fresh set-x)"
# shellcheck disable=SC2016 # a literal workflow expression
printf 'jobs:\n  a:\n    steps:\n      - env:\n          T: ${{ secrets.TOKEN }}\n        run: |\n          set -x\n          true\n' >"$d/.github/workflows/bad.yaml"
expect set-x 1 "TALOS-SECRETS e" "$d"

exit "$fail"
