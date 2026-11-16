#!/usr/bin/env bash
# Helper library of the Talos CI jobs (plan 15-01). Source it from a job script
# that has already run `set -euo pipefail`; never execute it. Never `set -x`:
# the throwaway secrets bundle lives in $TAL_WORK.
# shellcheck shell=bash

TAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAL_ROOT="$(cd "$TAL_LIB_DIR/.." && pwd)"
TAL_JOB="${TAL_JOB:-$(basename "${BASH_SOURCE[1]:-job}" .sh)}"
TAL_WORK="${TAL_WORK:-${RUNNER_TEMP:-/tmp}/tal}"
TAL_LOGDIR="${TAL_LOGDIR:-$PWD}"
TAL_APID_PORT="${TAL_APID_PORT:-50000}"
TAL_K8S_PORT="${TAL_K8S_PORT:-6443}"
TAL_REPORT_FILE="${TAL_REPORT:-tal-report-$TAL_JOB.txt}"
TAL_FINDINGS_FILE="findings-$TAL_JOB.txt"
export TAL_WORK TAL_LOGDIR TAL_APID_PORT TAL_K8S_PORT TAL_JOB
export PATH="$TAL_WORK/bin:$PATH"

# Fixed MACs of the CI networks (QEMU's own 52:54:00 prefix, not real hardware).
TAL_MAC_USER="52:54:00:12:34:56"
TAL_MAC_CP="52:54:00:12:00:11"
TAL_MAC_W="52:54:00:12:00:12"
export TAL_MAC_USER TAL_MAC_CP TAL_MAC_W

tal_die() {
  echo "::error::$*" >&2
  exit 1
}

# ---------------------------------------------------------------- reports ----
tal_report() { # tal_report KEY=VALUE
  echo "$1" >>"$TAL_REPORT_FILE"
  echo "report: $1"
}

tal_finding() { # tal_finding <id> PASS|FAIL|UNKNOWN <note>
  local id="$1" verdict="$2" note="${3:-}"
  [[ "$verdict" =~ ^(PASS|FAIL|UNKNOWN|HARDWARE-ONLY)$ ]] || tal_die "bad finding verdict $verdict"
  echo "FINDING $id $verdict $note" >>"$TAL_FINDINGS_FILE"
  echo "finding: $id $verdict $note"
}

# --------------------------------------------------------------- tooling ----
tal_require_pins() {
  if [[ -e "$TAL_ROOT/PINS-PENDING" ]]; then
    tal_die "pins are pending (talos/PINS-PENDING): run talos/refresh-pins.sh --write and commit the result"
  fi
  # shellcheck source=/dev/null
  . "$TAL_ROOT/versions.env"
}

tal_download_pinned() { # tal_download_pinned <url> <sha256> <dest>
  curl --fail --silent --show-error --retry 5 -L -o "$3" "$1"
  echo "$2  $3" | sha256sum -c - >/dev/null || tal_die "sha256 mismatch for $(basename "$3")"
  chmod +x "$3"
}

tal_prepare_runner() {
  tal_require_pins
  mkdir -p "$TAL_WORK/bin"
  if [[ "${TAL_NEEDS_KVM:-yes}" == yes ]]; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq qemu-system-x86 qemu-utils ovmf xz-utils jq python3
  fi
  command -v yq >/dev/null || tal_die "yq (mikefarah) is not installed on this runner"
  tal_download_pinned "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-linux-amd64" "$TALOSCTL_SHA256" "$TAL_WORK/bin/talosctl"
  tal_download_pinned "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" "$KUBECTL_SHA256" "$TAL_WORK/bin/kubectl"
}

tal_fetch() { # tal_fetch <schematic>  -> prints the ISO path
  TAL_CACHE="${TAL_CACHE:-$PWD/.cache}" bash "$TAL_ROOT/fetch-assets.sh" "$1" iso
}

tal_installer_ref() { # tal_installer_ref <schematic>
  bash "$TAL_ROOT/fetch-assets.sh" "$1" installer-ref
}

# ---------------------------------------------------------------- secrets ----
tal_secrets() {
  mkdir -p "$TAL_WORK"
  chmod 700 "$TAL_WORK"
  umask 077
  talosctl gen secrets --force -o "$TAL_WORK/secrets.yaml" >/dev/null
  : >"$TAL_WORK/mask.list"
  local line
  while IFS= read -r line; do
    [[ ${#line} -gt 12 ]] || continue
    echo "::add-mask::$line"
    printf '%s\n' "$line" >>"$TAL_WORK/mask.list"
  done < <(yq -r '.. | select(tag == "!!str")' "$TAL_WORK/secrets.yaml")
  trap tal_cleanup EXIT
}

# tal_summary: append the job's findings and report to the GitHub job summary
# (no permission needed) so the verdicts are readable without downloading.
tal_summary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  {
    echo "### ${TAL_JOB}"
    echo '```'
    cat "$TAL_FINDINGS_FILE" 2>/dev/null || true
    echo '```'
  } >>"$GITHUB_STEP_SUMMARY"
}

tal_scrub_logs() {
  local f
  if [[ -s "$TAL_WORK/mask.list" ]]; then
    for f in "$TAL_LOGDIR"/serial-*.log "$TAL_REPORT_FILE" "$TAL_FINDINGS_FILE"; do
      [[ -f "$f" ]] || continue
      python3 - "$f" "$TAL_WORK/mask.list" <<'PY'
import sys
path, masks = sys.argv[1], sys.argv[2]
data = open(path, "rb").read()
for m in open(masks, "rb").read().split(b"\n"):
    if m:
        data = data.replace(m, b"<redacted>")
open(path, "wb").write(data)
PY
    done
    for f in "$TAL_LOGDIR"/serial-*.log "$TAL_REPORT_FILE" "$TAL_FINDINGS_FILE"; do
      [[ -f "$f" ]] || continue
      if grep -aqF -f "$TAL_WORK/mask.list" "$f"; then
        echo "::error::a secret value is still present in $f after scrubbing" >&2
        return 1
      fi
    done
  fi
  echo "SERIAL_SCRUBBED=ok" >>"$TAL_REPORT_FILE"
}

tal_cleanup() {
  local rc=$?
  trap - EXIT
  local pidfile
  for pidfile in "$TAL_LOGDIR"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    tal_stop "$(basename "$pidfile" .pid)" || true
  done
  tal_scrub_logs || rc=1
  exit "$rc"
}

# ------------------------------------------------------------ machine config ----
tal_gen_config() { # tal_gen_config <name> <endpoint-host> <install-image> [patch-file...]
  local name="$1" endpoint="$2" image="$3"
  shift 3
  local args=(gen config "$name" "https://${endpoint}:6443" --with-secrets "$TAL_WORK/secrets.yaml"
    --install-image "$image" --output "$TAL_WORK/cfg" --force)
  [[ -n "${K8S_VERSION:-}" ]] && args+=(--kubernetes-version "${K8S_VERSION#v}")
  local p
  for p in "$@"; do args+=(--config-patch "@$p"); done
  mkdir -p "$TAL_WORK/cfg"
  talosctl "${args[@]}" >/dev/null
}

tal_patch_node() { # tal_patch_node <in> <patch-file> <out>
  talosctl machineconfig patch "$1" --patch "@$2" --output "$3"
}

# A talosconfig that matches the throwaway secrets bundle, for jobs that render
# their machine config with render.sh (which writes only the node config).
tal_gen_talosconfig() { # tal_gen_talosconfig <endpoint-host>
  mkdir -p "$TAL_WORK/cfg"
  talosctl gen config homelab "https://${1}:6443" --with-secrets "$TAL_WORK/secrets.yaml" \
    --output-types talosconfig --output "$TAL_WORK/cfg/talosconfig" --force >/dev/null
}

# sops and age from the pinned releases (plan 15-02 jobs).
tal_install_sops_age() {
  tal_require_pins
  mkdir -p "$TAL_WORK/bin"
  tal_download_pinned "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64" "$SOPS_SHA256" "$TAL_WORK/bin/sops"
  curl --fail --silent --show-error --retry 5 -L -o "$TAL_WORK/age.tgz" \
    "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz"
  echo "$AGE_SHA256  $TAL_WORK/age.tgz" | sha256sum -c - >/dev/null || tal_die "sha256 mismatch for age"
  tar -xzf "$TAL_WORK/age.tgz" -C "$TAL_WORK" age/age age/age-keygen
  mv "$TAL_WORK/age/age" "$TAL_WORK/age/age-keygen" "$TAL_WORK/bin/"
}

# ------------------------------------------------------------------ VMs ----
tal_boot() { # tal_boot <qcow2> <tag> [driver args...]
  bash "$TAL_LIB_DIR/direct-boot.sh" "$@"
}

tal_stop() { # tal_stop <tag>
  local pidfile="$TAL_LOGDIR/$1.pid" pid i
  [[ -f "$pidfile" ]] || return 0
  pid="$(cat "$pidfile")"
  kill "$pid" 2>/dev/null || true
  for i in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
    [[ $i -eq 30 ]] && kill -9 "$pid" 2>/dev/null
  done
  rm -f "$pidfile"
}

# --------------------------------------------------------------- talosctl ----
tal_ctl() { # talosctl with the generated talosconfig; TAL_APID_PORT and TAL_NODE pick the VM
  talosctl --talosconfig "$TAL_WORK/cfg/talosconfig" \
    --endpoints "127.0.0.1:${TAL_APID_PORT}" --nodes "${TAL_NODE:-127.0.0.1}" "$@"
}

tal_apply() { # tal_apply <port> <config-file>  (maintenance mode, insecure)
  local port="$1" file="$2" deadline=$((SECONDS + 120)) out="" tries=0
  while ((SECONDS < deadline)); do
    tries=$((tries + 1))
    if out="$(talosctl apply-config --insecure --nodes 127.0.0.1 --endpoints "127.0.0.1:${port}" --file "$file" 2>&1)"; then
      return 0
    fi
    # An earlier attempt that did go through reboots the node into the installer, which can
    # drop the reply; the retry then meets the secured API ("certificate required").
    if ((tries > 1)) && [[ "$out" == *"certificate required"* ]]; then
      return 0
    fi
    sleep 5
  done
  printf '%s\n' "$out" | tail -n 5 >&2
  tal_die "apply-config to port $port did not succeed within 120 s"
}

tal_wait_api() { # tal_wait_api <seconds>
  local deadline=$((SECONDS + $1))
  while ((SECONDS < deadline)); do
    tal_ctl version >/dev/null 2>&1 && return 0
    sleep 5
  done
  tal_die "the Talos API on port ${TAL_APID_PORT} did not answer within $1 s"
}

tal_bootstrap() {
  # The node may still be installing and rebooting, or etcd may not be ready yet
  # ("FailedPrecondition: bootstrap is not available yet", "Unavailable ... handshake
  # failed"). Retry any failure for up to 5 minutes; an "already bootstrapped" answer
  # from an earlier attempt that did go through counts as success.
  local deadline=$((SECONDS + 300)) out
  while true; do
    if out="$(tal_ctl bootstrap 2>&1)"; then
      return 0
    fi
    if [[ "$out" == *"AlreadyExists"* || "$out" == *"already"* ]]; then
      return 0
    fi
    if ((SECONDS >= deadline)); then
      printf '%s\n' "$out" >&2
      tal_die "talosctl bootstrap failed after 300 s"
    fi
    sleep 5
  done
}

tal_kubeconfig() {
  tal_ctl kubeconfig "$TAL_WORK/kubeconfig" --force >/dev/null
  yq -i ".clusters[0].cluster.server = \"https://127.0.0.1:${TAL_K8S_PORT}\"" "$TAL_WORK/kubeconfig"
  chmod 600 "$TAL_WORK/kubeconfig"
  export KUBECONFIG="$TAL_WORK/kubeconfig"
}

tal_kubectl() {
  kubectl --kubeconfig "$TAL_WORK/kubeconfig" "$@"
}

tal_wait_ready() { # tal_wait_ready <seconds> [expected-node-count]
  local deadline=$((SECONDS + $1)) expect="${2:-1}"
  while ((SECONDS < deadline)); do
    if tal_kubectl get nodes -o json 2>/dev/null | jq -e --argjson n "$expect" \
      '(.items | length) >= $n and ([.items[].status.conditions[] | select(.type == "Ready") | .status] | all(. == "True"))' >/dev/null; then
      return 0
    fi
    sleep 10
  done
  echo "--- diagnostics: nodes ---"
  tal_kubectl get nodes -o wide 2>&1 | tail -n 20 || true
  echo "--- diagnostics: dmesg tail ---"
  tal_ctl dmesg 2>&1 | tail -n 60 || true
  tal_die "node(s) not Ready within $1 s"
}

tal_mem() { # prints "MemTotal MemAvailable" in MB
  tal_ctl read /proc/meminfo | awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {printf "%d %d\n", t/1024, a/1024}'
}

# ------------------------------------------- cluster-level wrappers for later plans ----
# Single-node: talos_ci_up <name>   Two-node: talos_ci_up <name> --two-node
# Leaves KUBECONFIG and TAL_WORK/cfg/talosconfig in place; talos_ci_down stops
# the VMs and scrubs the logs.
talos_ci_up() {
  local name="$1" mode="${2:-}"
  tal_prepare_runner
  tal_secrets
  local iso image
  iso="$(tal_fetch base)"
  image="$(tal_installer_ref base)"
  if [[ "$mode" == --two-node ]]; then
    tal_up_two_node "$name" "$iso" "$image"
  else
    tal_up_single "$name" "$iso" "$image"
  fi
}

tal_up_single() { # tal_up_single <name> <iso> <install-image>
  local name="$1" iso="$2" image="$3"
  tal_gen_config "$name" 10.0.2.15 "$image" "$TAL_ROOT/test/patches/ci-single.yaml"
  tal_boot "$TAL_WORK/$name.qcow2" "$name" --iso "$iso"
  tal_apply "$TAL_APID_PORT" "$TAL_WORK/cfg/controlplane.yaml"
  tal_wait_api 600
  tal_bootstrap
  tal_kubeconfig
  tal_wait_ready 600
}

tal_up_two_node() { # tal_up_two_node <name> <iso> <install-image>
  local name="$1" iso="$2" image="$3" cfg="$TAL_WORK/cfg"
  local pdir="$TAL_ROOT/test/patches"
  tal_gen_config "$name" 192.168.100.11 "$image"
  tal_patch_node "$cfg/controlplane.yaml" "$pdir/ci-two-node-cp.yaml" "$cfg/cp.yaml"
  tal_patch_node "$cfg/worker.yaml" "$pdir/ci-two-node-w.yaml" "$cfg/w.yaml"
  export TAL_CP_APID=50000 TAL_W_APID=50001 TAL_CP_K8S=6443
  # The control plane listens on the private socket network, the worker connects.
  TAL_APID_PORT=$TAL_CP_APID TAL_K8S_PORT=6443 tal_boot "$TAL_WORK/$name-cp.qcow2" "${name}-cp" \
    --iso "$iso" --socket listen=7700 --mac "$TAL_MAC_CP"
  TAL_APID_PORT=$TAL_W_APID TAL_K8S_PORT=6444 tal_boot "$TAL_WORK/$name-w.qcow2" "${name}-w" \
    --iso "$iso" --socket connect=7700 --mac "$TAL_MAC_W" --mem 2048
  tal_apply "$TAL_CP_APID" "$cfg/cp.yaml"
  tal_apply "$TAL_W_APID" "$cfg/w.yaml"
  TAL_APID_PORT=$TAL_CP_APID tal_wait_api 600
  TAL_APID_PORT=$TAL_CP_APID tal_bootstrap
  TAL_APID_PORT=$TAL_CP_APID TAL_K8S_PORT=$TAL_CP_K8S tal_kubeconfig
  tal_wait_ready 900 2
}

talos_ci_down() { # talos_ci_down <name>
  local pidfile
  for pidfile in "$TAL_LOGDIR"/"$1"*.pid; do
    [[ -f "$pidfile" ]] || continue
    tal_stop "$(basename "$pidfile" .pid)"
  done
  tal_scrub_logs
}
