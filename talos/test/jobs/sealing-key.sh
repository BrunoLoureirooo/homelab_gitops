#!/usr/bin/env bash
# talos-job: kvm=yes timeout=45
# Plan 15-06 Task 2: the Sealed Secrets key must be restored into an EMPTY cluster BEFORE the
# controller starts. Proof on Talos: (1) restore the key, install the controller, a
# SealedSecret sealed offline beforehand decrypts and the controller does not create a second
# key; (2) control: a second empty cluster WITHOUT the restore generates a different key and
# the same SealedSecret does NOT decrypt. This is the reason the cutover order exists.
#
# Report lines: SEALING restore PASS|FAIL, SEALING order-control PASS|FAIL
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
# shellcheck source=/dev/null
source "$repo/talos/test/lib.sh"

KUBESEAL_VERSION="${KUBESEAL_VERSION:-v0.32.2}"
KUBESEAL_SHA256="${KUBESEAL_SHA256:-}"
CHART_VERSION="2.18.6" # same as argocd/apps/sealed-secrets.yaml

work="$(mktemp -d)"
trap 'rm -rf "$work"; talos_ci_down talos-ci >/dev/null 2>&1 || true' EXIT
mkdir -p "$work/bin"
export PATH="$work/bin:$PATH"

# ---- tools: kubeseal (checksum printed so it can be pinned) -------------------------------------
tgz="$work/kubeseal.tgz"
curl -fsSL --retry 5 -o "$tgz" "https://github.com/bitnami-labs/sealed-secrets/releases/download/${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION#v}-linux-amd64.tar.gz"
sum="$(sha256sum "$tgz" | cut -d' ' -f1)"
echo "TOOL kubeseal ${KUBESEAL_VERSION} sha256=${sum}"
if [[ -n "$KUBESEAL_SHA256" && "$sum" != "$KUBESEAL_SHA256" ]]; then
  echo "::error::kubeseal checksum mismatch"
  exit 1
fi
[[ -n "$KUBESEAL_SHA256" ]] || echo "::warning::kubeseal is not pinned (set KUBESEAL_SHA256 to the value printed above)"
tar -xzf "$tgz" -C "$work/bin" kubeseal

# ---- throwaway key pair, and a SealedSecret sealed offline before any cluster exists ---------------
openssl req -x509 -newkey rsa:4096 -nodes -days 30 -subj "/CN=sealed-secret/O=sealed-secret" \
  -keyout "$work/tls.key" -out "$work/tls.crt" >/dev/null 2>&1
probe_value="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
echo "::add-mask::${probe_value}"
kubectl create secret generic ci-probe -n default --from-literal=value="$probe_value" --dry-run=client -o json |
  KUBECONFIG=/dev/null kubeseal --cert "$work/tls.crt" --format yaml >"$work/sealed.yaml"
kubectl create secret tls sealed-secrets-key-ci --cert="$work/tls.crt" --key="$work/tls.key" --dry-run=client -o yaml |
  kubectl label --local -f - sealedsecrets.bitnami.com/sealed-secrets-key=active -o yaml >"$work/keyfile.yaml"
want_crt_sha="$(sha256sum "$work/tls.crt" | cut -d' ' -f1)"

install_controller() {
  local i
  for i in 1 2 3 4; do
    helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets --force-update && break
    [[ $i == 4 ]] && tal_die "helm repo add sealed-secrets failed 4 times (the error is printed above)"
    sleep 5
  done
  helm repo update sealed-secrets >/dev/null
  helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets --version "$CHART_VERSION" \
    -n kube-system --set keyrenewperiod=0 --wait --timeout 6m >/dev/null
}

active_keys() {
  kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o name | wc -l | tr -d ' '
}

# ---- run 1: restore first, then the controller --------------------------------------------------
talos_ci_up talos-ci
bash "$repo/talos/dr/restore-sealing-key.sh" "$work/keyfile.yaml" --ci
install_controller
kubectl apply -f "$work/sealed.yaml" >/dev/null

got=""
for _ in $(seq 1 60); do
  got="$(kubectl -n default get secret ci-probe -o jsonpath='{.data.value}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [[ -n "$got" ]] && break
  sleep 3
done
keys="$(active_keys)"
if [[ "$got" == "$probe_value" && "$keys" == "1" ]]; then
  tal_report "SEALING restore PASS"
else
  tal_report "SEALING restore FAIL keys=${keys}"
  kubectl -n kube-system logs deploy/sealed-secrets --tail=40 || true
  exit 1
fi
talos_ci_down talos-ci

# ---- run 2 (control): no restore, controller generates its own key ------------------------------------
talos_ci_up talos-ci
install_controller
kubectl apply -f "$work/sealed.yaml" >/dev/null
sleep 45
secret_present="no"
kubectl -n default get secret ci-probe >/dev/null 2>&1 && secret_present="yes"
synced="$(kubectl -n default get sealedsecret ci-probe -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}' 2>/dev/null || true)"
own_crt_sha="$(kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d | sha256sum | cut -d' ' -f1)"
if [[ "$secret_present" == "no" && "$synced" != "True" && "$own_crt_sha" != "$want_crt_sha" ]]; then
  tal_report "SEALING order-control PASS"
else
  tal_report "SEALING order-control FAIL secret=${secret_present} synced=${synced:-none}"
  exit 1
fi
tal_finding SEALING-ORDER PASS "restore-before-controller decrypts; without it the object does not"
