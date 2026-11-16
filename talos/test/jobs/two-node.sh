#!/usr/bin/env bash
# talos-job: kvm=yes timeout=60
# G1 row M2: control plane (mini01 role) plus worker (mini02 role). The worker
# joins, runs no etcd, and keeps its pods when the control plane VM is stopped.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"

cp_ip=192.168.100.11
w_ip=192.168.100.12

talos_ci_up two-node --two-node

# --- roles ------------------------------------------------------------------
tal_kubectl get node tal-cp -o json | jq -e '.metadata.labels | has("node-role.kubernetes.io/control-plane")' >/dev/null
tal_kubectl get node tal-w1 -o json | jq -e '.metadata.labels | has("node-role.kubernetes.io/control-plane") | not' >/dev/null

# --- etcd: Running on the control plane (positive control), absent on the worker ----
TAL_APID_PORT=$TAL_CP_APID TAL_NODE=$cp_ip tal_ctl service etcd | grep -q Running
TAL_APID_PORT=$TAL_W_APID TAL_NODE=$w_ip tal_ctl service kubelet | grep -q Running
if TAL_APID_PORT=$TAL_W_APID TAL_NODE=$w_ip tal_ctl service etcd >/dev/null 2>&1; then
  tal_die "etcd answered on the worker"
fi
tal_report "WORKER_NO_ETCD=ok"
tal_finding WORKER-NO-ETCD PASS "etcd Running on the control plane, absent on the worker"

# --- a workload pinned to the worker ---------------------------------------
tal_kubectl create deployment pause-w --image=registry.k8s.io/pause:3.10 --replicas=1
tal_kubectl patch deployment pause-w -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"tal-w1"}}}}}'
tal_kubectl rollout status deployment/pause-w --timeout=300s
node="$(tal_kubectl get pod -l app=pause-w -o jsonpath='{.items[0].spec.nodeName}')"
[[ "$node" == tal-w1 ]] || tal_die "pause-w landed on $node, not tal-w1"
on_cp="$(tal_kubectl get pods -A -l app=pause-w --field-selector spec.nodeName=tal-cp -o name | wc -l)"
[[ "$on_cp" -eq 0 ]] || tal_die "a pause-w pod runs on the control plane"
tal_report "TWO_NODE=ok"
tal_finding TWO-NODE PASS "control plane and worker Ready, workload on the worker only"

# --- the worker keeps its pods when the control plane is down ---------------
tal_stop two-node-cp
sleep 60
containers="$(TAL_APID_PORT=$TAL_W_APID TAL_NODE=$w_ip tal_ctl containers -k)"
if ! grep -E 'default/pause-w-[^ ]+:pause:' <<<"$containers" | grep -q RUNNING; then
  echo "$containers"
  tal_die "the pause container is not Running on the worker after the control plane stopped"
fi
tal_report "WORKER_KEEPS_PODS_CP_DOWN=ok"
tal_finding WORKER-PODS-CP-DOWN PASS "pause container still Running 60 s after the control plane stopped"
