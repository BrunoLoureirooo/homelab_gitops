#!/usr/bin/env bash
# talos-job: kvm=no timeout=5
# Plan 15-08: logic test of talos/deploy/apply.sh and upgrade.sh against a stub
# `talosctl`. No cluster, no network, no KVM: it proves the ordering and the
# refusals (validate everything before touching any node, check mode never
# applies, apply needs approval, `latest` is refused).
# The real-cluster proof is deploy-apply.sh / deploy-upgrade.sh.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
talos_dir="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fails=0
report() { # report <name> PASS|FAIL
  echo "DEPLOY-OFFLINE $1 $2"
  [[ "$2" == PASS ]] || fails=$((fails + 1))
}

mkdir -p "$work/bin" "$work/cfg"
# Stub: behaviour is driven by markers inside the config file it is given.
cat >"$work/bin/talosctl" <<'STUB'
#!/usr/bin/env bash
sub="$1"
shift
file=""
dry=0
help=0
while (($#)); do
  case "$1" in
    --file | --config) file="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --help) help=1; shift ;;
    *) shift ;;
  esac
done
case "$sub" in
  validate)
    if grep -q BADCONF "$file"; then echo "invalid" >&2; exit 1; fi
    ;;
  apply-config)
    if ((dry)); then
      if grep -q CHANGE "$file"; then printf '+a: 1\n+b: 2\n-c: 3\n'; fi
    else
      echo "applied $(basename "$file")" >>"$STUB_APPLIED"
    fi
    ;;
  health) ;;
  version) printf 'Client:\n\tTag: v9.9.9\nServer:\n\tTag: %s\n' "${STUB_NODE_VERSION:-v1.0.0}" ;;
  upgrade)
    if ((help)); then echo "      --preserve   keep the ephemeral partition"; else echo "upgrade" >>"$STUB_APPLIED"; fi
    ;;
  upgrade-k8s) echo "upgrade-k8s" >>"$STUB_APPLIED" ;;
esac
exit 0
STUB
chmod +x "$work/bin/talosctl"
export PATH="$work/bin:$PATH"
export TALOSCONFIG="$work/talosconfig"
: >"$TALOSCONFIG"
export STUB_APPLIED="$work/applied.log"
export TALOS_DEPLOY_LOG="$work/subcmds.log"
export TALOS_NODES="cp1=10.0.2.15:50000 w1=10.0.2.16:50000"
export TALOS_CONFIG_DIR="$work/cfg"

reset() {
  : >"$STUB_APPLIED"
  : >"$TALOS_DEPLOY_LOG"
}

# 1. check, nothing changes -> NOCHANGE for both nodes, no apply.
echo "kind: controlplane" >"$work/cfg/cp1.yaml"
echo "kind: worker" >"$work/cfg/w1.yaml"
reset
out="$(bash "$talos_dir/deploy/apply.sh" --mode check)"
if [[ "$(grep -c 'result=NOCHANGE' <<<"$out")" == 2 && ! -s "$STUB_APPLIED" ]]; then
  report check-nochange PASS
else
  report check-nochange FAIL
fi

# 2. check with a change on the worker: CHANGES, still no apply, no diff text.
echo "CHANGE" >>"$work/cfg/w1.yaml"
reset
out="$(bash "$talos_dir/deploy/apply.sh" --mode check)"
if grep -q 'node=w1 mode=check result=CHANGES changed_lines=3' <<<"$out" && ! grep -q 'a: 1' <<<"$out" && [[ ! -s "$STUB_APPLIED" ]]; then
  report check-reports-count-not-diff PASS
else
  report check-reports-count-not-diff FAIL
fi

# 3. apply without approval is refused (exit 2), nothing applied.
reset
rc=0
bash "$talos_dir/deploy/apply.sh" --mode apply >/dev/null 2>&1 || rc=$?
if [[ "$rc" == 2 && ! -s "$STUB_APPLIED" ]]; then
  report apply-needs-approval PASS
else
  report apply-needs-approval FAIL
fi

# 4. apply --yes: only the changed node is applied, in order, then APPLIED.
echo "CHANGE" >>"$work/cfg/cp1.yaml"
reset
out="$(bash "$talos_dir/deploy/apply.sh" --mode apply --yes)"
if [[ "$(paste -sd, "$STUB_APPLIED")" == "applied cp1.yaml,applied w1.yaml" ]] && grep -q 'node=cp1 mode=apply result=APPLIED' <<<"$out"; then
  report apply-order-control-plane-first PASS
else
  report apply-order-control-plane-first FAIL
fi

# 5. one bad config among good ones: nothing is applied anywhere, exit 1.
echo "BADCONF" >>"$work/cfg/w1.yaml"
reset
rc=0
out="$(bash "$talos_dir/deploy/apply.sh" --mode apply --yes 2>/dev/null)" || rc=$?
if [[ "$rc" == 1 ]] && grep -q 'node=w1 mode=apply result=REJECTED' <<<"$out" && ! grep -q 'apply-config' "$TALOS_DEPLOY_LOG"; then
  report bad-config-rejected-before-any-node PASS
else
  report bad-config-rejected-before-any-node FAIL
fi

# 6. a missing rendered config is rejected the same way.
rm -f "$work/cfg/w1.yaml"
reset
rc=0
bash "$talos_dir/deploy/apply.sh" --mode check >/dev/null 2>&1 || rc=$?
if [[ "$rc" == 1 ]] && ! grep -q 'apply-config' "$TALOS_DEPLOY_LOG"; then
  report missing-config-rejected PASS
else
  report missing-config-rejected FAIL
fi

# --- upgrade.sh -------------------------------------------------------------
cat >"$work/versions.env" <<'EOF'
TALOS_VERSION=v1.99.0
K8S_VERSION=v1.99.1
FACTORY_URL=https://factory.example.test
SCHEMATIC_BASE_ID=0000000000000000000000000000000000000000000000000000000000000000
EOF
export VERSIONS_FILE="$work/versions.env"
export NODES_DIR="$work/nodes-none"

reset
out="$(bash "$talos_dir/deploy/upgrade.sh" --talos --dry-run)"
if [[ "$(grep -c 'result=PLANNED' <<<"$out")" == 2 ]] && ! grep -q '^upgrade$' "$STUB_APPLIED"; then
  report upgrade-dry-run-plans-only PASS
else
  report upgrade-dry-run-plans-only FAIL
fi

reset
rc=0
bash "$talos_dir/deploy/upgrade.sh" --talos >/dev/null 2>&1 || rc=$?
if [[ "$rc" == 2 ]]; then report upgrade-needs-approval PASS; else report upgrade-needs-approval FAIL; fi

rc=0
bash "$talos_dir/deploy/upgrade.sh" --talos --dry-run --no-preserve >/dev/null 2>&1 || rc=$?
if [[ "$rc" == 2 ]]; then report no-preserve-is-ci-only PASS; else report no-preserve-is-ci-only FAIL; fi

sed -i.bak 's/TALOS_VERSION=v1.99.0/TALOS_VERSION=latest/' "$work/versions.env"
rc=0
bash "$talos_dir/deploy/upgrade.sh" --talos --dry-run >/dev/null 2>&1 || rc=$?
if [[ "$rc" == 2 ]]; then report latest-is-refused PASS; else report latest-is-refused FAIL; fi

if grep -n ':latest' "$talos_dir/deploy/upgrade.sh" >/dev/null; then
  report no-latest-tag-in-script FAIL
else
  report no-latest-tag-in-script PASS
fi

echo "DEPLOY-OFFLINE failures=$fails"
exit "$((fails > 0))"
