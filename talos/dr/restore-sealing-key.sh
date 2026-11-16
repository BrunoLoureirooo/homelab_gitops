#!/usr/bin/env bash
# Put the Sealed Secrets controller's private key into an EMPTY cluster BEFORE the
# controller starts (plan 15-06 Task 2, the order proven in plans 01-08 and 01-12).
#
#   restore-sealing-key.sh FILE (--ci | --live CONTEXT) [--namespace kube-system]
#
# FILE is the offline backup of the key Secret(s) (the output of
#   kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml).
# The script applies it into the namespace the controller uses (argocd/apps/sealed-secrets.yaml:
# kube-system), creating the namespace if needed. Never prints key material.
#
# Safety: refuses unless the context is the Talos CI context (--ci) or typed back (--live CONTEXT);
# refuses when the namespace already holds a key Secret (a running controller would have
# generated one; restoring on top would split the keys), exit 4.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/dr/common.sh
source "$here/common.sh"

file="${1:-}"
[[ -n "$file" && "$file" != --* ]] || dr_die 1 "usage: restore-sealing-key.sh FILE (--ci | --live CONTEXT) [--namespace NS]"
shift

mode=""
live_ctx=""
ns="kube-system"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ci) mode=ci; shift ;;
    --live) mode=live; live_ctx="${2:-}"; shift 2 || shift ;;
    --namespace) ns="${2:?}"; shift 2 ;;
    *) dr_die 1 "unknown argument: $1" ;;
  esac
done

dr_need kubectl
[[ -f "$file" ]] || dr_die 5 "key file not found"
dr_guard_context "$mode" "$live_ctx"

existing="$(kubectl -n "$ns" get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o name 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${existing:-0}" -gt 0 ]]; then
  dr_die 4 "refused: $ns already holds a sealed-secrets key; restoring now would create two active keys"
fi

kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n "$ns" -f "$file" >/dev/null
count="$(kubectl -n "$ns" get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o name | wc -l | tr -d ' ')"
[[ "$count" -ge 1 ]] || dr_die 1 "key Secret not found after apply"
echo "RESTORED keys=$count namespace=$ns"
