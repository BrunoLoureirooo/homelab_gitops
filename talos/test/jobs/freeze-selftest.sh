#!/usr/bin/env bash
# talos-job: kvm=no timeout=10
# freeze.sh against a recording fake kubectl: the scale order, the saved replica
# counts, the refusal to overwrite a recorded freeze, the exact restore on
# unfreeze (reverse order), the timeout path, and the refusals without --context.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"

w="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$w"' EXIT
export FAKE_KUBE_DIR="$w/kube" FAKE_LOG="$w/scale.log" PATH="$here/../fixtures/fakebin-freeze:$PATH"
chmod +x "$here/../fixtures/fakebin-freeze/kubectl"
mkdir -p "$FAKE_KUBE_DIR"
script="$TAL_ROOT/scripts/freeze.sh"

cat >"$FAKE_KUBE_DIR/argocd.json" <<'EOF'
{"kind":"StatefulSet","metadata":{"namespace":"argocd","name":"argocd-application-controller"},"spec":{"replicas":1}}
EOF
cat >"$FAKE_KUBE_DIR/homeserver.json" <<'EOF'
{"items":[
 {"kind":"Deployment","metadata":{"namespace":"homeserver","name":"vaultwarden"},"spec":{"replicas":1}},
 {"kind":"Deployment","metadata":{"namespace":"homeserver","name":"immich-server"},"spec":{"replicas":2}},
 {"kind":"Deployment","metadata":{"namespace":"homeserver","name":"idle-thing"},"spec":{"replicas":0}}]}
EOF
# The bot lives in its own namespace on the live cluster.
cat >"$FAKE_KUBE_DIR/cp-bot.json" <<'EOF'
{"items":[
 {"kind":"StatefulSet","metadata":{"namespace":"cp-reserva-bot","name":"cp-reserva-bot"},"spec":{"replicas":1}}]}
EOF
cat >"$FAKE_KUBE_DIR/all-deploy.json" <<'EOF'
{"items":[
 {"kind":"Deployment","metadata":{"namespace":"homeserver","name":"vaultwarden"},"spec":{"replicas":1}},
 {"kind":"Deployment","metadata":{"namespace":"storage","name":"minio"},"spec":{"replicas":1}}]}
EOF
echo '{"items":[]}' >"$FAKE_KUBE_DIR/pods.json"

fails=0
expect() { # expect <name> <rc wanted> <output pattern> -- <command...>
  local name="$1" want="$2" pat="$3" rc=0 out
  shift 4
  out="$("$@" 2>&1)" || rc=$?
  if [[ "$rc" == "$want" && "$out" == *$pat* ]]; then
    tal_finding "$name" PASS "rc=$rc"
  else
    tal_finding "$name" FAIL "rc=$rc want=$want"
    echo "$out" | head -5
    fails=$((fails + 1))
  fi
}
eq() { # eq <name> <got> <want>
  if [[ "$2" == "$3" ]]; then tal_finding "$1" PASS "ok"; else
    tal_finding "$1" FAIL "got [$2] want [$3]"
    fails=$((fails + 1))
  fi
}

state="$w/state.tsv"
expect refuse-without-context 2 "--context is required" -- bash "$script" freeze
expect refuse-unfreeze-no-state 2 "no state file" -- bash "$script" unfreeze --context c --state "$w/none.tsv" --yes

: >"$FAKE_LOG"
expect freeze-done 0 "FREEZE DONE targets=6" -- bash "$script" freeze --context c --state "$state" --yes
# Order: argocd controller, the homeserver workloads, the bot's namespace, then the
# other MinIO; the workload that was already at 0 is not scaled.
eq freeze-order "$(awk '{for(i=1;i<=NF;i++) if($i=="scale"){print $(i+1)" "$(i+2)}}' "$FAKE_LOG" | tr '\n' ',')" \
  "statefulset argocd-application-controller,deployment vaultwarden,deployment immich-server,statefulset cp-reserva-bot,deployment minio,"
eq freeze-replicas-zero "$(grep -c -- '--replicas=0' "$FAKE_LOG")" "5"
eq state-lines "$(wc -l <"$state" | tr -d ' ')" "6"
expect freeze-no-overwrite 2 "REFUSED" -- bash "$script" freeze --context c --state "$state" --yes

: >"$FAKE_LOG"
expect unfreeze-done 0 "UNFREEZE DONE targets=6" -- bash "$script" unfreeze --context c --state "$state" --yes
eq unfreeze-order-and-counts "$(awk '{for(i=1;i<=NF;i++) if($i=="scale"){printf "%s %s %s,", $(i+1), $(i+2), $NF}}' "$FAKE_LOG")" \
  "deployment minio --replicas=1,statefulset cp-reserva-bot --replicas=1,deployment immich-server --replicas=2,deployment vaultwarden --replicas=1,statefulset argocd-application-controller --replicas=1,"

# A pod that keeps running makes the wait time out.
cat >"$FAKE_KUBE_DIR/pods.json" <<'EOF'
{"items":[{"metadata":{"name":"minio-0"},"status":{"phase":"Running"}}]}
EOF
rm -f "$state"
FREEZE_WAIT_SECONDS=0 expect freeze-timeout 1 "WAIT-TIMEOUT" -- bash "$script" freeze --context c --state "$state" --yes

((fails == 0)) || tal_die "$fails freeze.sh behaviours were wrong"
tal_report "FREEZE_SELFTEST=pass"
