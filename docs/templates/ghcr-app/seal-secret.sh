#!/usr/bin/env bash
# Seal an app's keys into talos/sealed-secrets/<app>-secrets.yaml (namespace homeserver).
#
#   docs/templates/ghcr-app/seal-secret.sh <app> <KEY> [<KEY>...]
#
# Prompts for each value with echo off, builds the Secret in memory and pipes it through kubeseal
# with the repo's public certificate. Values travel in environment variables, never in a command
# line, a file, or shell history. Each KEY becomes an environment variable of that name in the pod
# (the Deployment uses envFrom). Then the file is listed in talos/sealed-secrets/kustomization.yaml.
# Needs kubeseal and jq; no cluster access (the certificate is committed).
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: seal-secret.sh <app> <KEY> [<KEY>...]" >&2
  exit 64
fi
app="$1"
shift
[[ "$app" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "app must be a DNS label" >&2; exit 64; }
for k in "$@"; do
  [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "key '$k' must be a valid environment variable name" >&2; exit 64; }
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
cert="$root/argocd/sealed-secrets/pub-cert.pem"
out="$root/talos/sealed-secrets/$app-secrets.yaml"
kz="$root/talos/sealed-secrets/kustomization.yaml"

[[ -f "$cert" ]] || { echo "missing $cert" >&2; exit 1; }
[[ ! -e "$out" ]] || { echo "$out already exists; remove it first to re-seal" >&2; exit 1; }
for t in kubeseal jq; do command -v "$t" >/dev/null || { echo "$t not found" >&2; exit 1; }; done

for k in "$@"; do
  read -rsp "value for $k (hidden): " v
  echo
  [[ -n "$v" ]] || { echo "empty value for $k" >&2; exit 1; }
  export "SEALV_$k=$v"
  unset v
done

keys="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
jq -n --arg name "$app-secrets" --argjson keys "$keys" '
  {apiVersion: "v1", kind: "Secret",
   metadata: {name: $name, namespace: "homeserver"}, type: "Opaque",
   data: ($keys | map({key: ., value: (env["SEALV_" + .] | @base64)}) | from_entries)}' |
  KUBECONFIG=/dev/null kubeseal --cert "$cert" --format yaml >"$out"

grep -q 'kind: SealedSecret' "$out" || { rm -f "$out"; echo "sealing failed" >&2; exit 1; }

# list it under resources: (the file ends with the resources list)
if ! grep -qF -- "- $app-secrets.yaml" "$kz"; then
  printf '  - %s-secrets.yaml\n' "$app" >>"$kz"
fi
echo "sealed $out ($# keys) and listed it in talos/sealed-secrets/kustomization.yaml"
echo "commit it; the talos-sealed-secrets app syncs on its own"
