#!/usr/bin/env bash
# Offline self-test of the talos/dr scripts (plan 15-06). No cluster, no network:
# a stub `kubectl` and `velero` on PATH answer the few calls the guards make.
# Run by .github/scripts/check-backups-06.sh (so `guards` runs it on every PR).
#
#   bash talos/test/offline/test-dr-scripts.sh
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
dr="$repo/talos/dr"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

pass=0
fail=0
ok() {
  echo "OK   $1"
  pass=$((pass + 1))
}
bad() {
  echo "FAIL $1"
  fail=$((fail + 1))
}
expect_exit() { # name want-code -- command...
  local name="$1" want="$2"
  shift 3
  "$@" >"$work/out" 2>&1
  local got=$?
  if [[ "$got" == "$want" ]]; then ok "$name"; else
    bad "$name (exit $got, wanted $want)"
    sed 's/^/     /' "$work/out" | head -5
  fi
}

# expect_out NAME WANT_OUTPUT WANT_EXIT -- command...: exact output and exit code.
expect_out() {
  local name="$1" want="$2" wantrc="$3" got rc
  shift 3
  got="$("$@" 2>&1)"
  rc=$?
  if [[ "$got" == "$want" && "$rc" == "$wantrc" ]]; then
    ok "$name"
  else
    bad "$name (got '$got' exit $rc)"
  fi
}

# --- stubs -------------------------------------------------------------------
cat >"$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
# Stub: answers only what the guards ask.
args="$*"
case "$args" in
  "config current-context") echo "${STUB_CONTEXT:-admin@other}" ;;
  *"get namespace"*) [[ "${STUB_NS_EXISTS:-no}" == yes ]] && exit 0 || exit 1 ;;
  *"get cronjob"*) printf '%s' "${STUB_LAST:-}" ;;
  *"get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o name"*) [[ "${STUB_KEYS:-0}" -gt 0 ]] && seq "$STUB_KEYS" | sed 's/^/secret\/k/' ;;
  *"jsonpath={range .items[*]}{.data.tls"*) printf '%s\n' ${STUB_CRTS:-} ;;
  *) exit 0 ;;
esac
EOF
cat >"$work/bin/velero" <<'EOF'
#!/usr/bin/env bash
echo "${STUB_BACKUP_PHASE:-Completed}"
EOF
chmod +x "$work/bin/kubectl" "$work/bin/velero"
export PATH="$work/bin:$PATH"

# --- context guards ------------------------------------------------------------
STUB_CONTEXT="admin@other" expect_exit "drill refuses outside the CI context" 3 -- bash "$dr/velero-restore-drill.sh" --backup x --ci
STUB_CONTEXT="admin@other" expect_exit "drill refuses --live with a wrong typed context" 3 -- bash "$dr/velero-restore-drill.sh" --backup x --live "admin@wrong"
STUB_CONTEXT="admin@talos-ci" STUB_NS_EXISTS=yes expect_exit "drill refuses when the scratch namespace exists" 4 -- bash "$dr/velero-restore-drill.sh" --backup x --ci
STUB_CONTEXT="admin@talos-ci" STUB_BACKUP_PHASE=PartiallyFailed expect_exit "drill refuses a backup that is not Completed" 5 -- bash "$dr/velero-restore-drill.sh" --backup x --ci
STUB_CONTEXT="admin@talos-ci" expect_exit "drill refuses source == target namespace" 3 -- bash "$dr/velero-restore-drill.sh" --backup x --ci --source-ns a --target-ns a
echo "key" >"$work/key.yaml"
STUB_CONTEXT="admin@other" expect_exit "restore-sealing-key refuses outside the CI context" 3 -- bash "$dr/restore-sealing-key.sh" "$work/key.yaml" --ci
STUB_CONTEXT="admin@talos-ci" STUB_KEYS=1 expect_exit "restore-sealing-key refuses when a key already exists" 4 -- bash "$dr/restore-sealing-key.sh" "$work/key.yaml" --ci
expect_exit "immich-dump refuses without --context" 3 -- bash "$dr/immich-dump.sh" --out "$work/d.dump"
: >"$work/exists.dump"
expect_exit "immich-dump refuses to overwrite" 4 -- bash "$dr/immich-dump.sh" --context c --out "$work/exists.dump"
expect_exit "immich-restore refuses without --context" 3 -- bash "$dr/immich-restore.sh" --dump "$work/exists.dump"

# --- verify-sealing-key -------------------------------------------------------------
crt_a="$(printf 'cert-a' | base64)"
crt_b="$(printf 'cert-b' | base64)"
printf 'items:\n- data:\n    tls.crt: %s\n- data:\n    tls.crt: %s\n' "$crt_a" "$crt_b" >"$work/offline.yaml"
expect_out "verify-sealing-key: same keys print MATCH" "MATCH" 0 env STUB_CRTS="$crt_a $crt_b" bash "$dr/verify-sealing-key.sh" "$work/offline.yaml"
crt_c="$(printf 'cert-c' | base64)"
expect_out "verify-sealing-key: an extra live key prints DIFFERENT" "DIFFERENT" 1 env STUB_CRTS="$crt_a $crt_c" bash "$dr/verify-sealing-key.sh" "$work/offline.yaml"

echo "---- $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
