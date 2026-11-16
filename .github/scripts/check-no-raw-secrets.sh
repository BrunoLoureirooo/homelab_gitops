#!/usr/bin/env bash
# CI guardrail: fail the build if a raw, unsealed `kind: Secret` is ever
# committed under argocd/ (outside charts/, where a vendored chart's own
# templates are a different concern kubeconform already treats specially).
# The whole point of argocd/sealed-secrets/README.md's workflow is that the
# ONLY secret-shaped object this repo ever commits is a SealedSecret
# (ciphertext) - this makes "someone commits the plaintext
# `kubectl create secret --dry-run -o yaml` intermediate instead of piping
# it through kubeseal first" fail CI instead of landing in a public repo.
set -uo pipefail

matches=$(grep -rnE '^kind:[[:space:]]*"?Secret"?[[:space:]]*$' argocd \
  --include='*.yaml' \
  | grep -v '/charts/' \
  || true)

if [ -n "$matches" ]; then
  echo "::error::Found a raw 'kind: Secret' committed under argocd/ - only 'kind: SealedSecret' (ciphertext) should ever be committed here. See argocd/sealed-secrets/README.md."
  echo "$matches"
  exit 1
fi

echo "OK: no raw Secret objects found under argocd/."
