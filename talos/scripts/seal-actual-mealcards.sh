#!/usr/bin/env bash
# Seal the Coverflex importer's credentials into talos/sealed-secrets/actual-mealcards-secrets.yaml.
#
#   seal-actual-mealcards.sh [CONTEXT]        (default context: admin@homelab-ts)
#
# Run it by hand AFTER Actual is running and you hold the Coverflex token (docs/plans/actual-budget.md,
# section 7a). Each value is read from the terminal with echo off, kept in environment variables of this
# process only, and never printed or written in the clear. The SealedSecret is encrypted against the LIVE
# controller certificate (kubeseal --fetch-cert), not the older certificate committed in the repo.
# Reads the cluster (certificate only); changes nothing on it.
set -euo pipefail

ctx="${1:-admin@homelab-ts}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
troot="$(cd "$here/.." && pwd)"
out="$troot/sealed-secrets/actual-mealcards-secrets.yaml"
kz="$troot/sealed-secrets/kustomization.yaml"

for t in kubeseal jq kubectl; do
  command -v "$t" >/dev/null 2>&1 || { echo "seal-actual-mealcards: $t is not installed" >&2; exit 5; }
done
[[ ! -e "$out" ]] || { echo "seal-actual-mealcards: $out already exists; delete it first to re-seal" >&2; exit 1; }

# name:required (ACTUAL_FILE_PASSWORD only with end-to-end encryption; press Enter to skip it)
keys=(
  "ACTUAL_SERVER_PASSWORD:1"
  "ACTUAL_SYNC_ID:1"
  "COVERFLEX_USERNAME:1"
  "COVERFLEX_PASSWORD:1"
  "COVERFLEX_USER_AGENT_TOKEN:1"
  "ACTUAL_FILE_PASSWORD:0"
)
names=()
for spec in "${keys[@]}"; do
  k="${spec%%:*}"
  req="${spec##*:}"
  read -rsp "$k (hidden$([[ "$req" == 0 ]] && echo ', Enter to skip')): " v
  echo
  if [[ -z "$v" ]]; then
    [[ "$req" == 0 ]] && continue
    echo "seal-actual-mealcards: $k is required" >&2
    exit 1
  fi
  export "SEALV_$k=$v"
  unset v
  names+=("$k")
done

cert="$(mktemp "${TMPDIR:-/tmp}/sscert.XXXXXX")"
trap 'rm -f "$cert"' EXIT
kubeseal --context "$ctx" --controller-name sealed-secrets --controller-namespace kube-system --fetch-cert >"$cert" 2>/dev/null ||
  { echo "seal-actual-mealcards: could not fetch the controller certificate from $ctx" >&2; exit 1; }

keys_json="$(printf '%s\n' "${names[@]}" | jq -R . | jq -sc .)"
jq -n --argjson keys "$keys_json" '
  {apiVersion: "v1", kind: "Secret",
   metadata: {name: "actual-mealcards-secrets", namespace: "homeserver"}, type: "Opaque",
   data: ($keys | map({key: ., value: (env["SEALV_" + .] | @base64)}) | from_entries)}' |
  KUBECONFIG=/dev/null kubeseal --cert "$cert" --format yaml >"$out"

grep -q 'kind: SealedSecret' "$out" || { rm -f "$out"; echo "seal-actual-mealcards: sealing failed" >&2; exit 1; }

if ! grep -qF -- "- actual-mealcards-secrets.yaml" "$kz"; then
  printf '  - actual-mealcards-secrets.yaml\n' >>"$kz"
fi
echo "sealed $out (${#names[@]} keys) and listed it in talos/sealed-secrets/kustomization.yaml"
echo "next: commit both files, set replicas to 1 in talos/manifests/actual-budget/mealcards.yaml, merge, sync"
