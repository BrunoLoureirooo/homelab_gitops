#!/usr/bin/env bash
# Resolve the digest of every image in talos/dr/images.env and write it back.
# Needs network and one of: crane, skopeo, docker buildx. Run it where those
# exist (CI or your Mac), then commit the result. Prints `PIN <name> <digest>`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
envfile="$here/images.env"

resolve() {
  local ref="$1"
  if command -v crane >/dev/null 2>&1; then
    crane digest "$ref"
  elif command -v skopeo >/dev/null 2>&1; then
    skopeo inspect --format '{{.Digest}}' "docker://$ref"
  elif docker buildx version >/dev/null 2>&1; then
    docker buildx imagetools inspect "$ref" --format '{{.Manifest.Digest}}'
  else
    echo "need crane, skopeo or docker buildx" >&2
    return 1
  fi
}

names="$(grep -E '^[A-Z_]+_IMAGE_REPO=' "$envfile" | sed 's/_IMAGE_REPO=.*//')"
for n in $names; do
  repo="$(grep -E "^${n}_IMAGE_REPO=" "$envfile" | cut -d= -f2-)"
  tag="$(grep -E "^${n}_IMAGE_TAG=" "$envfile" | cut -d= -f2-)"
  digest="$(resolve "${repo}:${tag}")"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "unexpected digest for $n" >&2
    exit 1
  }
  sed -i.bak "s|^${n}_IMAGE_DIGEST=.*|${n}_IMAGE_DIGEST=${digest}|" "$envfile"
  echo "PIN $n $digest"
done
rm -f "$envfile.bak"
