# shellcheck shell=bash
# Helpers shared by the plan 15-06 CI jobs (velero-roundtrip, sealing-key, litestream-roundtrip,
# cnpg-pitr, pgdump-restore). Sourced AFTER talos/test/lib.sh (plan 15-01),
# which provides talos_ci_up, talos_ci_down, tal_report and tal_finding. Never `set -x`.
#
# Contract assumed from plan 15-01:
#   talos_ci_up <name> [--two-node]   leaves kubectl context admin@<name> and KUBECONFIG usable
#   talos_ci_down <name>
#   tal_report KEY=VALUE              appends to the job report
#
# The throwaway S3 server runs as a container on the runner, OUTSIDE the cluster. The guest
# reaches the runner's loopback through QEMU user networking at 10.0.2.2.
# shellcheck disable=SC2034

BK_REPO_ROOT="${BK_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BK_PORT="${BK_PORT:-19000}"
BK_S3_GUEST="http://10.0.2.2:${BK_PORT}"
BK_S3_HOST="http://127.0.0.1:${BK_PORT}"
BK_BUCKETS="velero-backups litestream immich-pg"

# shellcheck source=/dev/null
source "$BK_REPO_ROOT/talos/dr/images.env"

bk_log() { echo "[bk] $*"; }

# image_ref REPO TAG DIGEST: prefers the digest, warns when only a tag is pinned.
bk_image_ref() {
  local repo="$1" tag="$2" digest="${3:-}"
  if [[ -n "$digest" ]]; then
    echo "${repo}@${digest}"
  else
    echo "::warning::image ${repo}:${tag} has no pinned digest (run talos/dr/pin-images.sh)" >&2
    echo "${repo}:${tag}"
  fi
}

bk_random() { head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "${1:-24}"; }

# --- throwaway MinIO ---------------------------------------------------------------
bk_minio_start() {
  BK_ACCESS="bk$(bk_random 10)"
  BK_SECRET="$(bk_random 30)"
  echo "::add-mask::${BK_ACCESS}"
  echo "::add-mask::${BK_SECRET}"
  export BK_ACCESS BK_SECRET
  BK_MINIO_NAME="bk-minio-$$"
  local img mc
  img="$(bk_image_ref "$CI_MINIO_IMAGE_REPO" "$CI_MINIO_IMAGE_TAG" "$CI_MINIO_IMAGE_DIGEST")"
  mc="$(bk_image_ref "$CI_MC_IMAGE_REPO" "$CI_MC_IMAGE_TAG" "$CI_MC_IMAGE_DIGEST")"
  BK_MC_IMAGE="$mc"
  docker run -d --name "$BK_MINIO_NAME" -p "127.0.0.1:${BK_PORT}:9000" \
    -e "MINIO_ROOT_USER=$BK_ACCESS" -e "MINIO_ROOT_PASSWORD=$BK_SECRET" \
    "$img" server /data >/dev/null
  local i
  for i in $(seq 1 60); do
    if curl -fsS "${BK_S3_HOST}/minio/health/ready" >/dev/null 2>&1; then
      break
    fi
    sleep 1
    [[ "$i" -lt 60 ]] || {
      echo "::error::throwaway MinIO did not become ready"
      return 1
    }
  done
  local b
  for b in $BK_BUCKETS; do
    bk_mc mb --ignore-existing "ci/$b" >/dev/null
  done
  bk_log "throwaway MinIO ready with buckets: $BK_BUCKETS"
}

# bk_mc ARGS...: runs mc against the throwaway server (alias `ci`).
bk_mc() {
  docker run --rm --network host \
    -e "MC_HOST_ci=http://${BK_ACCESS}:${BK_SECRET}@127.0.0.1:${BK_PORT}" \
    "$BK_MC_IMAGE" "$@"
}

# bk_bucket_bytes BUCKET: total bytes stored in the bucket.
bk_bucket_bytes() {
  bk_mc du --json "ci/$1" 2>/dev/null | jq -r '.size // 0' | tail -n1
}

bk_minio_stop() {
  [[ -z "${BK_MINIO_NAME:-}" ]] || docker rm -f "$BK_MINIO_NAME" >/dev/null 2>&1 || true
}

# --- cluster pieces ------------------------------------------------------------------
# bk_ns NAME [privileged]: create a namespace; Talos enforces Pod Security `baseline` by default.
bk_ns() {
  kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  if [[ "${2:-}" == privileged ]]; then
    kubectl label namespace "$1" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null
  fi
}

# bk_storage: make sure the cluster has a default StorageClass. Plan 15-03 provides one; this is
# the CI fallback (rancher local-path with the Talos-writable path /var/local-path-provisioner).
bk_storage() {
  if kubectl get storageclass -o json | jq -e '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true")' >/dev/null 2>&1; then
    bk_log "default StorageClass already present"
    return 0
  fi
  bk_log "installing local-path-provisioner (CI fallback)"
  bk_ns local-path-storage privileged
  kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml" >/dev/null
  kubectl -n local-path-storage get configmap local-path-config -o json |
    jq '.data["config.json"] |= (fromjson | .nodePathMap[0].paths = ["/var/local-path-provisioner"] | tojson)' |
    kubectl apply -f - >/dev/null
  kubectl -n local-path-storage rollout restart deploy/local-path-provisioner >/dev/null
  kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=180s >/dev/null
  kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true --overwrite >/dev/null
}

# --- tools -----------------------------------------------------------------------------
# bk_install_velero_cli: the CLI must match the server (chart 12.1.0 ships Velero 1.18.1).
# The tarball is checked against VELERO_CLI_SHA256 when set; the job always prints the hash it
# computed so the pin can be copied into talos/dr/images.env.
VELERO_CLI_VERSION="${VELERO_CLI_VERSION:-v1.18.1}"
VELERO_CLI_SHA256="${VELERO_CLI_SHA256:-}"
bk_install_velero_cli() {
  command -v velero >/dev/null 2>&1 && return 0
  local dir="${TAL_WORK:-${RUNNER_TEMP:-/tmp}}/velero-cli" url sum
  mkdir -p "$dir"
  url="https://github.com/vmware-tanzu/velero/releases/download/${VELERO_CLI_VERSION}/velero-${VELERO_CLI_VERSION}-linux-amd64.tar.gz"
  curl -fsSL --retry 5 -o "$dir/velero.tgz" "$url"
  sum="$(sha256sum "$dir/velero.tgz" | cut -d' ' -f1)"
  echo "TOOL velero ${VELERO_CLI_VERSION} sha256=${sum}"
  if [[ -n "$VELERO_CLI_SHA256" && "$sum" != "$VELERO_CLI_SHA256" ]]; then
    echo "::error::velero CLI checksum mismatch"
    return 1
  fi
  [[ -n "$VELERO_CLI_SHA256" ]] || echo "::warning::velero CLI is not pinned (set VELERO_CLI_SHA256 to the value printed above)"
  tar -xzf "$dir/velero.tgz" -C "$dir" --strip-components=1 "velero-${VELERO_CLI_VERSION}-linux-amd64/velero"
  mkdir -p "${TAL_WORK:-${RUNNER_TEMP:-/tmp}}/bin"
  install -m 0755 "$dir/velero" "${TAL_WORK:-${RUNNER_TEMP:-/tmp}}/bin/velero"
  export PATH="${TAL_WORK:-${RUNNER_TEMP:-/tmp}}/bin:$PATH"
}

# bk_helm_install_velero: the repo values plus the Talos override, with only the S3 URL
# pointed at the throwaway MinIO. Credentials are a throwaway Secret (never a repo secret).
bk_helm_install_velero() {
  bk_ns velero privileged
  local creds
  creds="[default]
aws_access_key_id=${BK_ACCESS}
aws_secret_access_key=${BK_SECRET}"
  kubectl -n velero create secret generic cloud-credentials --from-literal=cloud="$creds" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update vmware-tanzu >/dev/null
  helm upgrade --install velero vmware-tanzu/velero --version 12.1.0 -n velero \
    -f "$BK_REPO_ROOT/argocd/values/velero.yaml" \
    -f "$BK_REPO_ROOT/talos/values/velero.yaml" \
    --set "configuration.backupStorageLocation[0].config.s3Url=${BK_S3_GUEST}" \
    --wait --timeout 8m >/dev/null
  kubectl -n velero rollout status deploy/velero --timeout=300s >/dev/null
  kubectl -n velero rollout status ds/node-agent --timeout=300s >/dev/null
}

# bk_wait_backup_location: Velero marks the location Available when it can reach the bucket.
bk_wait_backup_location() {
  local i phase
  for i in $(seq 1 60); do
    phase="$(kubectl -n velero get backupstoragelocation default -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Available" ]] && return 0
    sleep 5
  done
  echo "::error::backup storage location not Available (phase ${phase:-unknown})"
  return 1
}

# --- synthetic workloads shaped like the real ones -----------------------------------------
# bk_make_workload NAME PVC SIZE ANNOTATE_VOLUME SCRIPT: a Pod that runs SCRIPT once to fill the volume
# mounted at /data, then sleeps. The Pod carries the Velero opt-in annotation like the real ones.
bk_make_workload() {
  local name="$1" pvc="$2" size="$3" script="$4" drill_image
  drill_image="$(bk_image_ref "$DRILL_IMAGE_REPO" "$DRILL_IMAGE_TAG" "$DRILL_IMAGE_DIGEST")"
  kubectl -n homeserver apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: $pvc }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: $size } }
---
apiVersion: v1
kind: Pod
metadata:
  name: $name
  annotations: { backup.velero.io/backup-volumes: data }
spec:
  containers:
    - name: main
      image: $drill_image
      command: ["sh", "-c"]
      args:
        - |
          set -e
          $script
          touch /data/.ready
          sleep 36000
      volumeMounts: [{ name: data, mountPath: /data }]
  volumes:
    - name: data
      persistentVolumeClaim: { claimName: $pvc }
EOF
}

bk_wait_ready_file() {
  local pod="$1" i
  for i in $(seq 1 120); do
    kubectl -n homeserver exec "$pod" -- test -f /data/.ready >/dev/null 2>&1 && return 0
    sleep 5
  done
  echo "::error::workload $pod did not finish writing its data"
  return 1
}

# bk_sha_listing NS PVC: sha256 of the sorted per-file sha256 listing of a volume, via a
# throwaway read-only checker pod (the .ready marker is excluded).
bk_sha_listing() {
  local ns="$1" pvc="$2" pod="shacheck-$RANDOM" drill_image out
  drill_image="$(bk_image_ref "$DRILL_IMAGE_REPO" "$DRILL_IMAGE_TAG" "$DRILL_IMAGE_DIGEST")"
  kubectl -n "$ns" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: { name: $pod }
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: $drill_image
      command: ["sh", "-c", "cd /v && find . -type f ! -name .ready -exec sha256sum {} + | sort -k2 | sha256sum | cut -d' ' -f1"]
      volumeMounts: [{ name: v, mountPath: /v, readOnly: true }]
  volumes:
    - name: v
      persistentVolumeClaim: { claimName: $pvc, readOnly: true }
EOF
  kubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" --timeout=300s >/dev/null
  out="$(kubectl -n "$ns" logs "$pod" | tail -n1)"
  kubectl -n "$ns" delete pod "$pod" --wait=false >/dev/null 2>&1 || true
  echo "$out"
}

# --- CloudNativePG ---------------------------------------------------------------------------
# bk_cnpg_install: the operator at the version the live cluster runs (1.25.0, plan 01-09),
# applied server-side like the sync option on the Argo app. The release manifest is not
# hash-checked here (a remote base cannot be); see talos/manifests/cnpg-operator/kustomization.yaml.
CNPG_VERSION="${CNPG_VERSION:-1.25.0}"
bk_cnpg_install() {
  kubectl apply --server-side -f \
    "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v${CNPG_VERSION}/cnpg-${CNPG_VERSION}.yaml" >/dev/null
  kubectl -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=300s >/dev/null
}

# bk_immich_secrets: throwaway credentials the Cluster and its backup config reference.
bk_immich_secrets() {
  kubectl -n homeserver create secret generic immich-db-creds \
    --type=kubernetes.io/basic-auth --from-literal=username=immich --from-literal=password="$(bk_random 24)" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n homeserver create secret generic immich-pg-s3 \
    --from-literal=ACCESS_KEY_ID="$BK_ACCESS" --from-literal=ACCESS_SECRET_KEY="$BK_SECRET" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# bk_immich_cluster_yaml NAME [--no-backup]: the REAL immich-pg Cluster as rendered by the Talos
# overlay (talos/manifests/immich-infra), renamed, with only what a CI VM cannot satisfy changed:
# the S3 endpoint, the priority class, the default storage class, and smaller resources.
bk_immich_cluster_yaml() {
  local name="$1" nobackup="${2:-}"
  local f="$BK_REPO_ROOT/talos/manifests/immich-infra/immich-infra.yaml"
  yq "select(.kind == \"Cluster\")
    | .metadata.name = \"$name\"
    | del(.spec.priorityClassName)
    | del(.spec.storage.storageClass)
    | .spec.resources = {\"requests\": {\"cpu\": \"100m\", \"memory\": \"512Mi\"}, \"limits\": {\"memory\": \"1536Mi\"}}
    | .spec.backup.barmanObjectStore.endpointURL = \"${BK_S3_GUEST}\"
    $([[ "$nobackup" == --no-backup ]] && echo '| del(.spec.backup)')" "$f"
}

# bk_wait_cluster NAME: until the CNPG cluster reports a ready primary.
bk_wait_cluster() {
  local name="$1" i
  for i in $(seq 1 90); do
    [[ "$(kubectl -n homeserver get cluster "$name" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Cluster in healthy state" ]] && return 0
    sleep 5
  done
  echo "::error::cluster $name not healthy"
  kubectl -n homeserver get cluster "$name" -o yaml | yq '.status' || true
  return 1
}

# bk_psql CLUSTER SQL: run SQL as the postgres superuser on the primary, unaligned and tuples only.
bk_psql() {
  local cluster="$1" sql="$2" pod
  pod="$(kubectl -n homeserver get pod -l "cnpg.io/cluster=${cluster},cnpg.io/instanceRole=primary" -o jsonpath='{.items[0].metadata.name}')"
  kubectl -n homeserver exec "$pod" -c postgres -- psql -At -d immich -c "$sql"
}

bk_cleanup_all() {
  bk_minio_stop
}
