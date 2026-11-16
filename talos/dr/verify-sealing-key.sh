#!/usr/bin/env bash
# Compare the live Sealed Secrets key with the offline copy (plan 15-06 Task 2).
#
#   verify-sealing-key.sh OFFLINE_FILE [--namespace kube-system]
#
# Read-only. Prints exactly one word: MATCH or DIFFERENT. Never prints a key,
# a fingerprint or a Secret value. Exit 0 on MATCH, 1 on DIFFERENT, 5 when a
# precondition is missing.
#
# What is compared: the SHA-256 of the certificate (tls.crt) of every active key
# in the cluster against the same for the offline file. MATCH means every key in
# the cluster is present in the offline file.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/dr/common.sh
source "$here/common.sh"

file="${1:-}"
[[ -n "$file" && "$file" != --* ]] || dr_die 1 "usage: verify-sealing-key.sh OFFLINE_FILE [--namespace NS]"
shift
ns="kube-system"
if [[ "${1:-}" == "--namespace" ]]; then
  ns="${2:?}"
fi

dr_need kubectl sha256sum base64
[[ -f "$file" ]] || dr_die 5 "offline file not found"

fingerprints_cluster() {
  kubectl -n "$ns" get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
    -o jsonpath='{range .items[*]}{.data.tls\.crt}{"\n"}{end}' |
    while IFS= read -r crt; do
      [[ -n "$crt" ]] && printf %s "$crt" | base64 -d | sha256sum | cut -d' ' -f1
    done | sort -u
}

fingerprints_file() {
  # The file is a List or a single Secret; read every tls.crt value by key name.
  grep -E '^[[:space:]]*tls\.crt:[[:space:]]' "$file" | awk '{print $2}' |
    while IFS= read -r crt; do
      printf %s "$crt" | base64 -d | sha256sum | cut -d' ' -f1
    done | sort -u
}

cluster="$(fingerprints_cluster)"
offline="$(fingerprints_file)"
[[ -n "$cluster" ]] || dr_die 5 "no key found in the cluster"
[[ -n "$offline" ]] || dr_die 5 "no key found in the offline file"

missing="$(comm -23 <(printf '%s\n' "$cluster") <(printf '%s\n' "$offline") | wc -l | tr -d ' ')"
if [[ "$missing" -eq 0 ]]; then
  echo MATCH
  exit 0
fi
echo DIFFERENT
exit 1
