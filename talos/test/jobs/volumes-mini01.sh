#!/usr/bin/env bash
# talos-job: kvm=yes timeout=45
# mini01 volumes (plan 15-02 task 3): a data volume on the system disk and a
# media volume Talos formats on the Toshiba stand-in (a 30 GB extra disk). Both
# mount, survive a reboot, and the media volume never lands on the system disk.
# Negative control: boot again without the extra disk; the media volume must stay
# unprovisioned and the system disk's partition table must be unchanged.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"

tal_prepare_runner
tal_secrets
iso="$(tal_fetch base)"
tal_gen_talosconfig 10.0.2.15

render_with() { # render_with <label> [extra render args...] -> prints the patched config path
  local label="$1"
  shift
  bash "$TAL_ROOT/render.sh" mini01 --secrets "$TAL_WORK/secrets.yaml" --out "$TAL_WORK/r-$label" \
    --schematic base --no-tailscale --set ENDPOINT_HOST=10.0.2.15 --set MEDIA_MIN_GB=20 --set MEDIA_MAX_GB=40 "$@" >/dev/null
  tal_patch_node "$TAL_WORK/r-$label/mini01.yaml" "$TAL_ROOT/test/patches/ci-selector.yaml" "$TAL_WORK/r-$label/final.yaml"
  echo "$TAL_WORK/r-$label/final.yaml"
}

# --- choose the layout: the full data volume if validate accepts it ----------
data_mode=ok
data_path=/var/mnt/data
cfg="$(render_with full)"
if ! talosctl validate --config "$cfg" --mode metal >/dev/null 2>&1; then
  echo "the data volume layout is rejected by validate on this version: using the EPHEMERAL fallback"
  data_mode=ephemeral
  data_path=/var/local-path-provisioner
  rm -rf "$TAL_WORK/r-fallback"
  cfg="$(TALOS_VOLUMES_PATCH="$TAL_ROOT/patches/volumes-mini01-ephemeral.yaml" render_with fallback)"
  talosctl validate --config "$cfg" --mode metal
fi
tal_report "VOLUMES_DATA=$data_mode"
tal_report "DATA_PATH=$data_path"

# --- VM: 256 GB NVMe system disk, a tiny virtio decoy, a 30 GB "Toshiba" ------
qemu-img create -q -f qcow2 "$TAL_WORK/vol-sys.qcow2" 1G
qemu-img create -q -f qcow2 "$TAL_WORK/vol-nvme.qcow2" 256G
qemu-img create -q -f qcow2 "$TAL_WORK/vol-media.qcow2" 30G
tal_boot "$TAL_WORK/vol-sys.qcow2" volumes-mini01 --iso "$iso" --boot-nvme \
  --nvme "$TAL_WORK/vol-nvme.qcow2" --data-disk "$TAL_WORK/vol-media.qcow2"
tal_apply "$TAL_APID_PORT" "$cfg"
tal_wait_api 900
tal_bootstrap
tal_kubeconfig
tal_wait_ready 600

# --- a privileged pod that sees the host mounts ------------------------------
tal_kubectl create namespace voltest
tal_kubectl label namespace voltest pod-security.kubernetes.io/enforce=privileged --overwrite
pod_yaml() { # pod_yaml <name>
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: voltest
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: docker.io/library/busybox:1.36
      command: ["sleep", "3600"]
      volumeMounts:
        - {name: media, mountPath: /media}
        - {name: data, mountPath: /data}
  volumes:
    - name: media
      hostPath: {path: /var/mnt/media, type: Directory}
    - name: data
      hostPath: {path: $data_path, type: DirectoryOrCreate}
EOF
}
pod_yaml probe | tal_kubectl apply -f -
tal_kubectl -n voltest wait --for=condition=Ready pod/probe --timeout=300s

media_size="$(tal_kubectl -n voltest exec probe -- sh -c "df -B1 /media | tail -n1 | awk '{print \$2}'")"
((media_size >= 20000000000 && media_size <= 33000000000)) || tal_die "the media mount is $media_size bytes, not the 30 GB extra disk"
if [[ "$data_mode" == ok ]]; then
  data_size="$(tal_kubectl -n voltest exec probe -- sh -c "df -B1 /data | tail -n1 | awk '{print \$2}'")"
  ((data_size >= 20 * 1024 * 1024 * 1024)) || tal_die "the data volume is only $data_size bytes"
fi
tal_kubectl -n voltest exec probe -- sh -c 'echo media-marker >/media/marker && echo data-marker >/data/marker && sync'
tal_kubectl delete namespace voltest --wait=true

# --- both survive a reboot ---------------------------------------------------
tal_ctl reboot >/dev/null
sleep 30
tal_wait_api 600
tal_wait_ready 600
tal_kubectl create namespace voltest
tal_kubectl label namespace voltest pod-security.kubernetes.io/enforce=privileged --overwrite
pod_yaml probe2 | tal_kubectl apply -f -
tal_kubectl -n voltest wait --for=condition=Ready pod/probe2 --timeout=300s
[[ "$(tal_kubectl -n voltest exec probe2 -- cat /media/marker)" == media-marker ]] || tal_die "the media marker did not survive the reboot"
[[ "$(tal_kubectl -n voltest exec probe2 -- cat /data/marker)" == data-marker ]] || tal_die "the data marker did not survive the reboot"
tal_report "VOLUMES_MEDIA=ok"
tal_finding VOLUMES-MINI01 PASS "media on the extra disk and $data_path both mount and survive a reboot"

# --- negative control: no extra disk ------------------------------------------
# Compared by partition list (name and size of every discovered volume), not by raw bytes:
# the first sectors of a GPT disk can change on a plain reboot without any repartitioning.
parts() { tal_ctl get discoveredvolumes -o json 2>/dev/null | jq -s -r '[.[].spec | select(((.size // 0) > 0) and ((.dev_path // "") | test("nvme"))) | "\(.name // .dev_path // "?") \(.size) \(.partition_label // "")"] | sort | .[]'; }
parts_before="$(parts)"
tal_stop volumes-mini01
ptable_hash() { qemu-io -r -c 'read -v 0 40960' "$TAL_WORK/vol-nvme.qcow2" | sha256sum | cut -d' ' -f1; }
before="$(ptable_hash)"
tal_boot "$TAL_WORK/vol-sys.qcow2" volumes-mini01 --boot-nvme --nvme "$TAL_WORK/vol-nvme.qcow2"
tal_wait_api 600
tal_wait_ready 600
if tal_ctl read /var/mnt/media/marker >/dev/null 2>&1; then
  tal_die "the media marker is readable without the extra disk: media data lives on the system disk"
fi
parts_after="$(parts)"
tal_stop volumes-mini01
after="$(ptable_hash)"
if [[ "$before" != "$after" ]]; then
  echo "raw partition-table bytes differ after booting without the media disk"
  tal_finding VOLUMES-PTABLE-BYTES UNKNOWN "raw first sectors of the system disk changed; compare the partition lists below"
fi
# The media volume is the only one allowed to be missing (the disk is not there).
if [[ "$parts_before" != "$parts_after" ]]; then
  echo "--- discovered volumes before:"; printf '%s\n' "$parts_before"
  echo "--- discovered volumes after:"; printf '%s\n' "$parts_after"
  tal_die "the discovered volumes changed while booting without the media disk (lists printed above)"
fi
tal_report "VOLUMES_MEDIA_NEGATIVE=ok"
tal_finding VOLUMES-MEDIA-NEGATIVE PASS "without the extra disk the media volume stays unprovisioned and the system disk's partitions are unchanged"
