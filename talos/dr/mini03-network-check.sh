#!/usr/bin/env bash
# Two-way pod traffic, MTU and time checks for mini03 (plan docs/plans/mini03-vm.md, WP10).
#
#   mini03-network-check.sh CONTEXT NODE_IP [NODE_IP...]
#
# Time sync and tun are read with talosctl on each node IP. Then two throwaway pods (one on
# mini01, one on mini03) in a scratch namespace each fetch a 3 MB file from the other, and the
# namespace is deleted. Prints results only, never addresses. Exit: 0 PASS, 1 FAIL, 5 usage.
set -euo pipefail
ctx="${1:-}"
shift || true
if [ -z "$ctx" ] || [ "$#" -lt 1 ]; then
  sed -n 2,7p "$0"
  exit 5
fi
NS=mini03-net
IMG="docker.io/library/busybox:1.36.1" # has httpd; alpine 3.22 does not
k() { kubectl --context "$ctx" "$@"; }
fail=0
ok() { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fail=1; }
trap 'k delete namespace "$NS" --wait=false --ignore-not-found >/dev/null 2>&1 || true' EXIT

echo "## time sync, links, tun (read-only)"
for ip in "$@"; do
  if talosctl -n "$ip" -e "$ip" get timestatus 2>/dev/null | grep -q true; then
    ok "time synced on a node"
  else
    bad "time not synced on a node"
  fi
  talosctl -n "$ip" -e "$ip" get links 2>/dev/null | grep -E "flannel|cni0" | awk '{print "      link line:", $0}' || true
done
if talosctl -n "$1" -e "$1" ls /dev/net 2>/dev/null | grep -q tun; then
  ok "/dev/net/tun present on first node"
else
  echo "NOTE  /dev/net/tun not seen on first node (gluetun will need it later)"
fi

echo "## cross-node pod traffic"
k create namespace "$NS" >/dev/null
k label namespace "$NS" pod-security.kubernetes.io/enforce=baseline --overwrite >/dev/null
mkpod() {
  k apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: $NS}
spec:
  nodeSelector: {kubernetes.io/hostname: $2}
  tolerations: [{key: node-role.homeserver/tier, operator: Equal, value: mobile, effect: NoSchedule}]
  securityContext: {runAsNonRoot: true, runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: $IMG
      command: ["sh", "-c", "head -c 3000000 /dev/zero > /tmp/big; httpd -f -p 8080 -h /tmp"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
YAML
}
mkpod a-mini01 mini01
mkpod b-mini03 mini03
if ! k -n "$NS" wait --for=condition=Ready pod/a-mini01 pod/b-mini03 --timeout=180s >/dev/null; then bad "pods not Ready"; fi
sleep 3
ipa="$(k -n "$NS" get pod a-mini01 -o jsonpath='{.status.podIP}')"
ipb="$(k -n "$NS" get pod b-mini03 -o jsonpath='{.status.podIP}')"
# A 3 MB download exercises the MTU: a stall with small requests working means an MTU problem.
n="$(k -n "$NS" exec b-mini03 -- wget -qO- -T 20 "http://$ipa:8080/big" | wc -c || true)"
if [ "${n// /}" = 3000000 ]; then ok "mini03 -> mini01, 3 MB transfer"; else bad "mini03 -> mini01 transfer (${n// /} bytes)"; fi
n="$(k -n "$NS" exec a-mini01 -- wget -qO- -T 20 "http://$ipb:8080/big" | wc -c || true)"
if [ "${n// /}" = 3000000 ]; then ok "mini01 -> mini03, 3 MB transfer"; else bad "mini01 -> mini03 transfer (${n// /} bytes)"; fi
for p in a-mini01 b-mini03; do
  echo "      pod interface MTU on $p: $(k -n "$NS" exec "$p" -- cat /sys/class/net/eth0/mtu)"
done
if [ "$fail" = 0 ]; then
  echo "NETWORK PASS"
else
  echo "NETWORK FAIL"
  exit 1
fi
