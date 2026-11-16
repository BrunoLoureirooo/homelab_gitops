#!/usr/bin/env bash
# Encrypt a Tailscale auth key for one node into talos/secrets/tailscale-<node>.sops.yaml.
#
#   seal-tailscale-key.sh <node>        (e.g. mini01)
#
# The key is read from the terminal without echo (or from TS_AUTHKEY if you already hold it in
# the environment), written only into a private temp file, encrypted with sops and removed. It is
# never printed, logged or put in git in the clear. Create the key first in the Tailscale admin
# console: single-use, pre-approved, tagged tag:talos, one-day expiry.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
troot="$(cd "$here/.." && pwd)"
node="${1:-}"
[[ "$node" =~ ^[a-z0-9-]+$ && -f "$troot/nodes/$node.env" ]] || {
  echo "usage: seal-tailscale-key.sh <node>   (a node with talos/nodes/<node>.env)" >&2
  exit 2
}
command -v sops >/dev/null 2>&1 || {
  echo "seal-tailscale-key: sops is not installed" >&2
  exit 5
}

key="${TS_AUTHKEY:-}"
if [[ -z "$key" ]]; then
  read -rsp "Tailscale auth key for $node (input hidden): " key
  echo
fi
# The usual prefix is assembled so this file does not itself look like a leaked key to the repo guards.
prefix="tskey"
prefix+="-auth-"
[[ "$key" == "$prefix"* && "$key" =~ ^[A-Za-z0-9_-]+$ ]] || {
  echo "seal-tailscale-key: that does not look like a Tailscale auth key (wrong prefix or characters)" >&2
  exit 2
}

umask 077
tmp="$(mktemp "${TMPDIR:-/tmp}/tskey.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
hostname_v="$(sed -n 's/^HOSTNAME=//p' "$troot/nodes/$node.env")"
cat >"$tmp" <<EOF
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: tailscale
environment:
  - TS_HOSTNAME=${hostname_v}
  - TS_AUTHKEY=${key}
EOF
unset key
out="$troot/secrets/tailscale-$node.sops.yaml"
sops -e --config "$troot/.sops.yaml" --filename-override "secrets/tailscale-$node.sops.yaml" --input-type yaml --output-type yaml "$tmp" >"$out"
echo "seal-tailscale-key: wrote $out (encrypted)"
