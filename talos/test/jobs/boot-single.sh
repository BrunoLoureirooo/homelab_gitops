#!/usr/bin/env bash
# talos-job: kvm=yes timeout=45
# G1 row M1: the pinned Image Factory ISO installs and boots to a Ready node,
# runs a pod on the control plane, and the install survives a restart from the
# disk alone.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"

talos_ci_up boot-single
tal_report "BOOT_SINGLE=ok"
tal_finding BOOT-SINGLE PASS "ISO installed, bootstrapped, node Ready"
tal_report "TALOS_VERSION=${TALOS_VERSION}"
tal_report "K8S_SERVER_VERSION=$(tal_kubectl version -o json | jq -r '.serverVersion.gitVersion')"

# A workload schedules on the control plane (allowSchedulingOnControlPlanes).
tal_kubectl run pause --image=registry.k8s.io/pause:3.10 --restart=Never
tal_kubectl wait --for=jsonpath='{.status.phase}'=Running pod/pause --timeout=300s

read -r mem_total mem_avail <<<"$(tal_mem)"
tal_report "MEM_USED_MB=$((mem_total - mem_avail))"

# Restart from the disk only (no ISO): proves the install and the persisted state.
tal_stop boot-single
tal_boot "$TAL_WORK/boot-single.qcow2" boot-single
tal_wait_api 300
tal_wait_ready 300
tal_report "RESTART_FROM_DISK=ok"
tal_finding RESTART-DISK PASS "node Ready again from the disk alone"
