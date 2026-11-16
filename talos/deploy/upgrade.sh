#!/usr/bin/env bash
# Roll out a Talos or Kubernetes version bump, control plane first.
# Plan 15-08. The target versions come from talos/versions.env (the pins file
# owned by plan 15-01); the installer image is built from the node's schematic
# id and the pinned Talos version, never from `latest`.
#
# Usage: upgrade.sh --talos|--k8s [--dry-run] [--yes] [--no-preserve]
#
# Environment: as apply.sh (TALOSCONFIG, TALOS_NODES, TALOS_DEPLOY_LOG,
#   CI_APPROVED=1), plus
#   VERSIONS_FILE   override for the pins file (tests)
#   NODES_DIR       override for talos/nodes (tests)
#   TALOS_CI=1      only in CI: allows --no-preserve for the data-loss question
#
# Output: `UPGRADE node=<n> from=<v> to=<v> result=<UPGRADED|PLANNED|FAILED>`
# (Kubernetes: `UPGRADE k8s to=<v> result=...`). No config, secret or address
# is printed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
talos_dir="$(cd "$here/.." && pwd)"
versions_file="${VERSIONS_FILE:-$talos_dir/versions.env}"
nodes_dir="${NODES_DIR:-$talos_dir/nodes}"

what=""
dry=0
yes=0
preserve=1
while (($#)); do
  case "$1" in
    --talos) what=talos ;;
    --k8s) what=k8s ;;
    --dry-run) dry=1 ;;
    --yes) yes=1 ;;
    --no-preserve) preserve=0 ;;
    -h | --help)
      sed -n '2,18p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "upgrade.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done
[[ -n "$what" ]] || {
  echo "upgrade.sh: --talos or --k8s is required" >&2
  exit 2
}
: "${TALOSCONFIG:?upgrade.sh: TALOSCONFIG is required}"
: "${TALOS_NODES:?upgrade.sh: TALOS_NODES is required}"
if ((preserve == 0)) && [[ "${TALOS_CI:-}" != 1 ]]; then
  echo "upgrade.sh: --no-preserve is for CI only (TALOS_CI=1)" >&2
  exit 2
fi
if ((dry == 0)) && [[ "$yes" -ne 1 && "${CI_APPROVED:-}" != 1 ]]; then
  echo "upgrade.sh: refusing to upgrade without --yes or CI_APPROVED=1" >&2
  exit 2
fi

log_cmd() {
  if [[ -n "${TALOS_DEPLOY_LOG:-}" ]]; then
    printf '%s\n' "$1" >>"$TALOS_DEPLOY_LOG"
  fi
}
tctl() {
  log_cmd "$1"
  talosctl "$@"
}

[[ -f "$versions_file" ]] || {
  echo "upgrade.sh: pins file not found" >&2
  exit 2
}
# versions.env is KEY=VALUE only (plan 15-01), safe to source.
# shellcheck source=/dev/null
. "$versions_file"
: "${TALOS_VERSION:?TALOS_VERSION missing from the pins file}"
: "${K8S_VERSION:?K8S_VERSION missing from the pins file}"
: "${FACTORY_URL:?FACTORY_URL missing from the pins file}"

names=()
endpoints=()
for pair in $TALOS_NODES; do
  names+=("${pair%%=*}")
  endpoints+=("${pair#*=}")
done
cp_endpoint="${endpoints[0]}"
cp_node="${cp_endpoint%%:*}"

# Current Talos version of a node, as `vX.Y.Z` (empty when unreadable).
node_version() {
  local node="$1" ep="$2"
  tctl version --nodes "$node" --endpoints "$ep" 2>/dev/null |
    awk '/^Server:/{s=1} s && /Tag:/{print $2; exit}'
}

# `--preserve` exists on current talosctl; detect instead of assuming.
preserve_flag=()
if ((preserve)); then
  if talosctl upgrade --help 2>&1 | grep -q -- '--preserve'; then
    preserve_flag=(--preserve)
  else
    echo "UPGRADE note=preserve-flag-unsupported"
  fi
fi

if [[ "$what" == k8s ]]; then
  to="${K8S_VERSION#v}"
  args=(upgrade-k8s --nodes "$cp_node" --endpoints "$cp_endpoint" --to "$to")
  if ((dry)); then
    if tctl "${args[@]}" --dry-run >/dev/null 2>&1; then
      echo "UPGRADE k8s to=$to result=PLANNED"
      exit 0
    fi
    echo "UPGRADE k8s to=$to result=FAILED"
    exit 1
  fi
  if tctl "${args[@]}" >/dev/null 2>&1; then
    echo "UPGRADE k8s to=$to result=UPGRADED"
    exit 0
  fi
  echo "UPGRADE k8s to=$to result=FAILED"
  exit 1
fi

# --- Talos, node by node, control plane first --------------------------------
status=0
for i in "${!names[@]}"; do
  n="${names[$i]}"
  ep="${endpoints[$i]}"
  node="${ep%%:*}"

  # Schematic of the node: nodes/<n>.env SCHEMATIC=<name> -> SCHEMATIC_<NAME>_ID.
  schem=""
  if [[ -f "$nodes_dir/$n.env" ]]; then
    schem="$(sed -n 's/^SCHEMATIC=//p' "$nodes_dir/$n.env" | head -n1 | tr -d "\"' ")"
  fi
  # Installer family of the node (decision D1): nodes/<n>.env INSTALLER, default classic.
  kind=""
  if [[ -f "$nodes_dir/$n.env" ]]; then
    kind="$(sed -n 's/^INSTALLER=//p' "$nodes_dir/$n.env" | head -n1 | tr -d "\"' ")"
  fi
  kind="${kind:-installer}"
  case "$kind" in
    installer | installer-secureboot) ;;
    *)
      echo "UPGRADE node=$n from=unknown to=$TALOS_VERSION result=FAILED"
      echo "upgrade.sh: INSTALLER for $n must be installer or installer-secureboot" >&2
      status=1
      break
      ;;
  esac
  # CI clusters have no node file: they pass the id through the environment.
  schem="${schem:-${TALOS_SCHEMATIC_NAME:-base}}"
  key="SCHEMATIC_$(printf '%s' "$schem" | tr '[:lower:]-' '[:upper:]_')_ID"
  id="${!key:-}"
  if [[ -z "$id" ]]; then
    echo "UPGRADE node=$n from=unknown to=$TALOS_VERSION result=FAILED"
    echo "upgrade.sh: no schematic id pinned for $n" >&2
    status=1
    break
  fi
  image="${FACTORY_URL#https://}/${kind}/${id}:${TALOS_VERSION}"
  case "$image" in
    *latest*)
      echo "upgrade.sh: refusing an installer image that contains 'latest'" >&2
      exit 2
      ;;
  esac

  from="$(node_version "$node" "$ep")"
  from="${from:-unknown}"
  if ((dry)); then
    echo "UPGRADE node=$n from=$from to=$TALOS_VERSION result=PLANNED"
    continue
  fi
  if [[ "$from" == "$TALOS_VERSION" ]]; then
    echo "UPGRADE node=$n from=$from to=$TALOS_VERSION result=UPGRADED note=already-current"
    continue
  fi

  if ! tctl upgrade --nodes "$node" --endpoints "$ep" --image "$image" ${preserve_flag[@]+"${preserve_flag[@]}"} --wait >/dev/null 2>&1; then
    echo "UPGRADE node=$n from=$from to=$TALOS_VERSION result=FAILED"
    status=1
    break
  fi
  now="$(node_version "$node" "$ep")"
  if [[ "$now" != "$TALOS_VERSION" ]]; then
    echo "UPGRADE node=$n from=$from to=$TALOS_VERSION result=FAILED note=version-after=${now:-unknown}"
    status=1
    break
  fi
  # Health before the next node (workers are checked through the control plane).
  if [[ "$ep" == "$cp_endpoint" ]]; then
    health=(--nodes "$cp_node" --endpoints "$cp_endpoint")
  else
    health=(--nodes "$cp_node" --endpoints "$cp_endpoint" --worker-nodes "$node")
  fi
  if ! tctl health "${health[@]}" --wait-timeout 10m >/dev/null 2>&1; then
    echo "UPGRADE node=$n from=$from to=$TALOS_VERSION result=FAILED note=health"
    status=1
    break
  fi
  echo "UPGRADE node=$n from=$from to=$TALOS_VERSION result=UPGRADED"
done
exit "$status"
