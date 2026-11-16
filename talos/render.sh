#!/usr/bin/env bash
# Render the Talos machine config of one node from committed patches, the node
# file and a secrets bundle (plan 15-02). Deterministic for fixed inputs.
#
#   render.sh <node> [--secrets FILE | --ci] [--out DIR] [--force] [--normalize]
#                    [--set KEY=VALUE]... [--schematic NAME] [--no-extras]
#   render.sh --check-secrets-clean
#   render.sh --print-volatile
#
#   <node>             mini01 or mini02 (talos/nodes/<node>.env and .yaml)
#   --secrets FILE     a plaintext secrets bundle (a temp path, never tracked)
#   --ci               generate a throwaway bundle with `talosctl gen secrets`
#   (neither)          decrypt secrets/secrets.sops.yaml with sops (age)
#   --out DIR          output directory (default talos/out, gitignored); it must
#                      not be inside the git work tree except under talos/out
#   --force            overwrite an existing <out>/<node>.yaml
#   --normalize        delete the documented VOLATILE_PATHS from the result
#   --set KEY=VALUE    override a whitelisted node/cluster key (CI and fixtures)
#   --schematic NAME   install-image schematic other than the node's (CI only)
#   --no-extras        skip the volumes and Tailscale patches (CI only)
#   --no-tailscale     skip only the Tailscale patch (CI: the base ISO has no
#                      Tailscale extension)
#
# Inputs and nothing else: cluster.env, nodes/<node>.env and .yaml, patches/*,
# versions.env, optional untracked local/*.local.env, and the secrets bundle.
# Keys that look like secrets are refused. Written files are mode 600.
#
# Env (test hooks): TALOS_NODES_DIR, TALOS_PATCH_DIR, TALOS_SECRETS_DIR,
# TALOS_VOLUMES_PATCH (file replacing patches/volumes-<node>.yaml),
# TALOS_ALLOW_PENDING_PINS=1 (offline fixtures only: placeholder schematic id).
set -euo pipefail
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
nodes_dir="${TALOS_NODES_DIR:-$here/nodes}"
patch_dir="${TALOS_PATCH_DIR:-$here/patches}"
secrets_dir="${TALOS_SECRETS_DIR:-$here/secrets}"

# Paths (yq syntax) that `talosctl gen config` may regenerate on every run even
# with a fixed secrets bundle. Empty until the render-determinism job measures
# a difference; --normalize deletes them so the applied config never depends on
# them.
VOLATILE_PATHS=""

usage() {
  echo "usage: render.sh <node> [--secrets FILE | --ci] [--out DIR] [--force] [--normalize] [--set KEY=VALUE]... [--schematic NAME] [--no-extras] [--no-tailscale]" >&2
  echo "       render.sh --check-secrets-clean | --print-volatile" >&2
  exit 2
}
die() {
  echo "render.sh: $*" >&2
  exit 1
}

node=""
secrets_file=""
ci=0
out="$here/out"
force=0
normalize=0
schematic_override=""
extras=1
tailscale=1
declare -a sets=()
sets_n=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-secrets-clean)
      # Fails if a rendered bundle or a render temp directory is left behind.
      left=0
      if find "$here/out" -maxdepth 2 -name 'secrets*.yaml' 2>/dev/null | grep -q .; then left=1; fi
      if find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'talos-render.*' 2>/dev/null | grep -q .; then left=1; fi
      if ((left)); then die "a secrets bundle or render temp directory was left behind"; fi
      echo "render.sh: no leftovers"
      exit 0
      ;;
    --print-volatile)
      printf '%s\n' "$VOLATILE_PATHS"
      exit 0
      ;;
    --secrets)
      [[ $# -ge 2 ]] || usage
      secrets_file="$2"
      shift 2
      ;;
    --ci)
      ci=1
      shift
      ;;
    --out)
      [[ $# -ge 2 ]] || usage
      out="$2"
      shift 2
      ;;
    --force)
      force=1
      shift
      ;;
    --normalize)
      normalize=1
      shift
      ;;
    --set)
      [[ $# -ge 2 ]] || usage
      sets[sets_n]="$2"
      sets_n=$((sets_n + 1))
      shift 2
      ;;
    --schematic)
      [[ $# -ge 2 ]] || usage
      schematic_override="$2"
      shift 2
      ;;
    --no-extras)
      extras=0
      shift
      ;;
    --no-tailscale)
      tailscale=0
      shift
      ;;
    -*) usage ;;
    *)
      [[ -z "$node" ]] || usage
      node="$1"
      shift
      ;;
  esac
done

[[ -n "$node" ]] || usage
[[ "$node" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "bad node name"
if [[ -n "$secrets_file" && "$ci" == 1 ]]; then die "use either --secrets or --ci"; fi

# ------------------------------------------------------------ key/value store ----
# Parallel arrays (bash 3.2 has no associative arrays).
declare -a KEYS=()
declare -a VALS=()
kv_n=0

kv_set() { # kv_set <key> <value>
  local i=0
  while ((i < kv_n)); do
    if [[ "${KEYS[$i]}" == "$1" ]]; then
      VALS[i]="$2"
      return 0
    fi
    i=$((i + 1))
  done
  KEYS[kv_n]="$1"
  VALS[kv_n]="$2"
  kv_n=$((kv_n + 1))
}

kv_get() { # kv_get <key>  (empty and rc 1 when missing)
  local i=0
  while ((i < kv_n)); do
    if [[ "${KEYS[$i]}" == "$1" ]]; then
      printf '%s' "${VALS[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# Keep in sync with .github/scripts/check-talos-config.sh.
allowed=" CLUSTER_NAME ENDPOINT_HOST K8S_PORT HOSTNAME ROLE SCHEMATIC DISK_TYPE DISK_SIZE_EXPR DISK_SIZE_MIN_GB MEDIA_MIN_GB MEDIA_MAX_GB INSTALLER "

check_key() { # check_key <key> <where>
  [[ "$1" =~ ^[A-Z0-9_]+$ ]] || die "bad key name in $2"
  if [[ "$1" =~ (^|_)(PASS[A-Z]*|HASH|KEY|TOKEN|SECRET)(_|$) ]]; then
    die "key $1 in $2 looks like a secret; secrets are never accepted here"
  fi
  [[ "$allowed" == *" $1 "* ]] || die "unknown key $1 in $2"
}

load_env() { # load_env <file>
  local f="$1" line k v label
  [[ -f "$f" ]] || return 0
  label="$(basename "$f")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || die "$label: not a KEY=VALUE line"
    k="${line%%=*}"
    v="${line#*=}"
    check_key "$k" "$label"
    # One pair of single quotes around the value is allowed.
    if [[ ${#v} -ge 2 && "$v" == \'*\' ]]; then
      v="${v#\'}"
      v="${v%\'}"
    fi
    kv_set "$k" "$v"
  done <"$f"
}

load_env "$here/cluster.env"
load_env "$here/local/cluster.local.env"
[[ -f "$nodes_dir/$node.env" ]] || die "no node file $nodes_dir/$node.env"
load_env "$nodes_dir/$node.env"
load_env "$here/local/$node.local.env"
i=0
while ((i < sets_n)); do
  [[ "${sets[$i]}" == *=* ]] || die "--set needs KEY=VALUE"
  check_key "${sets[$i]%%=*}" "--set"
  kv_set "${sets[$i]%%=*}" "${sets[$i]#*=}"
  i=$((i + 1))
done

need() { # need <key>
  kv_get "$1" || die "missing $1"
}

HOSTNAME_V="$(need HOSTNAME)"
ROLE="$(need ROLE)"
SCHEMATIC="${schematic_override:-$(need SCHEMATIC)}"
DISK_TYPE="$(kv_get DISK_TYPE || true)" # optional: a VM disk has no meaningful type
DISK_SIZE_EXPR="$(need DISK_SIZE_EXPR)"
DISK_SIZE_MIN_GB="$(kv_get DISK_SIZE_MIN_GB || true)" # optional lower bound; keeps a VM from matching the ISO loop devices
CLUSTER_NAME="$(need CLUSTER_NAME)"
ENDPOINT_HOST="$(need ENDPOINT_HOST)"
K8S_PORT="$(need K8S_PORT)"
[[ "$HOSTNAME_V" =~ ^[a-z0-9-]+$ ]] || die "HOSTNAME must be lowercase letters, digits, dashes"
[[ "$ROLE" == controlplane || "$ROLE" == worker ]] || die "ROLE must be controlplane or worker"
[[ "$SCHEMATIC" =~ ^[a-z0-9]+$ ]] || die "bad SCHEMATIC name"
[[ -z "$DISK_TYPE" || "$DISK_TYPE" =~ ^(ssd|hdd|nvme|sd)$ ]] || die "DISK_TYPE must be ssd, hdd, nvme or sd"
[[ "$DISK_SIZE_EXPR" =~ ^[\<\>=]{1,2}\ ?[0-9]+(GB|GiB|MB|MiB|TB|TiB)$ ]] || die "DISK_SIZE_EXPR must look like '>= 200GB'"
[[ -z "$DISK_SIZE_MIN_GB" || "$DISK_SIZE_MIN_GB" =~ ^[0-9]+$ ]] || die "DISK_SIZE_MIN_GB must be a whole number of GB"
[[ "$CLUSTER_NAME" =~ ^[a-z0-9-]+$ ]] || die "bad CLUSTER_NAME"
# Talos 1.14 selects the install disk with a CEL expression (UnattendedInstallConfig).
# Build it from the two simple node keys so node files keep one readable form.
sel_size="$(sed -E 's/^([<>=]+) ?([0-9]+)([A-Za-z]+)$/disk.size \1 \2u * \3/' <<<"$DISK_SIZE_EXPR")"
sel_size="${sel_size/ = / == }"
case "$DISK_TYPE" in
  nvme) sel_type=' && disk.transport == "nvme"' ;;
  ssd) sel_type=' && !disk.rotational' ;;
  hdd) sel_type=' && disk.rotational' ;;
  sd) sel_type=' && disk.transport == "mmc"' ;;
  *) sel_type="" ;;
esac
# Optional lower bound. Booted from the ISO, a VM also lists tiny read-only loop devices that satisfy
# "< 100GB"; without a floor the installer picks /dev/loop0 and fails.
sel_min=""
[[ -z "$DISK_SIZE_MIN_GB" ]] || sel_min=" && disk.size >= ${DISK_SIZE_MIN_GB}u * GB"
kv_set DISK_MATCH "${sel_size}${sel_min}${sel_type}"
# Two identical data disks cannot be told apart by size, so each is pinned by its serial number or,
# where Talos shows none (SATA disks behind some controllers), its WWID (`talosctl get disks`).
# They come from the node's encrypted disk inventory, secrets/disks-<node>.sops.yaml
# (keys `media` and `media2`), so no device identifier is ever in git in the clear.
media_serial=""
media2_serial=""
system_id=""
mirror_id=""
disk_inv="$secrets_dir/disks-$node.sops.yaml"
if ((extras)) && ((!ci)) && [[ -z "$secrets_file" ]] && [[ -f "$disk_inv" ]]; then
  inv_plain="$(sops -d --input-type yaml --output-type yaml "$disk_inv")" || die "cannot decrypt $disk_inv"
  media_serial="$(yq -r '.media // ""' <<<"$inv_plain")"
  media2_serial="$(yq -r '.media2 // ""' <<<"$inv_plain")"
  system_id="$(yq -r '.system // ""' <<<"$inv_plain")"
  mirror_id="$(yq -r '.mirror // ""' <<<"$inv_plain")"
  unset inv_plain
fi
for s in "$media_serial" "$media2_serial" "$system_id" "$mirror_id"; do
  [[ -z "$s" || "$s" =~ ^[A-Za-z0-9_.-]+$ ]] || die "a disk serial may only contain letters, digits, dot, dash, underscore"
done
if [[ -n "$media2_serial" ]]; then
  [[ -n "$media_serial" ]] || die "disk inventory: media2 needs media (both disks must be pinned)"
  [[ "$media_serial" != "$media2_serial" ]] || die "disk inventory: media and media2 are the same serial"
fi
# `system`: the disk Talos installs on, when two disks would otherwise both match (mini02's pair
# of 1 TB drives). `mirror`: the second disk of mini02's ZFS mirror (patches/volumes-mini02.yaml).
if [[ -n "$system_id" ]]; then
  kv_set DISK_MATCH "disk.serial == \"${system_id}\" || disk.wwid == \"${system_id}\""
fi
if [[ -n "$mirror_id" ]]; then
  kv_set ZFS2_MATCH "!system_disk && (disk.serial == \"${mirror_id}\" || disk.wwid == \"${mirror_id}\")"
else
  kv_set ZFS2_MATCH "!system_disk && disk.rotational"
fi
media_extra=""
[[ -n "$media_serial" ]] && media_extra=" && (disk.serial == \"${media_serial}\" || disk.wwid == \"${media_serial}\")"
kv_set MEDIA_EXTRA "$media_extra"
kv_set MEDIA2_MATCH "!system_disk && (disk.serial == \"${media2_serial}\" || disk.wwid == \"${media2_serial}\")"
[[ "$ENDPOINT_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "bad ENDPOINT_HOST"
[[ "$K8S_PORT" =~ ^[0-9]+$ ]] || die "bad K8S_PORT"
if kv_get MEDIA_MIN_GB >/dev/null; then
  [[ "$(kv_get MEDIA_MIN_GB)" =~ ^[0-9]+$ ]] || die "MEDIA_MIN_GB must be a whole number"
fi
if kv_get MEDIA_MAX_GB >/dev/null; then
  [[ "$(kv_get MEDIA_MAX_GB)" =~ ^[0-9]+$ ]] || die "MEDIA_MAX_GB must be a whole number"
fi

# ----------------------------------------------------------------- versions ----
# shellcheck source=/dev/null
. "$here/versions.env"
up="$(printf '%s' "$SCHEMATIC" | tr '[:lower:]' '[:upper:]')"
id_var="SCHEMATIC_${up}_ID"
schematic_id="${!id_var:-}"
if [[ ! "$schematic_id" =~ ^[0-9a-f]{64}$ ]]; then
  if [[ "${TALOS_ALLOW_PENDING_PINS:-0}" == 1 ]]; then
    schematic_id="0000000000000000000000000000000000000000000000000000000000000000"
  else
    die "$id_var is not a pinned 64-hex id (talos/PINS-PENDING?): run talos/refresh-pins.sh --write"
  fi
fi
# Decision D1: which installer image family the node installs and upgrades from.
# `installer` is the classic image; `installer-secureboot` is the UKI image (Secure
# Boot capable, left unenforced in the firmware when D1 is answered (b)).
installer_kind="$(kv_get INSTALLER || true)"
installer_kind="${installer_kind:-installer}"
[[ "$installer_kind" == installer || "$installer_kind" == installer-secureboot ]] ||
  die "INSTALLER must be installer or installer-secureboot (got '$installer_kind')"
install_image="factory.talos.dev/${installer_kind}/${schematic_id}:${TALOS_VERSION}"

# ------------------------------------------------------------------- output ----
repo_top="$(git -C "$here" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$repo_top" ]]; then
  repo_top="$(cd "$repo_top" && pwd -P)"
fi

abs_path() { # resolve a path that may not exist yet (nothing is created)
  local p="$1" rest=""
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [[ ! -d "$p" ]]; do
    rest="/$(basename "$p")$rest"
    p="$(dirname "$p")"
  done
  printf '%s%s' "$(cd "$p" && pwd -P)" "$rest"
}

abs_out="$(abs_path "$out")"
if [[ -n "$repo_top" && "$abs_out" == "$repo_top"/* && "$abs_out" != "$here/out" && "$abs_out" != "$here/out"/* ]]; then
  die "--out must not be inside the git work tree (use a temp dir or talos/out)"
fi
mkdir -p "$abs_out"
target="$abs_out/$node.yaml"
if [[ -e "$target" && "$force" != 1 ]]; then
  die "$target already exists (use --force to overwrite)"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/talos-render.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

# -------------------------------------------------------------- substitution ----
subst_file() { # subst_file <in> <out>: fill every @@KEY@@ from the key/value store
  local s k v n=0
  s="$(cat "$1")"
  while ((n < kv_n)); do
    k="${KEYS[$n]}"
    v="${VALS[$n]}"
    # Unquoted replacement: bash 3.2 (macOS) keeps quotes literally there.
    shopt -u patsub_replacement 2>/dev/null || true
    # shellcheck disable=SC2295
    s="${s//@@$k@@/$v}"
    n=$((n + 1))
  done
  if grep -qE '@@[A-Z0-9_]+@@' <<<"$s"; then
    die "unresolved @@TOKEN@@ in $1"
  fi
  printf '%s\n' "$s" >"$2"
}

[[ -f "$patch_dir/common.yaml" ]] || die "missing $patch_dir/common.yaml"
[[ -f "$patch_dir/$ROLE.yaml" ]] || die "missing $patch_dir/$ROLE.yaml"
[[ -f "$nodes_dir/$node.yaml" ]] || die "missing $nodes_dir/$node.yaml"

declare -a patches=()
patches[0]="$patch_dir/common.yaml"
patches[1]="$patch_dir/$ROLE.yaml"
subst_file "$nodes_dir/$node.yaml" "$tmp/node.yaml"
patches[2]="$tmp/node.yaml"

if ((extras)); then
  vol="${TALOS_VOLUMES_PATCH:-$patch_dir/volumes-$node.yaml}"
  if [[ -f "$vol" ]]; then
    subst_file "$vol" "$tmp/volumes.yaml"
    patches[${#patches[@]}]="$tmp/volumes.yaml"
  fi
  vol2="$patch_dir/volumes-$node-media2.yaml"
  if [[ -n "$media2_serial" && -f "$vol2" ]]; then
    subst_file "$vol2" "$tmp/volumes-media2.yaml"
    patches[${#patches[@]}]="$tmp/volumes-media2.yaml"
  fi
fi

# --------------------------------------------------------------------- secrets ----
if ((ci)); then
  talosctl gen secrets --force -o "$tmp/secrets.yaml" >/dev/null
elif [[ -n "$secrets_file" ]]; then
  [[ -f "$secrets_file" ]] || die "no secrets file $secrets_file"
  if [[ -n "$repo_top" ]] && git -C "$repo_top" ls-files --error-unmatch "$secrets_file" >/dev/null 2>&1; then
    die "$secrets_file is tracked by git; refusing to use a tracked plaintext bundle"
  fi
  cp "$secrets_file" "$tmp/secrets.yaml"
else
  [[ -f "$secrets_dir/secrets.sops.yaml" ]] || die "no $secrets_dir/secrets.sops.yaml (create it per secrets/README.md, or use --ci for a throwaway bundle)"
  sops -d --input-type yaml --output-type yaml "$secrets_dir/secrets.sops.yaml" >"$tmp/secrets.yaml"
fi

# ----------------------------------------------------------- Tailscale and SANs ----
if ((extras && tailscale)); then
  if ((ci)) || [[ -n "$secrets_file" ]]; then
    # Throwaway renders (CI, or an explicit --secrets bundle) never hold the age key, so they always
    # use the key-less patch, even when the real encrypted file exists.
    ts_src="$patch_dir/tailscale.yaml"
    subst_file "$ts_src" "$tmp/tailscale.yaml"
    patches[${#patches[@]}]="$tmp/tailscale.yaml"
  else
    if [[ -f "$secrets_dir/tailscale-$node.sops.yaml" ]]; then
      sops -d --input-type yaml --output-type yaml "$secrets_dir/tailscale-$node.sops.yaml" >"$tmp/tailscale.yaml"
      patches[${#patches[@]}]="$tmp/tailscale.yaml"
    else
      die "no $secrets_dir/tailscale-$node.sops.yaml: the Tailscale auth key is only ever read from an encrypted file (see secrets/README.md)"
    fi
  fi
fi

if [[ "$ROLE" == controlplane ]]; then
  cat >"$tmp/sans.yaml" <<EOF
machine:
  certSANs:
    - ${ENDPOINT_HOST}
---
apiVersion: v1alpha1
kind: KubeAPIServerConfig
certExtraSANs:
  - ${ENDPOINT_HOST}
EOF
  patches[${#patches[@]}]="$tmp/sans.yaml"
fi

# ------------------------------------------------------------------- generate ----
args=(gen config "$CLUSTER_NAME" "https://${ENDPOINT_HOST}:${K8S_PORT}"
  --with-secrets "$tmp/secrets.yaml" --install-image "$install_image"
  --with-docs=false --with-examples=false
  --output-types "$ROLE" --output "$tmp/result.yaml" --force)
if [[ -n "${K8S_VERSION:-}" ]]; then
  args+=(--kubernetes-version "${K8S_VERSION#v}")
fi
for p in "${patches[@]}"; do
  args+=(--config-patch "@$p")
done
talosctl "${args[@]}" >/dev/null

if ((normalize)) && [[ -n "$VOLATILE_PATHS" ]]; then
  for vp in $VOLATILE_PATHS; do
    yq -i "del($vp)" "$tmp/result.yaml"
  done
fi

install -m 600 "$tmp/result.yaml" "$target"
echo "$target"
