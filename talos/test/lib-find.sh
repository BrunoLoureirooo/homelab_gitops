#!/usr/bin/env bash
# Helpers of the findings jobs (plan 15-04). Source it after talos/test/lib.sh in
# a job script that already ran `set -euo pipefail`; never execute it. Never
# `set -x`: the throwaway secrets bundle lives in $TAL_WORK.
# shellcheck shell=bash

TAL_FIND_NS="${TAL_FIND_NS:-tal-find}"
TAL_FIND_TAG="${TAL_FIND_TAG:-find}"
TAL_MARKER_BYTES=4194304
export TAL_FIND_NS TAL_FIND_TAG

# Pinned image tags of the throwaway test pods (talos/versions.env).
tal_find_images() {
  tal_require_pins
  : "${ALPINE_TAG:?ALPINE_TAG is not set in talos/versions.env}"
  TAL_ALPINE="alpine:${ALPINE_TAG}"
  export TAL_ALPINE
}

# tal_find_cluster <schematic> [--data-disk SIZE]... [--patch FILE]...
# Boots a single-node cluster exactly like boot-single (the control plane is the
# only node), with extra blank data disks, and leaves talosctl and kubectl
# ready. The VM tag is $TAL_FIND_TAG; the data disks are $TAL_WORK/<tag>-dataN.qcow2.
tal_find_cluster() {
  local schematic="$1"
  shift
  local sizes=() patches=() volpatch=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --data-disk) sizes+=("$2") ;;
      --patch) patches+=("$2") ;;
      --volume-patch) volpatch="$2" ;;
      *) tal_die "tal_find_cluster: unknown argument $1" ;;
    esac
    shift 2
  done
  tal_prepare_runner
  tal_find_images
  # A second cluster in the same job reuses the first one's secrets bundle so the
  # log scrubbing keeps masking every value (TAL_FIND_REUSE_SECRETS=1).
  if [[ "${TAL_FIND_REUSE_SECRETS:-0}" != 1 || ! -f "$TAL_WORK/secrets.yaml" ]]; then
    tal_secrets
  fi
  local iso image
  # TAL_FIND_ISO / TAL_FIND_IMAGE override the plain assets (the UKI job uses the
  # Secure Boot ISO and installer).
  iso="${TAL_FIND_ISO:-$(tal_fetch "$schematic")}"
  image="${TAL_FIND_IMAGE:-$(tal_installer_ref "$schematic")}"
  tal_gen_config "$TAL_FIND_TAG" 10.0.2.15 "$image" "$TAL_ROOT/test/patches/ci-single.yaml" "${patches[@]+"${patches[@]}"}"
  local args=() i=0 s
  for s in "${sizes[@]+"${sizes[@]}"}"; do
    i=$((i + 1))
    qemu-img create -q -f qcow2 "$TAL_WORK/${TAL_FIND_TAG}-data${i}.qcow2" "$s"
    args+=(--data-disk "$TAL_WORK/${TAL_FIND_TAG}-data${i}.qcow2")
  done
  tal_boot "$TAL_WORK/${TAL_FIND_TAG}.qcow2" "$TAL_FIND_TAG" --iso "$iso" "${args[@]+"${args[@]}"}"
  # A multi-document volume patch is applied with `machineconfig patch`, the
  # same route the render.sh output takes in the 15-02 jobs.
  TAL_FIND_CONFIG="$TAL_WORK/cfg/controlplane.yaml"
  if [[ -n "$volpatch" ]]; then
    tal_patch_node "$TAL_WORK/cfg/controlplane.yaml" "$volpatch" "$TAL_WORK/cfg/controlplane-find.yaml"
    TAL_FIND_CONFIG="$TAL_WORK/cfg/controlplane-find.yaml"
    if ! talosctl validate --config "$TAL_FIND_CONFIG" --mode metal >"$TAL_WORK/validate.out" 2>&1; then
      # TAL_FIND_SOFT_VALIDATE=1: return 3 so the caller can record a FAIL
      # finding with the validator's message instead of aborting the job.
      if [[ "${TAL_FIND_SOFT_VALIDATE:-0}" == 1 ]]; then
        return 3
      fi
      tal_die "the volume patch $(basename "$volpatch") is rejected by talosctl validate: $(head -c 300 "$TAL_WORK/validate.out" | tr '\n' ' ')"
    fi
  fi
  export TAL_FIND_CONFIG
  tal_apply "$TAL_APID_PORT" "$TAL_FIND_CONFIG"
  tal_wait_api 600
  tal_bootstrap
  tal_kubeconfig
  tal_wait_ready 600
}

# tal_psa_privileged <namespace>: create the namespace if needed and allow
# privileged pods in it (Pod Security admission labels).
tal_psa_privileged() {
  tal_kubectl create namespace "$1" --dry-run=client -o yaml | tal_kubectl apply -f - >/dev/null
  tal_kubectl label namespace "$1" --overwrite \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged >/dev/null
}

# tal_probe <command...>: run a command, keep its combined output in
# $TAL_WORK/probe.out; return its exit status without ever failing the job.
# Used to learn whether a flag or resource exists before relying on it.
tal_probe() {
  mkdir -p "$TAL_WORK"
  if "$@" >"$TAL_WORK/probe.out" 2>&1; then
    return 0
  fi
  return 1
}

tal_probe_text() {
  head -c 400 "$TAL_WORK/probe.out" 2>/dev/null | tr '\n' ' '
}

# tal_run_pod <name> <image> <privileged:yes|no> <shell-script> [hostpath-mount...]
# Runs a one-shot pod in $TAL_FIND_NS, waits for Succeeded or Failed, prints
# the pod log on stdout and returns 0 on Succeeded. Each hostpath argument is
# <hostpath>=<mountpath>. A privileged pod also gets hostPID and /dev.
tal_run_pod() {
  local name="$1" image="$2" priv="$3" script="$4"
  shift 4
  tal_psa_privileged "$TAL_FIND_NS"
  tal_kubectl -n "$TAL_FIND_NS" delete pod "$name" --ignore-not-found >/dev/null
  local mounts="" vols="" n=0 hm
  for hm in "$@"; do
    n=$((n + 1))
    mounts+="        - {name: hp${n}, mountPath: \"${hm#*=}\"}"$'\n'
    vols+="    - {name: hp${n}, hostPath: {path: \"${hm%%=*}\", type: DirectoryOrCreate}}"$'\n'
  done
  local sec="" extra=""
  if [[ "$priv" == yes ]]; then
    sec="        securityContext: {privileged: true}"
    extra="  hostPID: true"
  fi
  {
    cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${TAL_FIND_NS}
spec:
  restartPolicy: Never
${extra}
  containers:
    - name: c
      image: ${image}
      command: ["/bin/sh", "-c"]
      args:
        - |
$(printf '%s\n' "$script" | sed 's/^/          /')
EOF
    [[ -n "$sec" ]] && printf '%s\n' "$sec"
    if [[ -n "$mounts" ]]; then
      printf '      volumeMounts:\n%s' "$mounts"
    fi
    if [[ -n "$vols" ]]; then
      printf '  volumes:\n%s' "$vols"
    fi
  } | tal_kubectl apply -f - >/dev/null
  local deadline=$((SECONDS + ${TAL_POD_TIMEOUT:-300})) phase=""
  while ((SECONDS < deadline)); do
    phase="$(tal_kubectl -n "$TAL_FIND_NS" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    sleep 3
  done
  tal_kubectl -n "$TAL_FIND_NS" logs "$name" 2>&1 || true
  [[ "$phase" == Succeeded ]]
}

# --- markers: a fixed 4 MiB file on a volume, with a negative control -------
# The expected checksum is a constant computed locally, so a verify can only
# pass when the bytes really are on the volume.
tal_marker_sha() {
  yes TALOS-MARKER | head -c "$TAL_MARKER_BYTES" | sha256sum | cut -d' ' -f1
}

# tal_marker_write <name>: write /var/mnt/<name>/marker.bin through a pod.
tal_marker_write() {
  tal_find_images
  local name="$1"
  tal_run_pod "mw-${name}" "$TAL_ALPINE" yes \
    "mkdir -p /m/${name} && yes TALOS-MARKER | head -c ${TAL_MARKER_BYTES} > /m/${name}/marker.bin && sync && sha256sum /m/${name}/marker.bin" \
    "/var/mnt=/m" >"$TAL_WORK/marker-w-${name}.out" || tal_die "marker write pod failed for ${name}: $(tr '\n' ' ' <"$TAL_WORK/marker-w-${name}.out" | head -c 300)"
  grep -q "$(tal_marker_sha)" "$TAL_WORK/marker-w-${name}.out" || tal_die "marker write for ${name} did not produce the expected checksum"
  tal_report "MARKER_WRITTEN_${name}=ok"
}

# tal_marker_verify <name>: 0 when the file exists with the expected checksum.
tal_marker_verify() {
  tal_find_images
  local name="$1"
  if tal_run_pod "mv-${name}" "$TAL_ALPINE" yes \
    "test -f /m/${name}/marker.bin && sha256sum /m/${name}/marker.bin || echo MARKER-MISSING" \
    "/var/mnt=/m" >"$TAL_WORK/marker-v-${name}.out"; then
    grep -q "$(tal_marker_sha)" "$TAL_WORK/marker-v-${name}.out"
  else
    return 1
  fi
}

# tal_assert_mounted <name>: /var/mnt/<name> is a real mount on the node.
tal_assert_mounted() {
  tal_ctl read /proc/mounts | grep -q " /var/mnt/${1} "
}

# tal_finding_from <id> <rc> <ok-note> <fail-note>
tal_finding_from() {
  if [[ "$2" -eq 0 ]]; then
    tal_finding "$1" PASS "$3"
  else
    tal_finding "$1" FAIL "$4"
  fi
}
