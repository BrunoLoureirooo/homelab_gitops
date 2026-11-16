#!/usr/bin/env bash
# talos-job: kvm=yes timeout=45
# G1 finding CNI-MTU (plan 15-03 task 2): metrics-server works on Talos
# (`kubectl top nodes` prints numbers) and the pod MTU under Talos's default
# flannel is measured, so the Tailscale ProxyClass tunnel MTU (1150 + about 80
# bytes of WireGuard/UDP/IP overhead) can be confirmed or re-derived.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"
# shellcheck source=talos/test/lib-platform.sh
. "$here/../lib-platform.sh"
# shellcheck source=talos/test/lib-find.sh
. "$here/../lib-find.sh"

tal_platform_up
tal_bootstrap_only metrics-server
read -r ms_sync ms_health <<<"$(tal_app_state metrics-server)"
tal_report "metrics-server ${ms_sync} ${ms_health}"

# --- (a) kubectl top nodes prints numbers --------------------------------------------
top_ok=no
for _ in $(seq 1 40); do
  if tal_kubectl top nodes --no-headers 2>/dev/null | awk '{ if ($2 ~ /[0-9]/ && $4 ~ /[0-9]/) ok = 1 } END { exit ok ? 0 : 1 }'; then
    top_ok=yes
    break
  fi
  sleep 10
done
tal_report "TOP_NODES=${top_ok}"

# --- (b) the pod interface MTU and the node's physical MTU ------------------------------
tal_find_images
pod_mtu="$(tal_run_pod mtu-probe "$TAL_ALPINE" no 'cat /sys/class/net/eth0/mtu' | tr -d '[:space:]' || true)"
node_mtu=""
for ifname in $(tal_ctl ls /sys/class/net 2>/dev/null | awk 'NR > 1 {print $NF}'); do
  case "$ifname" in
    lo | flannel* | cni* | veth* | kube* | docker* | tailscale*) continue ;;
  esac
  v="$(tal_ctl read "/sys/class/net/${ifname}/mtu" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    node_mtu="$v"
    node_if="$ifname"
    break
  fi
done
tal_report "POD_MTU=${pod_mtu:-unknown}"
tal_report "NODE_MTU=${node_mtu:-unknown}"
tal_report "NODE_IF=${node_if:-unknown}"

# --- (c) a large packet within the cluster (single node: same-node check only) ----------
tal_report "CROSS_NODE_MTU=untested"

# --- (d) what the ProxyClass tunnel MTU must be -------------------------------------------
declared="$(grep -A1 'TS_DEBUG_MTU' "$TAL_ROOT/../argocd/manifests/tailscale-operator/proxyclass.yaml" | grep -oE '[0-9]{3,4}' | head -n1 || true)"
overhead=80
proxy_ok=unknown
if [[ "$pod_mtu" =~ ^[0-9]+$ && "$declared" =~ ^[0-9]+$ ]]; then
  if ((declared + overhead <= pod_mtu)); then proxy_ok=yes; else proxy_ok=no; fi
fi
needed=""
[[ "$pod_mtu" =~ ^[0-9]+$ ]] && needed=$((pod_mtu - overhead))
tal_report "CNI flannel POD_MTU=${pod_mtu:-unknown} NODE_MTU=${node_mtu:-unknown} PROXYCLASS_MTU_OK=${proxy_ok}"
tal_report "PROXYCLASS_DECLARED_MTU=${declared:-unknown} PROXYCLASS_MAX_MTU=${needed:-unknown}"

if [[ "$top_ok" == yes && "$pod_mtu" =~ ^[0-9]+$ && "$node_mtu" =~ ^[0-9]+$ ]]; then
  tal_finding CNI-MTU PASS "metrics work; flannel pod MTU ${pod_mtu} on a node MTU of ${node_mtu}; ProxyClass tunnel MTU ${declared:-?} (+${overhead}) fits: ${proxy_ok}"
else
  tal_finding CNI-MTU FAIL "top=${top_ok} pod_mtu=${pod_mtu:-none} node_mtu=${node_mtu:-none}"
fi
tal_summary
