#!/usr/bin/env bash
# Shared helpers for the plan 15-05 NAS jobs (nas-pod.sh, csi-smb.sh). Sourced,
# never executed. Needs the 15-01 harness (lib.sh) to be sourced first and
# kubectl to point at the CI cluster ($TAL_WORK/kubeconfig).

# shellcheck shell=bash

nas_dir() { cd "$(dirname "${BASH_SOURCE[0]}")/../manifests" && pwd; }

# nas_up: deploy the Samba pod (CI overlay, plain directory, no hostPort) with a
# throwaway credential generated now. Exports NAS_USER and NAS_PASS.
nas_up() {
  local kc=(kubectl --kubeconfig "${TAL_WORK:?}/kubeconfig") m
  m="$(nas_dir)"
  NAS_USER=homelab
  NAS_PASS="$(openssl rand -hex 12)"
  echo "::add-mask::$NAS_PASS"
  export NAS_USER NAS_PASS
  "${kc[@]}" apply -f "$m/samba-nas/namespace.yaml" >/dev/null
  "${kc[@]}" -n nas create secret generic samba-nas-credentials \
    --from-literal=credential="$NAS_PASS" >/dev/null
  "${kc[@]}" apply -k "$m/samba-nas-ci" >/dev/null
  "${kc[@]}" -n nas rollout status deploy/samba-nas --timeout=300s >/dev/null
}

# nas_client <pod-name> <smbclient -c command>: run smbclient in a throwaway pod
# against the share `media`. The credential reaches the pod through a Secret
# reference, never through the command line.
nas_client() {
  local kc=(kubectl --kubeconfig "${TAL_WORK:?}/kubeconfig") json
  json="$(jq -nc --arg c "$2" '{spec:{containers:[{name:"c",image:"docker.io/library/alpine:3.21",
    env:[{name:"PW",valueFrom:{secretKeyRef:{name:"samba-nas-credentials",key:"credential"}}}],
    command:["sh","-c",("apk add --no-cache samba-client >/dev/null 2>&1 && smbclient //samba-nas.nas.svc.cluster.local/media -U \"homelab%$PW\" -c \"" + $c + "\"")]}]}}')"
  "${kc[@]}" -n nas delete pod "$1" --now --ignore-not-found >/dev/null 2>&1
  "${kc[@]}" -n nas run "$1" --restart=Never --image=docker.io/library/alpine:3.21 --overrides="$json" >/dev/null
  "${kc[@]}" -n nas wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$1" --timeout=240s >/dev/null 2>&1 || true
  "${kc[@]}" -n nas logs "$1" 2>/dev/null || true
  "${kc[@]}" -n nas delete pod "$1" --now >/dev/null 2>&1 || true
}
