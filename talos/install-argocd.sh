#!/usr/bin/env bash
# Install Argo CD into the current cluster (plan 15-03): the Helm chart pinned as
# ARGOCD_CHART in talos/versions.env, server.insecure, no dex, no notifications.
#
#   install-argocd.sh [--repo-url URL --repo-token-env VAR]
#
# With --repo-url and --repo-token-env, the repository (private) gets a credential
# Secret built from the token in the named environment variable (CI passes the
# job's read-only GITHUB_TOKEN; it lives only in the throwaway cluster). The
# token is never printed. Refuses to run unless the kube context is named
# admin@talos-ci or TAL_ALLOW_ANY_CONTEXT=1 (a live install is a operator-run step).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$here/versions.env"
repo_url=""
token_env=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url)
      repo_url="${2:?--repo-url needs a URL}"
      shift 2
      ;;
    --repo-token-env)
      token_env="${2:?--repo-token-env needs a variable name}"
      shift 2
      ;;
    *)
      echo "usage: install-argocd.sh [--repo-url URL --repo-token-env VAR]" >&2
      exit 64
      ;;
  esac
done

ctx="$(kubectl config current-context 2>/dev/null || true)"
if [[ "$ctx" != admin@talos-ci && "${TAL_ALLOW_ANY_CONTEXT:-0}" != 1 ]]; then
  echo "install-argocd: refusing to run in context '${ctx:-none}' (expected admin@talos-ci)" >&2
  exit 3
fi
: "${ARGOCD_CHART:?ARGOCD_CHART is not set in talos/versions.env}"

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update argo >/dev/null
# The public address of the web UI (argocd.<tailnet>.ts.net) is a host detail, so it is not committed:
# set ARGOCD_DOMAIN in the environment to have Argo CD generate links with it.
domain_args=()
[[ -z "${ARGOCD_DOMAIN:-}" ]] || domain_args=(--set "global.domain=${ARGOCD_DOMAIN}")
if ! helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART" \
  --namespace argocd --create-namespace \
  --set dex.enabled=false --set notifications.enabled=false \
  --set-string 'configs.params.server\.insecure=true' \
  ${domain_args[@]+"${domain_args[@]}"} \
  --wait --timeout 10m >/dev/null; then
  echo "install-argocd: helm did not finish; the state of the argocd namespace follows" >&2
  kubectl -n argocd get pods -o wide 2>&1 | tail -n 20 >&2 || true
  kubectl -n argocd get events --sort-by=.lastTimestamp 2>&1 | tail -n 25 >&2 || true
  exit 1
fi
echo "install-argocd: Argo CD chart ${ARGOCD_CHART} installed"

# Web UI on the tailnet (needs the Tailscale operator; the Ingress waits for it if it is not up yet).
kubectl apply -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/manifests/argocd-tailnet/ingress.yaml" >/dev/null

if [[ -n "$repo_url" ]]; then
  [[ -n "$token_env" && -n "${!token_env:-}" ]] || {
    echo "install-argocd: --repo-token-env must name a set variable" >&2
    exit 2
  }
  kubectl -n argocd create secret generic repo-homelab \
    --from-literal=type=git \
    --from-literal=url="$repo_url" \
    --from-literal=username=x-access-token \
    --from-literal=password="${!token_env}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n argocd label secret repo-homelab argocd.argoproj.io/secret-type=repository --overwrite >/dev/null
  echo "install-argocd: repository credential created for the private repo"
fi
