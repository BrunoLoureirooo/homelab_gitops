#!/usr/bin/env bash
# Negative proof for check-talos-config.sh and the refusals of render.sh (plan
# 15-02). Each case copies talos/ to a scratch directory, injects one violation
# and requires a non-zero exit that names the rule. The render cases use the
# offline fake talosctl in talos/test/fixtures/fakebin. Prints
# `SELFTEST <name> PASS|FAIL`; exit 1 on any FAIL.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
guard="$here/check-talos-config.sh"
src="$repo/talos"
if [[ ! -d "$src" ]]; then
  echo "OK (no talos dir)"
  exit 0
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail=0

fresh() { # fresh <name>: scratch copy of talos/, prints its path
  local base="${scratch:?}/${1:?}"
  rm -rf "$base"
  mkdir -p "$base"
  cp -R "$src" "$base/talos"
  rm -rf "$base/talos/out" "$base/talos/.cache" "$base/talos/local"
  echo "$base/talos"
}

expect_rule() { # expect_rule <rule> <label> <dir> [flag]
  local out rc
  out="$(TALOS_DIR="$3" bash "$guard" ${4:+"$4"} 2>&1)"
  rc=$?
  if ((rc != 0)) && grep -q "^TALOS-CONFIG $1 " <<<"$out"; then
    echo "SELFTEST $2 PASS"
  else
    echo "SELFTEST $2 FAIL (exit $rc)"
    fail=1
  fi
}

d="$(fresh clean)"
if TALOS_DIR="$d" bash "$guard" >/dev/null 2>&1; then
  echo "SELFTEST config-clean PASS"
else
  echo "SELFTEST config-clean FAIL"
  fail=1
fi

d="$(fresh r1)"
printf 'ADMIN_PASSWORD=x\n' >>"$d/nodes/mini01.env"
expect_rule 1 config-secret-looking-key "$d"

d="$(fresh r2a)"
printf 'machine:\n  install:\n    disk: /dev/sda\n' >"$d/patches/extra.yaml"
expect_rule 2 config-device-path "$d"

d="$(fresh r2b)"
printf 'machine:\n  network:\n    nameservers:\n      - 10.9.8.7\n' >"$d/patches/extra.yaml"
expect_rule 2 config-ipv4 "$d"

d="$(fresh r2c)"
printf 'machine:\n  systemDiskEncryption:\n    state: {}\n' >"$d/patches/extra.yaml"
expect_rule 2 config-encryption-block "$d"

d="$(fresh r4a)"
printf 'a: b\n' >"$d/secrets/secrets.sops.yaml"
expect_rule 4 config-plaintext-sops "$d"

d="$(fresh r4b)"
printf 'AGE-SECRET-KEY-%s\n' 'AAAAAAAAAAAA' >"$d/notes.txt"
expect_rule 4 config-age-private-key "$d"

d="$(fresh r5)"
# The real DECISIONS.md is answered; plant one unanswered decision to prove the gate.
awk '/^ANSWER:/ && !done { print "ANSWER: DEFAULT"; done = 1; next } { print }' "$d/DECISIONS.md" >"$d/DECISIONS.md.new" && mv "$d/DECISIONS.md.new" "$d/DECISIONS.md"
expect_rule 5 config-require-decisions "$d" --require-decisions

d="$(fresh r6a)"
sed -i.bak "s/'!system_disk && /'/" "$d/patches/volumes-mini01.yaml" && rm -f "$d/patches/volumes-mini01.yaml.bak"
expect_rule 6 config-media-without-system-disk "$d"

d="$(fresh r6b)"
printf '  - TS_AUTHKEY=%s\n' 'x' >>"$d/patches/tailscale.yaml"
expect_rule 6 config-tailscale-key "$d"

# --- render.sh refusals, offline with the fake talosctl ----------------------
fake="$src/test/fixtures/fakebin"
run_render() { # run_render <talos-dir> <args...>
  local dir="$1"
  shift
  PATH="$fake:$PATH" TALOS_ALLOW_PENDING_PINS=1 bash "$dir/render.sh" "$@" >/dev/null 2>&1
}

d="$(fresh render1)"
out="$scratch/render-out"
rm -rf "$out"
if run_render "$d" mini01 --ci --out "$out" && [[ -f "$out/mini01.yaml" ]] && ! grep -q '@@' "$out/mini01.yaml"; then
  echo "SELFTEST render-ok PASS"
else
  echo "SELFTEST render-ok FAIL"
  fail=1
fi
if run_render "$d" mini01 --ci --out "$out"; then
  echo "SELFTEST render-refuses-overwrite FAIL"
  fail=1
else
  echo "SELFTEST render-refuses-overwrite PASS"
fi
if run_render "$d" mini01 --ci --out "$out" --force; then
  echo "SELFTEST render-force PASS"
else
  echo "SELFTEST render-force FAIL"
  fail=1
fi

d="$(fresh render2)"
printf 'ADMIN_PASSWORD=x\n' >>"$d/nodes/mini01.env"
if run_render "$d" mini01 --ci --out "$scratch/render-out2"; then
  echo "SELFTEST render-refuses-secret-key FAIL"
  fail=1
else
  echo "SELFTEST render-refuses-secret-key PASS"
fi

# The real render.sh inside this repository's work tree: an --out inside the tree
# (and not under talos/out) is refused, and nothing is created there.
intree="$src/test/render-in-tree-probe"
if git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1; then
  if run_render "$src" mini01 --ci --out "$intree" || [[ -e "$intree" ]]; then
    echo "SELFTEST render-refuses-in-tree-out FAIL"
    fail=1
    rm -rf "$intree"
  else
    echo "SELFTEST render-refuses-in-tree-out PASS"
  fi
else
  echo "SELFTEST render-refuses-in-tree-out SKIP (not a git work tree)"
fi

# a leftover render temp dir must be reported by --check-secrets-clean
mkdir -p "$scratch/tmpleft/talos-render.test"
if TMPDIR="$scratch/tmpleft" bash "$src/render.sh" --check-secrets-clean >/dev/null 2>&1; then
  echo "SELFTEST render-detects-leftover FAIL"
  fail=1
else
  echo "SELFTEST render-detects-leftover PASS"
fi

exit "$fail"
