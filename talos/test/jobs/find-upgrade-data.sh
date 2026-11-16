#!/usr/bin/env bash
# talos-job: kvm=yes timeout=75 heavy=yes
# G1 findings UPGRADE-PRESERVE-DATA, UPGRADE-NOPRESERVE-DATA, UPGRADE-EXTENSION-ADD,
# UPGRADE-K8S-OBJECTS: what a Talos upgrade does to a user data volume (a marker
# file on a second disk) and to the cluster's own objects (a ConfigMap).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"
# shellcheck source=talos/test/lib-find.sh
. "$here/../lib-find.sh"

TAL_FIND_TAG=find-upgrade
tal_find_cluster base --data-disk 20G --volume-patch "$TAL_ROOT/test/patches/find-data-volume.yaml"

base_image="$(tal_installer_ref base)"
target_image="$(tal_installer_ref upgradetarget)"

# --- baseline: the volume, a marker and a ConfigMap ---------------------------
for _ in $(seq 1 30); do
  tal_assert_mounted data && break
  sleep 5
done
tal_assert_mounted data || tal_die "the data volume is not mounted at /var/mnt/data"
tal_marker_write data
tal_marker_verify data || tal_die "the marker does not verify right after writing it"
tal_kubectl create configmap upgrade-check --from-literal=k=v >/dev/null
tal_report "BASELINE=ok"

# --- flags the upgrade command may or may not have on this version -------------
have_preserve=no
have_stage=no
if tal_probe talosctl upgrade --help; then
  grep -q -- '--preserve' "$TAL_WORK/probe.out" && have_preserve=yes
  grep -q -- '--stage' "$TAL_WORK/probe.out" && have_stage=yes
fi
tal_report "UPGRADE_FLAG_PRESERVE=${have_preserve}"
tal_report "UPGRADE_FLAG_STAGE=${have_stage}"

# upgrade_case <label> <image> [extra upgrade flags...]
# Runs the upgrade, waits for the node, re-bootstraps once if the cluster state
# was wiped (an upgrade without --preserve wipes EPHEMERAL, which holds etcd),
# then reports MARKER=ok|lost and CONFIGMAP=ok|lost for the case.
upgrade_case() {
  local label="$1" image="$2"
  shift 2
  local started=$SECONDS rc=0
  tal_ctl upgrade --image "$image" "$@" >"$TAL_WORK/upgrade-${label}.out" 2>&1 || rc=$?
  tal_report "UPGRADE_${label}_RC=${rc}"
  tal_report "UPGRADE_${label}_SECONDS=$((SECONDS - started))"
  tal_wait_api 600
  local ready=no i
  for i in $(seq 1 30); do
    if tal_kubectl get nodes -o json 2>/dev/null | jq -e '(.items | length) >= 1 and ([.items[].status.conditions[] | select(.type == "Ready") | .status] | all(. == "True"))' >/dev/null; then
      ready=yes
      break
    fi
    sleep 10
  done
  if [[ "$ready" == no ]]; then
    # the cluster state went with EPHEMERAL: bootstrap the same node again
    tal_report "UPGRADE_${label}_REBOOTSTRAP=yes"
    tal_bootstrap || true
    tal_kubeconfig
    tal_wait_ready 600
  fi
  if tal_marker_verify data; then
    tal_report "UPGRADE_${label}_MARKER=ok"
  else
    tal_report "UPGRADE_${label}_MARKER=lost"
  fi
  if tal_kubectl get configmap upgrade-check >/dev/null 2>&1; then
    tal_report "UPGRADE_${label}_CONFIGMAP=ok"
  else
    tal_report "UPGRADE_${label}_CONFIGMAP=lost"
  fi
  # rewrite the marker if a case lost it, so the next case starts from a known state
  tal_marker_verify data || tal_marker_write data
  tal_kubectl get configmap upgrade-check >/dev/null 2>&1 || tal_kubectl create configmap upgrade-check --from-literal=k=v >/dev/null
  return "$rc"
}

report_value() { grep -m1 "^$1=" "$TAL_REPORT_FILE" | cut -d= -f2-; }

# --- U1: same version, --preserve ---------------------------------------------
if [[ "$have_preserve" == yes ]]; then
  u1rc=0
  upgrade_case U1 "$base_image" --preserve || u1rc=$?
  if [[ "$(report_value UPGRADE_U1_MARKER)" == ok && $u1rc -eq 0 ]]; then
    tal_finding UPGRADE-PRESERVE-DATA PASS "marker survived an upgrade with --preserve"
  else
    tal_finding UPGRADE-PRESERVE-DATA FAIL "marker $(report_value UPGRADE_U1_MARKER), upgrade rc=${u1rc}: $(head -c 200 "$TAL_WORK/upgrade-U1.out" | tr '\n' ' ')"
  fi
  if [[ "$(report_value UPGRADE_U1_CONFIGMAP)" == ok ]]; then
    tal_finding UPGRADE-K8S-OBJECTS PASS "the ConfigMap survived an upgrade with --preserve"
  else
    tal_finding UPGRADE-K8S-OBJECTS FAIL "the ConfigMap was lost by an upgrade with --preserve"
  fi
else
  tal_finding UPGRADE-PRESERVE-DATA UNKNOWN "talosctl upgrade has no --preserve flag on ${TALOS_VERSION}: $(tal_probe_text)"
  tal_finding UPGRADE-K8S-OBJECTS UNKNOWN "no --preserve flag to test"
fi

# --- U2: same version, no --preserve ------------------------------------------
u2rc=0
upgrade_case U2 "$base_image" || u2rc=$?
if [[ "$(report_value UPGRADE_U2_MARKER)" == ok && $u2rc -eq 0 ]]; then
  tal_finding UPGRADE-NOPRESERVE-DATA PASS "marker survived an upgrade without --preserve (cluster objects: $(report_value UPGRADE_U2_CONFIGMAP))"
else
  tal_finding UPGRADE-NOPRESERVE-DATA FAIL "marker $(report_value UPGRADE_U2_MARKER), upgrade rc=${u2rc}: $(head -c 200 "$TAL_WORK/upgrade-U2.out" | tr '\n' ' ')"
fi

# --- U3: upgrade to an installer with one more extension -----------------------
u3flags=()
[[ "$have_preserve" == yes ]] && u3flags+=(--preserve)
u3rc=0
upgrade_case U3 "$target_image" "${u3flags[@]+"${u3flags[@]}"}" || u3rc=$?
ext_ok=no
if tal_ctl get extensions 2>/dev/null | grep -qi 'intel-ucode'; then
  ext_ok=yes
fi
tal_report "UPGRADE_U3_EXTENSION=${ext_ok}"
if [[ "$(report_value UPGRADE_U3_MARKER)" == ok && "$ext_ok" == yes && $u3rc -eq 0 ]]; then
  tal_finding UPGRADE-EXTENSION-ADD PASS "an upgrade to the installer with one more extension loaded it and kept the marker"
else
  tal_finding UPGRADE-EXTENSION-ADD FAIL "extension loaded=${ext_ok}, marker $(report_value UPGRADE_U3_MARKER), rc=${u3rc}: $(head -c 200 "$TAL_WORK/upgrade-U3.out" | tr '\n' ' ')"
fi

tal_summary
