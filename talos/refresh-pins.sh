#!/usr/bin/env bash
# Compute every pin in versions.env from the upstream sources. Needs internet.
# Without --write the proposal goes to versions.env.proposed (gitignored, next
# to the real file); with --write it replaces versions.env and removes
# talos/PINS-PENDING.
#
#   refresh-pins.sh [--write]
#
# Values that stay manual: TALOS_VERSION, K8S_VERSION, KUBECTL_VERSION,
# SOPS_VERSION, AGE_VERSION, FACTORY_URL (edit them first, then run this).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
write=0
[[ "${1:-}" == "--write" ]] && write=1

# shellcheck source=/dev/null
. "$here/versions.env"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

dl() { curl --fail --silent --show-error --retry 5 -L -o "$2" "$1"; }
sum() { sha256sum "$1" | cut -d' ' -f1; }

dl "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-linux-amd64" "$work/talosctl"
dl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" "$work/kubectl"
dl "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64" "$work/sops"
dl "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz" "$work/age.tgz"

pairs=(
  "TALOSCTL_SHA256=$(sum "$work/talosctl")"
  "KUBECTL_SHA256=$(sum "$work/kubectl")"
  "SOPS_SHA256=$(sum "$work/sops")"
  "AGE_SHA256=$(sum "$work/age.tgz")"
)

dl "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCALPATH_VERSION}/deploy/local-path-storage.yaml" "$work/local-path.yaml"
pairs+=("LOCALPATH_MANIFEST_SHA256=$(sum "$work/local-path.yaml")")

for name in base mini01 mini02 mini03 upgradetarget; do
  up="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
  id="$(curl --fail --silent --show-error --retry 5 -X POST --data-binary "@$here/schematics/$name.yaml" "$FACTORY_URL/schematics" | jq -r '.id')"
  [[ "$id" =~ ^[0-9a-f]{64}$ ]] || {
    echo "refresh-pins: no schematic id for $name" >&2
    exit 1
  }
  dl "$FACTORY_URL/image/${id}/${TALOS_VERSION}/metal-amd64.iso" "$work/$name.iso"
  pairs+=("SCHEMATIC_${up}_ID=$id" "ASSET_${up}_ISO_SHA256=$(sum "$work/$name.iso")")
  if [[ "$name" == mini01 ]]; then
    dl "$FACTORY_URL/image/${id}/${TALOS_VERSION}/metal-amd64-secureboot.iso" "$work/mini01-sb.iso"
    pairs+=("ASSET_MINI01_ISO_SECUREBOOT_SHA256=$(sum "$work/mini01-sb.iso")")
  fi
done

out="$here/versions.env.proposed"
cp "$here/versions.env" "$out"
for p in "${pairs[@]}"; do
  k="${p%%=*}"
  v="${p#*=}"
  sed -i.bak "s|^${k}=.*|${k}=${v}|" "$out"
done
rm -f "$out.bak"

if ((write)); then
  mv "$out" "$here/versions.env"
  rm -f "$here/PINS-PENDING"
  echo "refresh-pins: versions.env updated, PINS-PENDING removed"
else
  echo "refresh-pins: proposal written to $out (review, then rerun with --write)"
fi
