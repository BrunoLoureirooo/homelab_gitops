#!/usr/bin/env bash
# Fetch a pinned Talos asset from the Image Factory.
#
#   fetch-assets.sh <schematic-name> iso|iso-secureboot|installer-ref|installer-secureboot-ref
#
# iso            download metal-amd64.iso for the schematic into TAL_CACHE
#                (default ./.cache), verify the pinned sha256, print the path
# iso-secureboot same for metal-amd64-secureboot.iso (mini01 and mini02 only),
#                pinned by ASSET_<NAME>_ISO_SECUREBOOT_SHA256
# installer-ref  print factory.talos.dev/installer/<id>:<TALOS_VERSION>
# installer-secureboot-ref
#                print factory.talos.dev/installer-secureboot/<id>:<TALOS_VERSION>
#                (the UKI installer; plan 15-04's Secure Boot upgrade path)
#
# The Factory serves no .sha256 on the free tier, so the hash is OURS: a pin of
# UNPINNED_UNTIL_FIRST_FETCH downloads, prints the computed hash and exits 3
# ("review and pin"; versions.env is never edited by this script). A pin that
# does not match exits 1 and deletes the downloaded file.
#
# The schematic file talos/schematics/<name>.yaml is POSTed to the factory and
# the returned id must equal the pinned SCHEMATIC_<NAME>_ID, so a changed file
# or a changed factory answer fails loudly.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage="usage: fetch-assets.sh <schematic-name> iso|iso-secureboot|installer-ref|installer-secureboot-ref"
name="${1:?$usage}"
what="${2:?$usage}"
[[ "$name" =~ ^[a-z0-9]+$ ]] || {
  echo "::error::bad schematic name" >&2
  exit 2
}

if [[ -e "$here/PINS-PENDING" ]]; then
  echo "::error::pins are pending (talos/PINS-PENDING): run talos/refresh-pins.sh --write first" >&2
  exit 1
fi

# shellcheck source=/dev/null
. "$here/versions.env"
up="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
id_var="SCHEMATIC_${up}_ID"
sha_var="ASSET_${up}_ISO_SHA256"
asset=metal-amd64.iso
tag=plain
case "$what" in
  iso-secureboot)
    [[ "$name" == mini01 || "$name" == mini02 ]] || {
      echo "::error::iso-secureboot exists only for mini01 and mini02" >&2
      exit 2
    }
    sha_var="ASSET_${up}_ISO_SECUREBOOT_SHA256"
    asset=metal-amd64-secureboot.iso
    tag=sb
    ;;
  iso | installer-ref | installer-secureboot-ref) ;;
  *)
    echo "$usage" >&2
    exit 2
    ;;
esac
want_id="${!id_var:-}"
want_sha="${!sha_var:-}"
[[ "$want_id" =~ ^[0-9a-f]{64}$ ]] || {
  echo "::error::$id_var is not a pinned 64-hex id" >&2
  exit 1
}

schematic="$here/schematics/$name.yaml"
[[ -f "$schematic" ]] || {
  echo "::error::no schematic $schematic" >&2
  exit 1
}

if [[ "$what" == installer-ref ]]; then
  echo "factory.talos.dev/installer/${want_id}:${TALOS_VERSION}"
  exit 0
fi
if [[ "$what" == installer-secureboot-ref ]]; then
  echo "factory.talos.dev/installer-secureboot/${want_id}:${TALOS_VERSION}"
  exit 0
fi

first_fetch=0
if [[ "$want_sha" == UNPINNED_UNTIL_FIRST_FETCH ]]; then
  first_fetch=1
elif ! [[ "$want_sha" =~ ^[0-9a-f]{64}$ ]]; then
  echo "::error::$sha_var is not a pinned sha256" >&2
  exit 1
fi

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

got_id="$(curl --fail --silent --show-error --retry 5 -X POST --data-binary "@$schematic" "$FACTORY_URL/schematics" | jq -r '.id')"
if [[ "$got_id" != "$want_id" ]]; then
  echo "::error::schematic id changed for $name (the pin in versions.env no longer matches the factory answer)" >&2
  exit 1
fi

cache="${TAL_CACHE:-$PWD/.cache}"
mkdir -p "$cache"
iso="$cache/talos-${name}-${tag}-${TALOS_VERSION}-${want_id:0:12}.iso"
url="$FACTORY_URL/image/${want_id}/${TALOS_VERSION}/${asset}"

if ((first_fetch)); then
  curl --fail --silent --show-error --location --retry 5 -o "$iso.part" "$url"
  mv "$iso.part" "$iso"
  echo "FIRST-FETCH $sha_var=$(sha_of "$iso")" >&2
  echo "first download: review the hash above, put it in talos/versions.env as $sha_var and rerun" >&2
  exit 3
fi

if [[ ! -f "$iso" || "$(sha_of "$iso")" != "$want_sha" ]]; then
  curl --fail --silent --show-error --location --retry 5 -o "$iso.part" "$url"
  mv "$iso.part" "$iso"
fi
if [[ "$(sha_of "$iso")" != "$want_sha" ]]; then
  rm -f "$iso"
  echo "::error::ISO sha256 does not match $sha_var (file deleted)" >&2
  exit 1
fi
echo "$iso"
