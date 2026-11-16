#!/usr/bin/env bash
# talos-job: kvm=yes timeout=45
# G1 finding PLATFORM-SYNC (plan 15-03 task 1): a real app from the GENERATED
# Talos app set (cluster-baseline, with the Talos StorageClass and namespace
# labels) syncs and is Healthy on a Talos CI cluster running Argo CD.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"
# shellcheck source=talos/test/lib-platform.sh
. "$here/../lib-platform.sh"

tal_platform_up
tal_bootstrap_only cluster-baseline

read -r sync health <<<"$(tal_app_state cluster-baseline)"
tal_report "platform cluster-baseline ${sync} ${health}"
if [[ "$sync" == Synced && "$health" == Healthy ]]; then
  # the generated copy is what ran: the StorageClass has the Talos provisioner
  prov="$(tal_kubectl get storageclass topolvm-fast -o jsonpath='{.provisioner}' 2>/dev/null || true)"
  priv="$(tal_kubectl get namespace homeserver -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || true)"
  tal_report "STORAGECLASS_PROVISIONER=${prov}"
  tal_report "HOMESERVER_PSA=${priv}"
  if [[ "$priv" == privileged ]]; then
    tal_finding PLATFORM-SYNC PASS "cluster-baseline Synced and Healthy from the generated set (topolvm-fast provisioner: ${prov:-none})"
  else
    tal_finding PLATFORM-SYNC FAIL "cluster-baseline synced but the homeserver namespace lacks the privileged label (got '${priv}')"
  fi
else
  tal_finding PLATFORM-SYNC FAIL "cluster-baseline is ${sync} ${health}"
fi
tal_summary
