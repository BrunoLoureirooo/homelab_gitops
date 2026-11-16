#!/usr/bin/env bash
# The empty-cluster sync order on Talos (plan 15-03), the Talos form of plan
# 01-12's order. The same script is the CI proof (--ci) and the cutover step
# (--live, operator-run, plan 15-07).
#
#   bootstrap-argocd.sh --ci|--live [--yes] [--sealing-key FILE] [--from STEP]
#                       [--revision REV] [--minio-url URL] [--only STEP]
#
#   --only STEP  apply all Applications but run just that one step (CI jobs that
#                need a single app)
#
#   --ci         refuses unless the kube context is exactly admin@talos-ci
#   --live       prints the context and requires it typed back (--yes is ignored)
#   --revision   CI: apply the Applications directly with every targetRevision of
#                this repository rewritten to REV (the commit under test)
#                live: omitted; talos/root.yaml is applied and the Applications
#                come from git at main
#   --sealing-key  a Secret manifest for the Sealed Secrets controller key,
#                applied BEFORE sealed-secrets syncs (CI: a throwaway key)
#   --from STEP  resume at a step name (see the list printed at the start)
#   --minio-url  accepted for the cutover; velero's backup location needs it to
#                become Available (plan 15-06), otherwise velero is expected to
#                stay Degraded
#
# Exit codes: 0 done, 1 a sync operation failed, 3 wrong context (nothing was
# touched), 64 usage. No sync waves are used: the order is this list.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_url="https://github.com/BrunoLoureirooo/homelab_gitops"
mode=""
sealing_key=""
from=""
only=""
revision=""
minio_url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ci | --live)
      mode="${1#--}"
      shift
      ;;
    --yes)
      # accepted for symmetry with other helpers; --ci never prompts and --live always does
      shift
      ;;
    --sealing-key)
      sealing_key="${2:?--sealing-key needs a file}"
      shift 2
      ;;
    --from)
      from="${2:?--from needs a step name}"
      shift 2
      ;;
    --only)
      only="${2:?--only needs a step name}"
      shift 2
      ;;
    --revision)
      revision="${2:?--revision needs a commit or branch}"
      shift 2
      ;;
    --minio-url)
      minio_url="${2:?--minio-url needs a URL}"
      shift 2
      ;;
    *)
      echo "usage: bootstrap-argocd.sh --ci|--live [--yes] [--sealing-key FILE] [--from STEP] [--revision REV] [--minio-url URL] [--only STEP]" >&2
      exit 64
      ;;
  esac
done
[[ -n "$mode" ]] || {
  echo "bootstrap-argocd: say --ci or --live" >&2
  exit 64
}

# --- the context guard comes before anything touches a cluster ----------------------
ctx="$(kubectl config current-context 2>/dev/null || true)"
if [[ "$mode" == ci ]]; then
  if [[ "$ctx" != admin@talos-ci ]]; then
    echo "bootstrap-argocd: --ci needs the kube context admin@talos-ci (current: '${ctx:-none}'); nothing was touched" >&2
    exit 3
  fi
else
  [[ -n "$ctx" ]] || {
    echo "bootstrap-argocd: no kube context; nothing was touched" >&2
    exit 3
  }
  echo "bootstrap-argocd: this will sync the REAL cluster in context '$ctx'."
  printf 'Type the context name to continue: '
  read -r typed
  if [[ "$typed" != "$ctx" ]]; then
    echo "bootstrap-argocd: the typed name does not match; nothing was touched" >&2
    exit 3
  fi
fi

apps_dir="$here/apps"
ns=argocd
timeout_s="${BOOTSTRAP_SYNC_TIMEOUT:-600}"

have_app() { [[ -f "$apps_dir/$1.yaml" ]]; }

# --- apply the Applications -------------------------------------------------------------
if [[ -n "$revision" ]]; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  for f in "$apps_dir"/*.yaml; do
    cp "$f" "$work/$(basename "$f")"
    yq -i "(.. | select(tag == \"!!map\" and has(\"repoURL\") and .repoURL == \"$repo_url\") | .targetRevision) = \"$revision\"" "$work/$(basename "$f")"
    kubectl apply -f "$work/$(basename "$f")" >/dev/null
  done
  echo "bootstrap-argocd: applied $(find "$apps_dir" -maxdepth 1 -name '*.yaml' | wc -l | tr -d ' ') Applications at revision $revision"
else
  kubectl apply -f "$here/root.yaml" >/dev/null
  for _ in $(seq 1 30); do
    kubectl -n "$ns" get application namespaces >/dev/null 2>&1 && break
    sleep 5
  done
  echo "bootstrap-argocd: applied talos/root.yaml (Applications come from git at main)"
fi

# --- helpers ------------------------------------------------------------------------------
app_field() { # app_field <app> <jsonpath>
  kubectl -n "$ns" get application "$1" -o jsonpath="$2" 2>/dev/null || true
}

sync_app() { # sync_app <app>
  local app="$1" deadline phase
  if ! kubectl -n "$ns" get application "$app" >/dev/null 2>&1; then
    echo "bootstrap-argocd: Application $app does not exist; skipped"
    return 0
  fi
  kubectl -n "$ns" patch application "$app" --type merge \
    -p '{"operation":{"initiatedBy":{"username":"bootstrap"},"sync":{"syncOptions":["CreateNamespace=true"]}}}' >/dev/null 2>&1 || true
  deadline=$((SECONDS + timeout_s))
  while ((SECONDS < deadline)); do
    phase="$(app_field "$app" '{.status.operationState.phase}')"
    case "$phase" in
      Succeeded | Failed | Error) break ;;
    esac
    sleep 5
  done
  # let the health settle for a while (Progressing becomes Healthy or Degraded)
  local settle=$((SECONDS + 120)) health
  while ((SECONDS < settle)); do
    health="$(app_field "$app" '{.status.health.status}')"
    [[ "$health" != Progressing && "$health" != Missing && -n "$health" ]] && break
    sleep 5
  done
  echo "STEP $app operation=${phase:-none} sync=$(app_field "$app" '{.status.sync.status}') health=$(app_field "$app" '{.status.health.status}')"
}

pause() { # pause <name> <what to do>
  if [[ "$mode" == ci ]]; then
    echo "SKIP $1 (ci)"
  else
    echo "PAUSE $1: $2"
    printf 'Type "restored" when this is done: '
    local a
    read -r a
    [[ "$a" == restored ]] || {
      echo "bootstrap-argocd: stopped at $1" >&2
      exit 1
    }
  fi
}

# --- the order ------------------------------------------------------------------------------
storage_app=local-path-provisioner
have_app topolvm && storage_app=topolvm

steps=(namespaces sealing-key cluster-baseline sealed-secrets sealed-secrets-set cert-manager cnpg-operator "$storage_app" metrics-server
  tailscale-operator talos-sealed-secrets velero volume-restore-pause immich-infra db-restore-pause immich vaultwarden-pvc vaultwarden cp-reserva-bot)
echo "bootstrap-argocd: steps: ${steps[*]}"
[[ -z "$minio_url" ]] || echo "bootstrap-argocd: MinIO URL given; velero's location can become Available"

started=0
[[ -z "$from" ]] && started=1
for step in "${steps[@]}"; do
  if ((!started)); then
    if [[ "$step" == "$from" ]]; then started=1; else continue; fi
  fi
  if [[ -n "$only" && "$step" != "$only" ]]; then
    continue
  fi
  case "$step" in
    sealing-key)
      if [[ -n "$sealing_key" ]]; then
        kubectl apply -f "$sealing_key" >/dev/null
        echo "STEP sealing-key applied"
      else
        echo "STEP sealing-key none given (the controller will generate its own key; sealed secrets will not decrypt)"
      fi
      ;;
    volume-restore-pause)
      pause "$step" "restore the Velero volume backups (vaultwarden, cp-reserva-bot, immich library) now"
      ;;
    db-restore-pause)
      pause "$step" "restore the Immich database from its dump into immich-pg-1 now"
      ;;
    cnpg-operator | talos-sealed-secrets)
      if have_app "$step"; then
        sync_app "$step"
      else
        echo "STEP $step not in talos/apps yet (added by plan 15-06); skipped"
      fi
      ;;
    *) sync_app "$step" ;;
  esac
done

echo "---- final state ----"
kubectl -n "$ns" get applications -o json |
  jq -r '.items | sort_by(.metadata.name)[] | "APP \(.metadata.name) \(.status.sync.status // "Unknown") \(.status.health.status // "Unknown")"'
