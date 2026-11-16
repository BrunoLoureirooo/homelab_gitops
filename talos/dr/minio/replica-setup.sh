#!/usr/bin/env bash
# One-time setup of the backup replica's access (talos/manifests/backup-replica/README.md, steps c-e).
#
#   replica-setup.sh --check     look only: tools, cluster, root Secrets, replica pod. Changes nothing.
#   replica-setup.sh             do it
#   replica-setup.sh --rotate    also replace the two users' passwords if they already exist
#
# What it does, in order:
#   1. PRIMARY (MinIO on mini02): policy backup-replica-reader (read-only on the three buckets) and
#      the user replica-reader attached to it.
#   2. REPLICA (MinIO on mini03): the buckets velero-backups, litestream and immich-pg, policy
#      backup-replica-writer and the user replica-writer attached to it.
#   3. Tests the permissions: the reader can list but NOT write on the primary; the writer can write and
#      delete on the replica. Seals nothing if a test fails.
#   4. Seals the Secret velero/backup-replica-mirror (keys MC_HOST_primary and MC_HOST_replica, the in-cluster
#      addresses) into talos/sealed-secrets/ against the LIVE controller's certificate and lists it in the
#      kustomization. You then commit and open a PR.
#
# Secrets: the two root logins are read from the cluster Secrets minio-root and minio-replica-root into
# shell variables; the generated passwords exist only in variables and in the sealed file. Nothing secret is
# printed, written in the clear, or put on a command line that `ps` can show (mc reads MC_HOST_* from the
# environment). Run it from the repository root, with the cluster reachable. It only needs: kubectl, kubeseal,
# mc, curl, base64.
set -euo pipefail

ctx="${KUBE_CONTEXT:-admin@homelab-ts}"
ns=velero
mode=apply
rotate=0
for a in "$@"; do
  case "$a" in
    --check) mode=check ;;
    --rotate) rotate=1 ;;
    *) echo "unknown argument: $a" >&2; exit 1 ;;
  esac
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
sealed_dir="$root/talos/sealed-secrets"
out_file="$sealed_dir/backup-replica-mirror.yaml"
kz="$sealed_dir/kustomization.yaml"

die() { echo "ERROR: $*" >&2; exit 1; }
k() { kubectl --context "$ctx" "$@"; }

for t in kubectl kubeseal mc curl base64; do
  command -v "$t" >/dev/null 2>&1 || die "$t is not installed"
done
[[ -f "$here/policy-replica-reader.json" && -f "$here/policy-replica-writer.json" ]] || die "policy files missing next to this script"
[[ -d "$sealed_dir" ]] || die "run from a checkout of the repository (no $sealed_dir)"

echo "== checks"
k -n "$ns" get secret minio-root >/dev/null 2>&1 || die "Secret $ns/minio-root not found (primary root login)"
k -n "$ns" get secret minio-replica-root >/dev/null 2>&1 || die "Secret $ns/minio-replica-root not found: merge the sealed secret PR first"
ready="$(k -n "$ns" get deploy minio-replica -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
[[ "${ready:-0}" -ge 1 ]] || die "Deployment minio-replica is not ready (run: kubectl -n $ns get pods)"
k -n "$ns" get svc velero-backup-target velero-backup-replica >/dev/null 2>&1 || die "Services velero-backup-target / velero-backup-replica missing"
if [[ -e "$out_file" && "$rotate" -eq 0 ]]; then
  die "$out_file already exists; use --rotate to replace it (and the users' passwords)"
fi
echo "   tools, cluster, root Secrets and the replica pod are in place"
[[ "$mode" == check ]] && { echo "check only: nothing changed"; exit 0; }

# Roots come from the cluster; they stay in variables.
read_secret() { k -n "$ns" get secret "$1" -o "jsonpath={.data.$2}" | base64 -d; }
p_user="$(read_secret minio-root MINIO_ROOT_USER)"
p_pass="$(read_secret minio-root MINIO_ROOT_PASSWORD)"
r_user="$(read_secret minio-replica-root MINIO_ROOT_USER)"
r_pass="$(read_secret minio-replica-root MINIO_ROOT_PASSWORD)"
[[ -n "$p_user" && -n "$p_pass" && -n "$r_user" && -n "$r_pass" ]] || die "a root Secret is missing a key"

pf_pids=()
tmp="$(mktemp -d)"
cleanup() {
  for p in "${pf_pids[@]:-}"; do
    if [[ -n "$p" ]]; then kill "$p" 2>/dev/null || true; fi
  done
  rm -rf "$tmp"
  unset p_pass r_pass reader_pass writer_pass MC_HOST_pri MC_HOST_rep MC_HOST_pritest MC_HOST_reptest 2>/dev/null || true
}
trap cleanup EXIT

echo "== port-forwards (temporary)"
k -n "$ns" port-forward svc/velero-backup-target 19000:9000 >/dev/null 2>&1 &
pf_pids+=("$!")
k -n "$ns" port-forward svc/velero-backup-replica 19001:9000 >/dev/null 2>&1 &
pf_pids+=("$!")
for port in 19000 19001; do
  ok=0
  for _ in $(seq 1 30); do
    curl -fsS "http://localhost:$port/minio/health/live" >/dev/null 2>&1 && { ok=1; break; }
    sleep 1
  done
  [[ "$ok" -eq 1 ]] || die "MinIO on port $port did not answer"
done
echo "   both MinIO servers answer"

export MC_CONFIG_DIR="$tmp/mc"
export MC_HOST_pri="http://${p_user}:${p_pass}@localhost:19000"
export MC_HOST_rep="http://${r_user}:${r_pass}@localhost:19001"

gen() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32; }
user_exists() { mc admin user info "$1" "$2" >/dev/null 2>&1; }

make_user() { # make_user <alias> <user> <policy> <policy-file> -> sets $newpass (empty if kept)
  local al="$1" user="$2" pol="$3" file="$4"
  mc admin policy create "$al" "$pol" "$file" >/dev/null 2>&1 ||
    mc admin policy create "$al" "$pol" "$file" --overwrite >/dev/null 2>&1 || die "cannot create policy $pol"
  newpass=""
  if user_exists "$al" "$user"; then
    if [[ "$rotate" -eq 1 ]]; then
      newpass="$(gen)"
      mc admin user add "$al" "$user" "$newpass" >/dev/null
      echo "   user $user existed: password replaced"
    else
      die "user $user already exists; use --rotate to replace its password (the sealed Secret must match)"
    fi
  else
    newpass="$(gen)"
    mc admin user add "$al" "$user" "$newpass" >/dev/null
    echo "   user $user created"
  fi
  mc admin policy attach "$al" "$pol" --user "$user" >/dev/null 2>&1 || true
}

echo "== primary: read-only user"
make_user pri replica-reader backup-replica-reader "$here/policy-replica-reader.json"
reader_pass="$newpass"

echo "== replica: buckets and writer"
for b in velero-backups litestream immich-pg; do
  mc mb --ignore-existing "rep/$b" >/dev/null
  echo "   bucket $b ready"
done
make_user rep replica-writer backup-replica-writer "$here/policy-replica-writer.json"
writer_pass="$newpass"

echo "== permission tests"
export MC_HOST_pritest="http://replica-reader:${reader_pass}@localhost:19000"
export MC_HOST_reptest="http://replica-writer:${writer_pass}@localhost:19001"
probe="$tmp/probe"
echo probe >"$probe"
fail=0
if mc ls pritest/velero-backups >/dev/null 2>&1; then echo "   PASS reader can list the primary"; else echo "   FAIL reader cannot list the primary"; fail=1; fi
if mc cp "$probe" pritest/velero-backups/.reader-must-not-write >/dev/null 2>&1; then
  echo "   FAIL reader COULD WRITE to the primary"
  mc rm "pri/velero-backups/.reader-must-not-write" >/dev/null 2>&1 || true
  fail=1
else echo "   PASS reader cannot write to the primary"; fi
if mc cp "$probe" reptest/velero-backups/.writer-selftest >/dev/null 2>&1 && mc rm reptest/velero-backups/.writer-selftest >/dev/null 2>&1; then
  echo "   PASS writer can write and delete on the replica"
else echo "   FAIL writer cannot write on the replica"; fail=1; fi
[[ "$fail" -eq 0 ]] || die "a permission test failed; nothing was sealed"

echo "== seal backup-replica-mirror"
cert="$tmp/cert.pem"
kubeseal --context "$ctx" --controller-name sealed-secrets --controller-namespace kube-system --fetch-cert >"$cert" 2>/dev/null ||
  die "could not fetch the sealing certificate from the controller"
grep -q "BEGIN CERTIFICATE" "$cert" || die "no certificate returned"
src_pri="http://replica-reader:${reader_pass}@velero-backup-target.${ns}.svc.cluster.local:9000"
src_rep="http://replica-writer:${writer_pass}@velero-backup-replica.${ns}.svc.cluster.local:9000"
k create secret generic backup-replica-mirror -n "$ns" \
  --from-literal=MC_HOST_primary="$src_pri" --from-literal=MC_HOST_replica="$src_rep" \
  --dry-run=client -o json |
  KUBECONFIG=/dev/null kubeseal --cert "$cert" --format yaml >"$out_file"
unset src_pri src_rep
grep -q "kind: SealedSecret" "$out_file" || die "sealing did not produce a SealedSecret"
if grep -qE "replica-reader|replica-writer|://" "$out_file"; then die "plaintext found in $out_file; deleting it"; fi
if ! grep -q "backup-replica-mirror.yaml" "$kz"; then
  awk '{ print } /^  - minio-replica-root.yaml$/ { print "  - backup-replica-mirror.yaml" }' "$kz" >"$tmp/kustomization.yaml" &&
    cat "$tmp/kustomization.yaml" >"$kz"
fi
grep -q "backup-replica-mirror.yaml" "$kz" || die "could not list the file in $kz; add it by hand"

echo
echo "done. Sealed: talos/sealed-secrets/backup-replica-mirror.yaml (listed in the kustomization)."
echo "Next: commit it, open a PR, merge it; then run the first mirror:"
echo "  kubectl --context $ctx -n $ns create job --from=cronjob/backup-replica-mirror first-mirror"
