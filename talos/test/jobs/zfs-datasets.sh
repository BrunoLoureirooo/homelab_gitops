#!/usr/bin/env bash
# talos-job: kvm=no timeout=30
# WP4: CI integration test for the ZFS datasets Job (talos/storage/zfs-datasets-job.yaml).
# Applies the Job with default quotas, waits for completion, verifies datasets exist.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
talos_dir="$(cd "$here/../.." && pwd)"
# shellcheck source=/dev/null
. "$talos_dir/test/lib.sh"

test_job_apply() {
  local kc
  kc=(kubectl --kubeconfig "${TAL_WORK:?}/kubeconfig")

  echo "Applying ZFS datasets Job with defaults..."
  "${kc[@]}" apply -f "$talos_dir/storage/zfs-datasets-job.yaml"

  echo "Waiting for Job completion..."
  "${kc[@]}" -n kube-system wait job/zfs-datasets --for condition=complete --timeout=5m

  echo "Job completed. Output:"
  "${kc[@]}" -n kube-system logs job/zfs-datasets
}

test_datasets_exist() {
  local kc
  kc=(kubectl --kubeconfig "${TAL_WORK:?}/kubeconfig")

  echo "Verifying datasets exist..."
  if "${kc[@]}" -n kube-system run test-zfs --restart=Never --image=docker.io/library/busybox:1.37 --hostPID --privileged --timeout=60 -- \
    sh -c "nsenter -t 1 -m -- zfs list tank/nas tank/immich tank/backups" 2>/dev/null; then
    tal_report "ASSERT datasets-exist PASS"
  else
    tal_report "ASSERT datasets-exist FAIL"
    tal_finding ZFS-DS FAIL "one or more datasets missing"
    exit 1
  fi
}

# Main
test_job_apply
test_datasets_exist
tal_finding ZFS-DS PASS "Job applied and all datasets created"
