#!/usr/bin/env bash
# Apply (or dry-run) the Talos machine config to the nodes, control plane first.
# Plan 15-08. The GitHub workflow (talos-deploy.yaml) only wires the tailnet,
# the secrets and the approval around this script; CI exercises the very same
# script against a Talos QEMU cluster (talos/test/jobs/deploy-apply.sh).
#
# Usage: apply.sh --mode check|apply [--node NAME ...] [--yes]
#
# Inputs (environment only, nothing is read from arguments that could leak):
#   TALOSCONFIG        path to the talosconfig (required)
#   TALOS_NODES        space separated name=endpoint pairs, control plane
#                      first, endpoint is host or host:port  (required)
#   TALOS_CONFIG_DIR   optional: directory holding already rendered <name>.yaml
#                      files (CI uses it; production renders with render.sh)
#   TALOS_RENDER_ARGS  optional extra arguments for render.sh, for example
#                      "--secrets FILE" (never a secret value itself)
#   SOPS_AGE_KEY_FILE  optional, passed through to render.sh
#   TALOS_DEPLOY_LOG   optional file: one line per talosctl subcommand used
#                      (the CI negative control reads it); never arguments
#   CI_APPROVED=1      set by the workflow after the environment approval
#
# Output: one `DEPLOY node=<n> mode=<m> result=<NOCHANGE|CHANGES|APPLIED|REJECTED>`
# line per node. It never prints a config, a secret or an address; a dry-run
# diff is reduced to the number of changed lines.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
talos_dir="$(cd "$here/.." && pwd)"

mode=""
yes=0
only=()
while (($#)); do
  case "$1" in
    --mode)
      mode="${2:-}"
      shift 2
      ;;
    --node)
      only+=("${2:-}")
      shift 2
      ;;
    --yes)
      yes=1
      shift
      ;;
    -h | --help)
      sed -n '2,28p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "apply.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

case "$mode" in
  check | apply) ;;
  *)
    echo "apply.sh: --mode check|apply is required" >&2
    exit 2
    ;;
esac
: "${TALOSCONFIG:?apply.sh: TALOSCONFIG is required}"
: "${TALOS_NODES:?apply.sh: TALOS_NODES is required}"

if [[ "$mode" == apply && "$yes" -ne 1 && "${CI_APPROVED:-}" != 1 ]]; then
  echo "apply.sh: refusing to apply without --yes or CI_APPROVED=1" >&2
  exit 2
fi

log_cmd() {
  # Subcommand name only: the file proves what was (not) called, no arguments.
  if [[ -n "${TALOS_DEPLOY_LOG:-}" ]]; then
    printf '%s\n' "$1" >>"$TALOS_DEPLOY_LOG"
  fi
}

# talosctl wrapper: logs the subcommand, keeps stdout for the caller.
tctl() {
  log_cmd "$1"
  talosctl "$@"
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- node list ---------------------------------------------------------------
names=()
endpoints=()
for pair in $TALOS_NODES; do
  n="${pair%%=*}"
  e="${pair#*=}"
  if [[ -z "$n" || -z "$e" || "$n" == "$pair" ]]; then
    echo "apply.sh: bad TALOS_NODES entry (want name=endpoint)" >&2
    exit 2
  fi
  if ((${#only[@]})); then
    keep=0
    for o in "${only[@]}"; do
      [[ "$o" == "$n" ]] && keep=1
    done
    ((keep)) || continue
  fi
  names+=("$n")
  endpoints+=("$e")
done
if ((${#names[@]} == 0)); then
  echo "apply.sh: no nodes selected" >&2
  exit 2
fi
cp_endpoint="${endpoints[0]}"

# --- 1. render every config first, validate ALL before touching any node -----
configs=()
rejected=0
for i in "${!names[@]}"; do
  n="${names[$i]}"
  if [[ -n "${TALOS_CONFIG_DIR:-}" ]]; then
    cfg="$TALOS_CONFIG_DIR/$n.yaml"
    if [[ ! -f "$cfg" ]]; then
      echo "DEPLOY node=$n mode=$mode result=REJECTED"
      echo "apply.sh: no rendered config for $n in TALOS_CONFIG_DIR" >&2
      rejected=1
      configs+=("")
      continue
    fi
  else
    # shellcheck disable=SC2086 # TALOS_RENDER_ARGS is a word list by design
    if ! bash "$talos_dir/render.sh" "$n" --out "$work" ${TALOS_RENDER_ARGS:-} >/dev/null 2>"$work/render-$n.err"; then
      echo "DEPLOY node=$n mode=$mode result=REJECTED"
      echo "apply.sh: render failed for $n (details withheld)" >&2
      rejected=1
      configs+=("")
      continue
    fi
    cfg="$work/$n.yaml"
  fi
  if tctl validate --config "$cfg" --mode metal >"$work/validate-$n.out" 2>&1; then
    configs+=("$cfg")
  else
    echo "DEPLOY node=$n mode=$mode result=REJECTED"
    echo "apply.sh: validate failed for $n (details withheld)" >&2
    rejected=1
    configs+=("")
  fi
done
if ((rejected)); then
  # Nothing has been sent to any node at this point.
  exit 1
fi

# --- 2. per node: dry-run diff, then (apply mode) apply and wait for health --
status=0
for i in "${!names[@]}"; do
  n="${names[$i]}"
  ep="${endpoints[$i]}"
  node="${ep%%:*}"
  cfg="${configs[$i]}"

  if ! tctl apply-config --nodes "$node" --endpoints "$ep" --file "$cfg" --mode=auto --dry-run >"$work/dry-$n.out" 2>&1; then
    echo "DEPLOY node=$n mode=$mode result=REJECTED"
    echo "apply.sh: dry-run failed for $n (details withheld)" >&2
    status=1
    break
  fi
  # Reduce the diff to a count: the lines themselves may hold config values.
  changed="$(grep -cE '^[+-][^+-]' "$work/dry-$n.out" || true)"

  if [[ "$changed" == "0" ]]; then
    echo "DEPLOY node=$n mode=$mode result=NOCHANGE"
    continue
  fi
  if [[ "$mode" == check ]]; then
    echo "DEPLOY node=$n mode=$mode result=CHANGES changed_lines=$changed"
    continue
  fi

  if ! tctl apply-config --nodes "$node" --endpoints "$ep" --file "$cfg" --mode=auto >"$work/apply-$n.out" 2>&1; then
    echo "DEPLOY node=$n mode=$mode result=REJECTED"
    echo "apply.sh: apply failed for $n (details withheld)" >&2
    status=1
    break
  fi
  # Health before the next node. Workers are checked through the control plane.
  if [[ "$ep" == "$cp_endpoint" ]]; then
    health=(--nodes "${cp_endpoint%%:*}" --endpoints "$cp_endpoint")
  else
    health=(--nodes "${cp_endpoint%%:*}" --endpoints "$cp_endpoint" --worker-nodes "$node")
  fi
  if ! tctl health "${health[@]}" --wait-timeout 10m >"$work/health-$n.out" 2>&1; then
    echo "DEPLOY node=$n mode=$mode result=REJECTED"
    echo "apply.sh: health check failed after applying $n (details withheld)" >&2
    status=1
    break
  fi
  echo "DEPLOY node=$n mode=$mode result=APPLIED"
done

exit "$status"
