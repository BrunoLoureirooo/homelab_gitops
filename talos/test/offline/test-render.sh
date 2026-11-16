#!/usr/bin/env bash
# Offline checks of the rendered manifests and of the CI helper that reshapes them
# (plan 15-06). Needs yq and kubectl (its built-in kustomize); no cluster, no network.
# The bash -c snippets below are single-quoted on purpose: they expand inside the child shell.
# shellcheck disable=SC2016
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
pass=0
fail=0
ok() {
  echo "OK   $1"
  pass=$((pass + 1))
}
bad() {
  echo "FAIL $1"
  fail=$((fail + 1))
}
check() { # name command...
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}

# shellcheck source=talos/test/backup-lib.sh
source "$repo/talos/test/backup-lib.sh"

f="$repo/talos/manifests/immich-infra/immich-infra.yaml"

check "the committed immich overlay output is current" bash "$repo/talos/overlays/render.sh" --check
check "overlay output has a barman backup block on the Cluster" yq -e 'select(.kind == "Cluster") | .spec.backup.barmanObjectStore.destinationPath == "s3://immich-pg/"' "$f"
check "overlay output keeps the base Prune=false annotation" yq -e 'select(.kind == "Cluster") | .metadata.annotations["argocd.argoproj.io/sync-options"] == "Prune=false"' "$f"
check "overlay output has the SMB library claim" yq -e 'select(.kind == "PersistentVolumeClaim") | .metadata.name == "immich-library-smb"' "$f"
check "ScheduledBackup uses a six-field cron" yq -e 'select(.kind == "ScheduledBackup") | .spec.schedule | test("^[^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+$")' "$f"

BK_S3_GUEST="http://10.0.2.2:19000"
out="$(bk_immich_cluster_yaml immich-pg-restore --no-backup)"
check "CI cluster helper renames the cluster" bash -c 'yq -e ".metadata.name == \"immich-pg-restore\"" <<<"$1"' _ "$out"
check "CI cluster helper drops the backup block when asked" bash -c '! yq -e ".spec.backup" <<<"$1"' _ "$out"
check "CI cluster helper drops the priority class and storage class" bash -c '! yq -e ".spec.priorityClassName" <<<"$1" && ! yq -e ".spec.storage.storageClass" <<<"$1"' _ "$out"
check "CI cluster helper keeps the real image" bash -c 'yq -e ".spec.imageName | test(\"vectorchord\")" <<<"$1"' _ "$out"
out2="$(bk_immich_cluster_yaml immich-pg)"
check "CI cluster helper points archiving at the throwaway endpoint" bash -c 'yq -e ".spec.backup.barmanObjectStore.endpointURL == \"http://10.0.2.2:19000\"" <<<"$1"' _ "$out2"

check "backup-target builds" kubectl kustomize "$repo/talos/manifests/backup-target"
check "sealed-secrets directory builds (empty is valid)" kubectl kustomize "$repo/talos/sealed-secrets"
check "velero override makes the homeserver schedule daily" yq -e '.schedules."homeserver-nightly".schedule == "0 10 * * *"' "$repo/talos/values/velero.yaml"
check "litestream is only in the Talos values" bash -c '! grep -qi litestream "$1/argocd/values/vaultwarden.yaml" && grep -qi litestream "$1/talos/values/vaultwarden.yaml"' _ "$repo"

echo "---- $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
