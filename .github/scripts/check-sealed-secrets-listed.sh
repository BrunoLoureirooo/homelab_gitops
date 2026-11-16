#!/usr/bin/env bash
# CI guardrail: verify every SealedSecret YAML in talos/sealed-secrets/ (except
# kustomization.yaml) is listed under resources: in that kustomization.yaml, and
# that every file listed there actually exists on disk.
set -uo pipefail

root="${CHECK_ROOT:-.}"
cd "$root" || exit 2

kustomization="talos/sealed-secrets/kustomization.yaml"
dir="talos/sealed-secrets"

if [[ ! -f "$kustomization" ]]; then
  echo "FAIL: $kustomization not found"
  exit 1
fi

if [[ ! -d "$dir" ]]; then
  echo "FAIL: $dir not found"
  exit 1
fi

bad=0

if ! listed="$(yq -r '.resources[]' "$kustomization")"; then
  echo "FAIL: could not parse resources: in $kustomization"
  exit 1
fi

while IFS= read -r file; do
  base="$(basename "$file")"
  [[ "$base" == "kustomization.yaml" ]] && continue
  if ! grep -qxF "$base" <<<"$listed"; then
    echo "FAIL: $base is not listed under resources: in $kustomization"
    bad=1
  fi
done < <(find "$dir" -maxdepth 1 -name '*.yaml' -type f | sort)

while IFS= read -r base; do
  [[ -z "$base" ]] && continue
  if [[ ! -f "$dir/$base" ]]; then
    echo "FAIL: $base listed in resources: does not exist on disk"
    bad=1
  fi
done <<<"$listed"

if ((bad)); then
  exit 1
fi
echo "OK: SealedSecrets listed"
