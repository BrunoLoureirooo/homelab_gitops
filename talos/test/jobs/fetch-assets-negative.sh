#!/usr/bin/env bash
# talos-job: kvm=no timeout=15
# fetch-assets.sh hash behaviour, against a fake local factory (no network):
#   - a first-fetch marker prints the computed hash and exits 3, leaving
#     versions.env untouched
#   - the right pin exits 0 and prints the cached path
#   - a wrong pin exits 1 and deletes the file
#   - the Secure Boot ISO has its own pin and is a different file
#   - talos/PINS-PENDING stops everything with exit 1
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"

work="$(mktemp -d)"
trap 'kill "${srv:-}" 2>/dev/null || true; rm -rf "$work"' EXIT

id="$(printf 'a%.0s' $(seq 1 64))"
python3 "$here/../fake-factory.py" "$id" "$work/port" &
srv=$!
for _ in $(seq 1 50); do
  [[ -s "$work/port" ]] && break
  sleep 0.1
done
[[ -s "$work/port" ]] || tal_die "fake factory did not start"
port="$(cat "$work/port")"

sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# A sandbox copy of the script with its own versions.env and schematic.
sb="$work/talos"
mkdir -p "$sb/schematics" "$work/cache"
cp "$TAL_ROOT/fetch-assets.sh" "$sb/"
cp "$TAL_ROOT/schematics/mini01.yaml" "$sb/schematics/"
plain_sum="$(python3 -c 'import hashlib;print(hashlib.sha256(b"fake plain iso "*1024).hexdigest())')"
sb_sum="$(python3 -c 'import hashlib;print(hashlib.sha256(b"fake secureboot iso "*1024).hexdigest())')"

write_versions() { # write_versions <plain pin> <secureboot pin>
  cat >"$sb/versions.env" <<EOF
TALOS_VERSION=v9.9.9
FACTORY_URL=http://127.0.0.1:$port
SCHEMATIC_MINI01_ID=$id
ASSET_MINI01_ISO_SHA256=$1
ASSET_MINI01_ISO_SECUREBOOT_SHA256=$2
EOF
}
run() { # run <kind> -> sets rc, out, err
  rc=0
  out="$(TAL_CACHE="$work/cache" bash "$sb/fetch-assets.sh" mini01 "$1" 2>"$work/err")" || rc=$?
  err="$(cat "$work/err")"
}

fails=0
check() { # check <name> <condition result 0|1>
  if [[ "$2" == 0 ]]; then tal_finding "$1" PASS "ok"; else
    tal_finding "$1" FAIL "unexpected behaviour"
    fails=$((fails + 1))
  fi
}

# 1. first fetch: marker -> exit 3, hash printed, versions.env untouched
write_versions "$plain_sum" UNPINNED_UNTIL_FIRST_FETCH
before="$(sha_of "$sb/versions.env")"
run iso-secureboot
check first-fetch-exit3 "$([[ $rc == 3 ]] && echo 0 || echo 1)"
check first-fetch-prints-hash "$([[ "$err" == *"$sb_sum"* ]] && echo 0 || echo 1)"
check first-fetch-no-edit "$([[ "$(sha_of "$sb/versions.env")" == "$before" ]] && echo 0 || echo 1)"

# 2. pinned right -> exit 0 and a path that exists
write_versions "$plain_sum" "$sb_sum"
run iso
check pinned-plain-exit0 "$([[ $rc == 0 && -f "$out" ]] && echo 0 || echo 1)"
run iso-secureboot
check pinned-secureboot-exit0 "$([[ $rc == 0 && -f "$out" && "$out" == *-sb-* ]] && echo 0 || echo 1)"

# 3. wrong pin -> exit 1 and the file is deleted
write_versions "$(printf 'b%.0s' $(seq 1 64))" "$sb_sum"
rm -f "$work"/cache/*
run iso
check wrong-pin-exit1 "$([[ $rc == 1 ]] && echo 0 || echo 1)"
check wrong-pin-deletes-file "$([[ -z "$(ls -A "$work/cache")" ]] && echo 0 || echo 1)"

# 4. a cached file with the wrong content is replaced, not trusted
write_versions "$plain_sum" "$sb_sum"
mkdir -p "$work/cache"
run iso
cached="$out"
echo junk >"$cached"
run iso
check stale-cache-replaced "$([[ $rc == 0 && "$(sha_of "$out")" == "$plain_sum" ]] && echo 0 || echo 1)"

# 5. PINS-PENDING stops the script
touch "$sb/PINS-PENDING"
run iso
check pins-pending-exit1 "$([[ $rc == 1 ]] && echo 0 || echo 1)"
rm -f "$sb/PINS-PENDING"

# 6. the secure boot kind is refused for the base schematic
run iso-secureboot
check secureboot-ok-for-mini01 "$([[ $rc == 0 ]] && echo 0 || echo 1)"
cp "$sb/schematics/mini01.yaml" "$sb/schematics/base.yaml"
cat >>"$sb/versions.env" <<EOF
SCHEMATIC_BASE_ID=$id
ASSET_BASE_ISO_SHA256=$plain_sum
EOF
rc=0
TAL_CACHE="$work/cache" bash "$sb/fetch-assets.sh" base iso-secureboot >/dev/null 2>&1 || rc=$?
check secureboot-refused-for-base "$([[ $rc == 2 ]] && echo 0 || echo 1)"

((fails == 0)) || tal_die "$fails fetch-assets behaviours were wrong"
tal_report "FETCH_ASSETS_NEGATIVE=pass"
