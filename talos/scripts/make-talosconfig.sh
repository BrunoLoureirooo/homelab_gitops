#!/usr/bin/env bash
# Create the talosconfig your Mac needs (talosctl bootstrap, kubeconfig, upgrade, ...)
# from the encrypted secrets bundle. render.sh writes only the node config, so this is the
# step that gives you the client certificate for the cluster.
#
#   make-talosconfig.sh <node ip or name> [output file]     default output ~/.talos/config
#
# Needs the age key (SOPS_AGE_KEY_FILE or the default sops location), sops and talosctl.
# The decrypted bundle only exists in a private temp directory and is removed on exit;
# nothing secret is printed. The output file is created with mode 600.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
troot="$(cd "$here/.." && pwd)"
node="${1:-}"
out="${2:-$HOME/.talos/config}"
[[ -n "$node" ]] || {
  echo "usage: make-talosconfig.sh <node ip or name> [output file]" >&2
  exit 2
}
for t in sops talosctl; do
  command -v "$t" >/dev/null 2>&1 || {
    echo "make-talosconfig: $t is not installed" >&2
    exit 5
  }
done

# shellcheck source=/dev/null
. "$troot/cluster.env"
bundle="$troot/secrets/secrets.sops.yaml"
[[ -f "$bundle" ]] || {
  echo "make-talosconfig: no $bundle" >&2
  exit 5
}

umask 077
tmp="$(mktemp -d "${TMPDIR:-/tmp}/talosconfig.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
sops -d --input-type yaml --output-type yaml "$bundle" >"$tmp/secrets.yaml"
talosctl gen config "$CLUSTER_NAME" "https://${ENDPOINT_HOST}:${K8S_PORT}" \
  --with-secrets "$tmp/secrets.yaml" --output-types talosconfig --output "$tmp/talosconfig" --force >/dev/null

mkdir -p "$(dirname "$out")"
install -m 600 "$tmp/talosconfig" "$out"
talosctl --talosconfig "$out" config endpoint "$node" >/dev/null
talosctl --talosconfig "$out" config node "$node" >/dev/null
echo "make-talosconfig: wrote $out (endpoint and node set to $node)"
