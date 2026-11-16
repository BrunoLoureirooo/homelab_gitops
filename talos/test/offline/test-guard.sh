#!/usr/bin/env bash
# Negative controls for .github/scripts/check-backups-06.sh (plan 15-06): copy the relevant tree
# to a temporary directory, plant one defect at a time, and require the guard to FAIL on it.
# A guard that never fires proves nothing.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0

fresh_copy() {
  rm -rf "$work/t"
  mkdir -p "$work/t/.github"
  cp -R "$repo/talos" "$work/t/talos"
  cp -R "$repo/docs" "$work/t/docs"
  cp -R "$repo/argocd" "$work/t/argocd"
  cp -R "$repo/.github/scripts" "$work/t/.github/scripts"
}

run_guard() {
  (cd "$work/t" && BACKUP_GUARD_NO_OFFLINE=1 bash .github/scripts/check-backups-06.sh)
}

# expect_fail NAME PATTERN: the guard must exit non-zero and print a FAIL line matching PATTERN.
expect_fail() {
  local name="$1" pattern="$2" out rc
  out="$(run_guard 2>&1)"
  rc=$?
  if [[ "$rc" -ne 0 ]] && grep -q "$pattern" <<<"$out"; then
    echo "OK   guard fires: $name"
    pass=$((pass + 1))
  else
    echo "FAIL guard did not fire: $name (exit $rc)"
    fail=$((fail + 1))
  fi
}

fresh_copy
out="$(run_guard 2>&1)"
rc=$?
if [[ "$rc" -eq 0 ]]; then
  echo "OK   guard is green on the unmodified tree"
  pass=$((pass + 1))
else
  echo "FAIL guard is not green on the unmodified tree"
  echo "$out" | head -5
  fail=$((fail + 1))
fi

# The planted values are assembled at run time so this file does not trip the guard itself.
sfx="ts"
fresh_copy
printf '\nsee https://example.%s.net/x\n' "$sfx" >>"$work/t/docs/dr/talos-backups.md"
expect_fail "tailnet name in docs" "host-details: tailnet name"

oct="101"
fresh_copy
printf '\naddress 100.%s.102.103\n' "$oct" >>"$work/t/docs/dr/talos-backups.md"
expect_fail "Tailscale CGNAT address in docs" "host-details: Tailscale CGNAT"

host="50"
fresh_copy
printf '\nvictus is 192.168.1.%s\n' "$host" >>"$work/t/docs/dr/talos-backups.md"
expect_fail "private address in docs" "host-details: private address"

fresh_copy
printf 'apiVersion: v1\nkind: Secret\nmetadata: { name: x }\n' >"$work/t/talos/sealed-secrets/oops.yaml"
expect_fail "raw Secret in the sealed-secrets directory" "raw-secret"

fresh_copy
printf 'apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\nmetadata: { name: x }\n' >"$work/t/talos/sealed-secrets/ok.yaml"
printf 'resources:\n  - ok.yaml\n  - missing.yaml\n' >>"$work/t/talos/sealed-secrets/kustomization.yaml"
sed -i.bak 's/^resources: \[\]$//' "$work/t/talos/sealed-secrets/kustomization.yaml"
expect_fail "kustomization lists a file that does not exist" "lists a missing file"

fresh_copy
sed -i.bak 's#^LITESTREAM_IMAGE_TAG=.*#LITESTREAM_IMAGE_TAG=latest#' "$work/t/talos/dr/images.env"
expect_fail "image tagged latest" "pins"

fresh_copy
sed -i.bak 's#docker.io/litestream/litestream\n *tag: 0.3.13#x#; s#tag: 0.3.13#tag: 0.3.99#' "$work/t/talos/values/vaultwarden.yaml"
expect_fail "manifest tag differs from images.env" "pins"

fresh_copy
printf '# hand edit\n' >>"$work/t/talos/manifests/immich-infra/immich-infra.yaml"
expect_fail "rendered immich manifest edited by hand" "overlay"

fresh_copy
sed -i.bak '/^# talos-job:/d' "$work/t/talos/test/jobs/cnpg-pitr.sh"
expect_fail "job without a header" "jobs"

echo "---- $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
