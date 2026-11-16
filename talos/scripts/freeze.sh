#!/usr/bin/env bash
# Freeze and unfreeze the OLD k3s cluster around the final backup (plan 15-07,
# cutover steps 5 and the rollback). operator-run: this WRITES to the live cluster.
#
#   freeze.sh freeze   --context C [--state FILE] [--yes]
#   freeze.sh unfreeze --context C [--state FILE] [--yes]
#
# freeze: records every replica count it is about to change in the state file
# (default ~/.cutover-freeze-<context>.tsv, outside the repo; an existing file is
# never overwritten), then scales to 0, in this order: the Argo CD application
# controller (so nothing is re-created), every Deployment and StatefulSet in
# `homeserver` and in `cp-reserva-bot`, then any other MinIO Deployment. It waits until no Immich,
# Vaultwarden, cp-reserva or MinIO pod is Running. This also stops the writer of
# the backup disk.
# unfreeze: scales everything back to the recorded counts, MinIO first and the
# Argo CD controller last.
#
# Refuses to run without an explicit --context. Without --yes it prints the plan
# and asks you to type `<mode> <context>`. Prints `FREEZE DONE targets=<n>` or
# `UNFREEZE DONE targets=<n>`; exit 0 on success, 1 on a failure or a timeout.
#
# Env: FREEZE_WAIT_SECONDS (default 180) bounds the wait for pods to stop.
set -euo pipefail

usage() {
  echo "usage: freeze.sh freeze|unfreeze --context C [--state FILE] [--yes]" >&2
  exit 2
}

mode="${1:-}"
shift || true
[[ "$mode" == freeze || "$mode" == unfreeze ]] || usage
ctx=""
state=""
yes=0
while (($#)); do
  case "$1" in
    --context)
      ctx="${2:-}"
      shift 2
      ;;
    --state)
      state="${2:-}"
      shift 2
      ;;
    --yes)
      yes=1
      shift
      ;;
    *) usage ;;
  esac
done
[[ -n "$ctx" ]] || {
  echo "REFUSED: --context is required (never run this against whatever the default context is)" >&2
  exit 2
}
state="${state:-$HOME/.cutover-freeze-${ctx//[^A-Za-z0-9_.-]/_}.tsv}"
k() { kubectl --context "$ctx" "$@"; }

k get ns >/dev/null 2>&1 || {
  echo "cannot reach the cluster for context $ctx" >&2
  exit 1
}

confirm() { # confirm <plan text>
  echo "$1"
  ((yes)) && return 0
  read -r -p "type '$mode $ctx' to go on: " answer
  [[ "$answer" == "$mode $ctx" ]] || {
    echo "not confirmed" >&2
    exit 2
  }
}

scale() { # scale <kind> <namespace> <name> <replicas>
  k -n "$2" scale "$1" "$3" --replicas="$4" >/dev/null
}

if [[ "$mode" == freeze ]]; then
  [[ ! -e "$state" ]] || {
    echo "REFUSED: $state exists (a freeze is already recorded; unfreeze first or choose another --state)" >&2
    exit 2
  }
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  # kind<TAB>namespace<TAB>name<TAB>replicas, in freeze order.
  k -n argocd get statefulset argocd-application-controller -o json 2>/dev/null |
    jq -r '[ "statefulset", .metadata.namespace, .metadata.name, (.spec.replicas // 0) ] | @tsv' >>"$tmp" || true
  k -n homeserver get deployment,statefulset -o json |
    jq -r '.items[] | [ (.kind | ascii_downcase), .metadata.namespace, .metadata.name, (.spec.replicas // 0) ] | @tsv' >>"$tmp"
  # The WhatsApp bot runs in its own namespace, not in homeserver. Left running it would
  # keep writing its session volume after the final backup, and the wait below would
  # time out because a cp-reserva pod is still Running.
  k -n cp-reserva-bot get deployment,statefulset -o json 2>/dev/null |
    jq -r '.items[] | [ (.kind | ascii_downcase), .metadata.namespace, .metadata.name, (.spec.replicas // 0) ] | @tsv' >>"$tmp" || true
  k get deployment -A -o json |
    jq -r '.items[] | select(.metadata.name | test("minio")) | select(.metadata.namespace != "homeserver") | [ "deployment", .metadata.namespace, .metadata.name, (.spec.replicas // 0) ] | @tsv' >>"$tmp"
  n="$(wc -l <"$tmp" | tr -d ' ')"
  ((n > 0)) || {
    echo "nothing to freeze found in context $ctx" >&2
    exit 1
  }
  confirm "FREEZE plan for context $ctx ($n workloads to 0, counts saved to $state):
$(awk -F'\t' '{printf "  %s %s/%s (now %s)\n", $1, $2, $3, $4}' "$tmp")"
  cp "$tmp" "$state"
  while IFS=$'\t' read -r kind ns name replicas; do
    [[ "$replicas" == 0 ]] && continue
    scale "$kind" "$ns" "$name" 0
  done <"$state"

  deadline=$((SECONDS + ${FREEZE_WAIT_SECONDS:-180}))
  while :; do
    running="$(k get pods -A -o json | jq -r '[.items[] | select(.metadata.name | test("minio|immich|vaultwarden|cp-reserva")) | select(.status.phase == "Running")] | length')"
    [[ "$running" == 0 ]] && break
    ((SECONDS < deadline)) || {
      echo "FREEZE WAIT-TIMEOUT $running pod(s) still Running (state kept in $state)" >&2
      exit 1
    }
    sleep 5
  done
  echo "FREEZE DONE targets=$n"
  exit 0
fi

# ---- unfreeze ----------------------------------------------------------------
[[ -f "$state" ]] || {
  echo "REFUSED: no state file $state: nothing recorded to restore" >&2
  exit 2
}
n="$(wc -l <"$state" | tr -d ' ')"
confirm "UNFREEZE plan for context $ctx ($n workloads back to their recorded counts, MinIO first, the Argo CD controller last):
$(awk -F'\t' '{printf "  %s %s/%s -> %s\n", $1, $2, $3, $4}' "$state")"
# Reverse order: the last frozen (MinIO) first, the Argo CD controller last.
tac_file="$(mktemp)"
trap 'rm -f "$tac_file"' EXIT
awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}' "$state" >"$tac_file"
while IFS=$'\t' read -r kind ns name replicas; do
  [[ "$replicas" == 0 ]] && continue
  scale "$kind" "$ns" "$name" "$replicas"
done <"$tac_file"
echo "UNFREEZE DONE targets=$n"
