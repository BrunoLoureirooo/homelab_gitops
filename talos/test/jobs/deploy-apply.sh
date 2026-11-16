#!/usr/bin/env bash
# talos-job: kvm=yes timeout=45
# Plan 15-08 Task 1: the production apply.sh against a Talos QEMU cluster.
# check mode changes nothing, apply mode adds a node label without a reboot,
# and an invalid config is rejected before any node is contacted.
#
# Depends on the 15-01 harness (talos/test/lib.sh: talos_ci_up/talos_ci_down,
# tal_* helpers, tal_report, tal_finding). Reports DEPLOY check|apply|reject.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
talos_dir="$(cd "$here/../.." && pwd)"
# shellcheck source=/dev/null
. "$talos_dir/test/lib.sh"

name=deploy-apply
cleanup() { talos_ci_down "$name" || true; }
trap cleanup EXIT

talos_ci_up "$name"

work="${TAL_WORK:?TAL_WORK not set by lib.sh}"
cfgdir="$work/deploy-cfg"
mkdir -p "$cfgdir"
node=tal-ci
# The single-node CI cluster has one control plane; its generated config is the
# "rendered" config for this node (render.sh itself is covered by 15-02 jobs).
cp "$work/cfg/controlplane.yaml" "$cfgdir/$node.yaml"

export TALOSCONFIG="${TALOSCONFIG:-$work/cfg/talosconfig}"
export TALOS_NODES="$node=127.0.0.1:${TAL_APID_PORT:-50000}"
export TALOS_CONFIG_DIR="$cfgdir"
export TALOS_DEPLOY_LOG="$work/deploy-subcommands.log"
: >"$TALOS_DEPLOY_LOG"

uptime_s() {
  talosctl --nodes 127.0.0.1 --endpoints "127.0.0.1:${TAL_APID_PORT:-50000}" read /proc/uptime | awk '{print int($1)}'
}
label() {
  kubectl --kubeconfig "$work/kubeconfig" get node "$node" -o 'jsonpath={.metadata.labels.homelab\.test/deploy}' 2>/dev/null || true
}

# (a) check with nothing changed.
out="$(bash "$talos_dir/deploy/apply.sh" --mode check)"
if grep -q "node=$node mode=check result=NOCHANGE" <<<"$out"; then
  tal_report "DEPLOY_CHECK_NOCHANGE=ok"
else
  tal_report "DEPLOY_CHECK_NOCHANGE=FAIL"
  echo "$out"
  exit 1
fi

# (b) a harmless change: a node label via a machine config patch.
cat >"$work/label-patch.yaml" <<'EOF'
apiVersion: v1alpha1
kind: KubeNodeConfig
labels:
  homelab.test/deploy: "1"
EOF
talosctl machineconfig patch "$cfgdir/$node.yaml" --patch "@$work/label-patch.yaml" -o "$cfgdir/$node.yaml.new"
mv "$cfgdir/$node.yaml.new" "$cfgdir/$node.yaml"

out="$(bash "$talos_dir/deploy/apply.sh" --mode check)"
if ! grep -q "node=$node mode=check result=CHANGES" <<<"$out"; then
  tal_report "DEPLOY_CHECK=FAIL"
  echo "$out"
  exit 1
fi
if [[ -n "$(label)" ]]; then
  tal_report "DEPLOY_CHECK=FAIL label present after check"
  exit 1
fi
tal_report "DEPLOY check PASS"

before="$(uptime_s)"
out="$(bash "$talos_dir/deploy/apply.sh" --mode apply --yes)"
grep -q "node=$node mode=apply result=APPLIED" <<<"$out" || {
  tal_report "DEPLOY_APPLY=FAIL"
  echo "$out"
  exit 1
}
# The label shows up once the node label controller reconciles (no reboot).
seen=""
for _ in $(seq 1 30); do
  seen="$(label)"
  [[ "$seen" == 1 ]] && break
  sleep 5
done
after="$(uptime_s)"
if [[ "$seen" == 1 && "$after" -ge "$before" ]]; then
  tal_report "DEPLOY apply PASS"
else
  tal_report "DEPLOY apply FAIL label=${seen:-none} uptime_before=$before uptime_after=$after"
  exit 1
fi

# (c) negative control: an invalid machine type must be rejected by validate,
# and no apply-config call may happen (not even a dry run).
sed -E 's/^( *)type: controlplane$/\1type: bogus/' "$cfgdir/$node.yaml" >"$cfgdir/$node.yaml.bad"
mv "$cfgdir/$node.yaml.bad" "$cfgdir/$node.yaml"
: >"$TALOS_DEPLOY_LOG"
rc=0
out="$(bash "$talos_dir/deploy/apply.sh" --mode apply --yes 2>/dev/null)" || rc=$?
if [[ "$rc" -ne 0 ]] && grep -q "node=$node mode=apply result=REJECTED" <<<"$out" && ! grep -q 'apply-config' "$TALOS_DEPLOY_LOG"; then
  tal_report "DEPLOY reject PASS"
else
  tal_report "DEPLOY reject FAIL rc=$rc"
  exit 1
fi

tal_finding DEPLOY-APPLY PASS "check, apply without reboot, and reject proven"
