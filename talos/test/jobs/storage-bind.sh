#!/usr/bin/env bash
# talos-job: kvm=yes timeout=60
# G1 finding STORAGE-BIND (plan 15-03 task 3): whichever storage the 15-04
# verdict chose, every PVC shape the current apps ask for binds on the Talos
# cluster and keeps data across a pod restart. The job refuses to guess: the
# verdict in talos/FINDINGS.md must exist and agree with talos/apps-overrides.yaml.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"
# shellcheck source=talos/test/lib-platform.sh
. "$here/../lib-platform.sh"
# shellcheck source=talos/test/lib-find.sh
. "$here/../lib-find.sh"

# --- the verdict ------------------------------------------------------------------------
# (talos/FINDINGS.md is created from talos/findings/FINDINGS.md.template once the
# find-storage job has produced a verdict.)
verdict="$(grep -m1 '^STORAGE_VERDICT=' "$TAL_ROOT/FINDINGS.md" 2>/dev/null | cut -d= -f2 || true)"
case "$verdict" in
  local-path | topolvm) ;;
  *) tal_die "talos/FINDINGS.md has no STORAGE_VERDICT=local-path|topolvm line (got '${verdict:-nothing}'): run the find-storage job first, commit its verdict, and do not guess" ;;
esac
chosen="$(yq -r '.storage' "$TAL_ROOT/apps-overrides.yaml")"
[[ "$verdict" == "$chosen" ]] || tal_die "the verdict is '$verdict' but talos/apps-overrides.yaml says storage: $chosen; change the override and run render-apps.sh --force"

# --- the PVC shapes the apps ask for, regenerated from the repo, not typed -----------------
shapes="$TAL_WORK/pvc-shapes.txt"
: >"$shapes"
for f in "$TAL_ROOT"/../argocd/manifests/immich-infra/immich-library-pvc.yaml "$TAL_ROOT"/../argocd/manifests/vaultwarden-pvc/pvc.yaml; do
  yq -r 'select(.kind == "PersistentVolumeClaim") | .metadata.name + " " + (.spec.storageClassName // "") + " " + (.spec.resources.requests.storage // "") + " " + (.spec.accessModes[0] // "")' "$f" | grep -v '^---' >>"$shapes"
done
# the Postgres volume (CNPG) and the bot's volume come from a Cluster and a values file
yq -r 'select(.kind == "Cluster") | "immich-pg-data " + .spec.storage.storageClass + " " + .spec.storage.size + " ReadWriteOnce"' "$TAL_ROOT/../argocd/manifests/immich-infra/immich-cluster.yaml" | grep -v '^---' >>"$shapes"
yq -r '"cp-reserva-bot-data " + .persistence.storageClass + " " + .persistence.size + " ReadWriteOnce"' "$TAL_ROOT/../argocd/values/cp-reserva-bot.yaml" >>"$shapes"
count="$(grep -c . "$shapes")"
tal_report "PVC_SHAPES=${count}"

# --- cluster, apps, storage ------------------------------------------------------------------
tal_platform_up
tal_find_images
tal_bootstrap_only namespaces
tal_bootstrap_only cluster-baseline
if [[ "$verdict" == local-path ]]; then
  tal_bootstrap_only local-path-provisioner
else
  tal_bootstrap_only topolvm
fi
tal_psa_privileged tal-storage
tal_kubectl -n tal-storage delete pvc --all --ignore-not-found >/dev/null

bound=0
survives=0
while read -r name class size mode; do
  [[ -n "$name" ]] || continue
  # a scratch PVC of the same shape (class, size, access mode)
  tal_kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: ${name}, namespace: tal-storage}
spec:
  accessModes: [${mode:-ReadWriteOnce}]
  storageClassName: ${class}
  resources: {requests: {storage: ${size}}}
EOF
  mk_pod() { # mk_pod <pod> <command>
    tal_kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: tal-storage}
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: ${TAL_ALPINE}
      command: ["/bin/sh", "-c", "$2"]
      volumeMounts: [{name: v, mountPath: /d}]
  volumes: [{name: v, persistentVolumeClaim: {claimName: ${name}}}]
EOF
  }
  want="$(yes storage-bind | head -c 10485760 | sha256sum | cut -d' ' -f1)"
  mk_pod "w-${name}" 'yes storage-bind | head -c 10485760 > /d/f && sync && sha256sum /d/f'
  if tal_kubectl -n tal-storage wait --for=jsonpath='{.status.phase}'=Succeeded "pod/w-${name}" --timeout=300s >/dev/null 2>&1; then
    phase="$(tal_kubectl -n tal-storage get pvc "${name}" -o jsonpath='{.status.phase}')"
    [[ "$phase" == Bound ]] && bound=$((bound + 1))
    tal_kubectl -n tal-storage delete pod "w-${name}" --wait=true >/dev/null
    mk_pod "r-${name}" 'sha256sum /d/f'
    tal_kubectl -n tal-storage wait --for=jsonpath='{.status.phase}'=Succeeded "pod/r-${name}" --timeout=300s >/dev/null 2>&1 || true
    got="$(tal_kubectl -n tal-storage logs "r-${name}" 2>/dev/null | cut -d' ' -f1)"
    [[ "$got" == "$want" ]] && survives=$((survives + 1))
  else
    echo "claim ${name} (${class}, ${size}) did not get a working pod"
  fi
done <"$shapes"

tal_report "STORAGE ${verdict} PVC_COUNT=${count} BOUND=${bound} SURVIVES=${survives}"
if [[ "$count" -eq "$bound" && "$count" -eq "$survives" && "$count" -gt 0 ]]; then
  tal_finding STORAGE-BIND PASS "${verdict}: ${count} PVC shapes bound and kept a 10 MiB file across a pod restart"
else
  tal_finding STORAGE-BIND FAIL "${verdict}: ${count} shapes, ${bound} bound, ${survives} kept their data"
fi
tal_summary
