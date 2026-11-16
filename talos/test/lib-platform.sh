#!/usr/bin/env bash
# Helpers of the platform jobs (plan 15-03). Source it after talos/test/lib.sh in
# a job script that already ran `set -euo pipefail`; never execute it.
# shellcheck shell=bash

TAL_REPO_URL="https://github.com/BrunoLoureirooo/homelab_gitops"
TAL_PL_CLUSTER="talos-ci" # the kube context is admin@talos-ci; the scripts refuse any other

# tal_platform_up: a single-node Talos CI cluster plus Argo CD (with a credential
# for the private repository from the job's read-only token).
tal_platform_up() {
  talos_ci_up "$TAL_PL_CLUSTER"
  command -v helm >/dev/null || tal_die "helm is not installed on this runner"
  : "${TAL_REPO_TOKEN:?TAL_REPO_TOKEN (the read-only token of the job) is not set}"
  : "${TAL_REVISION:?TAL_REVISION (the commit under test) is not set}"
  bash "$TAL_ROOT/install-argocd.sh" --repo-url "$TAL_REPO_URL" --repo-token-env TAL_REPO_TOKEN
}

# tal_bootstrap_only <step> [extra bootstrap args...]: apply every Application at
# the commit under test and sync just one step.
tal_bootstrap_only() {
  local step="$1"
  shift
  bash "$TAL_ROOT/bootstrap-argocd.sh" --ci --yes --revision "$TAL_REVISION" --only "$step" "$@"
}

# tal_app_state <app> -> "<sync> <health>"
tal_app_state() {
  tal_kubectl -n argocd get application "$1" -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null || echo "Unknown Unknown"
}

# tal_throwaway_sealing_key <file>: a self-signed key pair as a Sealed Secrets
# controller key Secret. Exists only on the runner; sealed secrets of the repo do
# not decrypt with it, which is the point of the ratchet's `secrets` line.
tal_throwaway_sealing_key() {
  local dir="$TAL_WORK/sealkey"
  mkdir -p "$dir"
  chmod 700 "$dir"
  openssl req -x509 -nodes -newkey rsa:4096 -keyout "$dir/tls.key" -out "$dir/tls.crt" -subj "/CN=sealed-secret/O=sealed-secret" -days 2 >/dev/null 2>&1
  tal_kubectl -n kube-system create secret tls sealed-secrets-key-ci --cert="$dir/tls.crt" --key="$dir/tls.key" --dry-run=client -o yaml |
    tal_kubectl label --local -f - sealedsecrets.bitnami.com/sealed-secrets-key=active -o yaml >"$1"
  chmod 600 "$1"
  # the key bytes are secrets: mask them and make sure the scrubber removes them
  while IFS= read -r line; do
    [[ ${#line} -gt 12 ]] || continue
    echo "::add-mask::$line"
    printf '%s\n' "$line" >>"$TAL_WORK/mask.list"
  done < <(grep -E 'tls\.(crt|key):' "$1" | awk '{print $2}')
}
