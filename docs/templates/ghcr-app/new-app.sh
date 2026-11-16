#!/usr/bin/env bash
# Create the manifests for an app that runs a project's published GHCR image on mini01.
#
#   docs/templates/ghcr-app/new-app.sh <app> <image:tag> <port> [sha256-digest]
#
# Example:
#   docs/templates/ghcr-app/new-app.sh mytool ghcr.io/someone/mytool:v1.4.2 8080
#
# Without a digest the script asks ghcr.io for the tag's digest (curl and jq, no Docker needed), so
# the manifest is pinned to the exact image. Private package: export GHCR_USER and GHCR_TOKEN
# (a read:packages token) first. Writes talos/manifests/<app>/,
# talos/apps-src/<app>.yaml and the expectation line check-talos-apps requires; then run
# talos/render-apps.sh --force (see README.md).
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: new-app.sh <app> <image:tag> <port> [sha256-digest]" >&2
  exit 64
fi
app="$1" ref="$2" port="$3" digest="${4:-}"
digest="${digest#sha256:}"

[[ "$app" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "app must be a DNS label (lowercase, digits, dashes)" >&2; exit 64; }
[[ "$ref" =~ ^ghcr\.io/[a-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] || { echo "image must look like ghcr.io/<owner>/<name>:<tag> (lowercase path)" >&2; exit 64; }
[[ "$port" =~ ^[0-9]+$ ]] || { echo "port must be a number" >&2; exit 64; }
image="${ref%:*}" tag="${ref##*:}"
[[ "$tag" != "latest" ]] || { echo "pick a real version tag, not latest" >&2; exit 64; }

# Ask the registry for the tag's digest over HTTPS: needs only curl and jq, no Docker. A public
# package works anonymously; for a private one export GHCR_USER and GHCR_TOKEN (read:packages).
resolve_digest() {
  local repo="${image#ghcr.io/}" auth=() tok head
  [[ -n "${GHCR_USER:-}" && -n "${GHCR_TOKEN:-}" ]] && auth=(-u "$GHCR_USER:$GHCR_TOKEN")
  tok="$(curl -fsS ${auth[@]+"${auth[@]}"} "https://ghcr.io/token?scope=repository:$repo:pull" | jq -r '.token // empty')" || return 1
  [[ -n "$tok" ]] || return 1
  head="$(curl -fsSI -H "Authorization: Bearer $tok" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
    "https://ghcr.io/v2/$repo/manifests/$tag")" || return 1
  printf '%s\n' "$head" | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }'
}

if [[ -z "$digest" ]]; then
  digest="$(resolve_digest || true)"
  digest="${digest#sha256:}"
  [[ -n "$digest" ]] || { echo "could not resolve $ref. Wrong name or tag? For a private package export GHCR_USER and GHCR_TOKEN (read:packages) and retry, or pass the digest as the 4th argument." >&2; exit 1; }
  echo "resolved $ref to sha256:$digest"
fi
[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { echo "digest must be 64 hex characters" >&2; exit 64; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
man="$root/talos/manifests/$app"
src="$root/talos/apps-src/$app.yaml"

[[ ! -e "$man" && ! -e "$src" ]] || { echo "$app already exists; refusing to overwrite" >&2; exit 1; }
mkdir -p "$man"

# my-tool -> MY_TOOL, used for the <APP>_OUTPUT_DIR variable in the optional media-disk block
appvar="$(printf '%s' "$app" | tr 'a-z-' 'A-Z_')"

fill() {
  sed -e "s#__APPVAR__#$appvar#g" -e "s#__APP__#$app#g" -e "s#__IMAGE__#$image#g" -e "s#__TAG__#$tag#g" \
    -e "s#__PORT__#$port#g" -e "s#__DIGEST__#$digest#g" "$1"
}

for f in deployment service pvc ingress kustomization; do
  fill "$here/$f.yaml.tmpl" >"$man/$f.yaml"
done
fill "$here/app.yaml.tmpl" >"$src"

# check-talos-apps.sh wants one expectation line per Application.
printf '%-24s *       *       # manual sync; GHCR image app, needs its sealed %s-secrets\n' "$app" "$app" \
  >>"$root/talos/test/empty-cluster-expectations.txt"

echo "created talos/manifests/$app/ and talos/apps-src/$app.yaml"
echo "next: seal-secret.sh $app <KEY>..., edit deployment.yaml, then talos/render-apps.sh --force"
