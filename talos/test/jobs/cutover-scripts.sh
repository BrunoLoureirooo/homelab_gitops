#!/usr/bin/env bash
# talos-job: kvm=no timeout=10
# The read-only pre-flight and G2 aggregator against a fake kubectl with canned
# JSON (no cluster, no hardware): every check that reads the cluster or the
# CUTOVER.md record must print PASS for the good fixture and FAIL or BRUNO for the
# broken one, and the scripts must never call a write verb (the fake refuses
# them with exit 99).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"

w="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$w"' EXIT
export FAKE_KUBE_DIR="$w/kube" PATH="$here/../fixtures/fakebin-kube:$PATH"
mkdir -p "$FAKE_KUBE_DIR"
chmod +x "$here/../fixtures/fakebin-kube/kubectl"

# The suffix is assembled so no literal tailnet-shaped name is committed.
dom="vaultwarden.example-net.$(printf 'ts%s' '.net')"
iso_ago() { python3 -c "import datetime,sys;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }
today="$(date +%F)"

write_kube() { # write_kube <ingress hostname> <backup age minutes> <qsv rc> <hourly: two|one>
  echo True >"$FAKE_KUBE_DIR/node-ready"
  cat >"$FAKE_KUBE_DIR/deploy.json" <<EOF
{"items":[{"metadata":{"name":"vaultwarden"},"spec":{"template":{"spec":{"containers":[{"env":[{"name":"DOMAIN","value":"https://$dom"}]}]}}}}]}
EOF
  cat >"$FAKE_KUBE_DIR/ingress.json" <<EOF
{"items":[{"metadata":{"name":"vaultwarden"},"status":{"loadBalancer":{"ingress":[{"hostname":"$1"}]}}}]}
EOF
  cat >"$FAKE_KUBE_DIR/pods.json" <<'EOF'
{"items":[
 {"metadata":{"name":"immich-server-0"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}
EOF
  # The bot is in its own namespace (cp-reserva-bot), not in homeserver.
  cat >"$FAKE_KUBE_DIR/pods-bot.json" <<'EOF'
{"items":[
 {"metadata":{"name":"cp-reserva-bot-0"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}
EOF
  echo '{"items":[]}' >"$FAKE_KUBE_DIR/pvc.json"
  cat >"$FAKE_KUBE_DIR/pvc-bot.json" <<'EOF'
{"items":[{"metadata":{"name":"cp-reserva-bot-data"},"status":{"phase":"Bound"}}]}
EOF
  echo pod/immich-pg-1 >"$FAKE_KUBE_DIR/primary"
  echo 1234 >"$FAKE_KUBE_DIR/asset-count"
  echo /config/log/FFmpeg.Transcode-1.log >"$FAKE_KUBE_DIR/jellyfin-log"
  echo "$3" >"$FAKE_KUBE_DIR/qsv-rc"
  printf '{"items":[{"status":{"phase":"Completed","completionTimestamp":"%s"}}]}\n' "$(iso_ago "$2")" >"$FAKE_KUBE_DIR/backups.json"
  if [[ "$4" == two ]]; then
    printf '{"items":[{"status":{"phase":"Completed","completionTimestamp":"%s"}},{"status":{"phase":"Completed","completionTimestamp":"%s"}}]}\n' "$(iso_ago 5)" "$(iso_ago 66)" >"$FAKE_KUBE_DIR/backups-hourly.json"
  else
    printf '{"items":[{"status":{"phase":"Completed","completionTimestamp":"%s"}}]}\n' "$(iso_ago 5)" >"$FAKE_KUBE_DIR/backups-hourly.json"
  fi
}

write_record() { # write_record <drill date> <match date> <disk line value>
  cat >"$w/CUTOVER.md" <<EOF
LIVE-DISK-CONFIRMED: $3
DISK-256-CONTENT: backups and a spare filesystem
BACKUP-DISK: the 256
COPY-256-PRECOPY: PASS
COPY-256-DIR: /srv/copy256
RESTORE-DRILL: PASS $1
SEALING-KEY-MATCH: $2
PRE-CUTOVER-ASSET-COUNT: 1234
UPGRADE-REHEARSAL: PASS
SECURE-BOOT: off
EOF
}
printf 'G1 DECISION: go\n' >"$w/FINDINGS-go.md"
printf 'G1 DECISION: no-go\n' >"$w/FINDINGS-nogo.md"

fails=0
line_is() { # line_is <name> <output> <prefix> <wanted word>
  local got
  got="$(grep -m1 "^$3 " <<<"$2" | awk '{print $3}')"
  if [[ "$got" == "$4" ]]; then tal_finding "$1" PASS "$3 $got"; else
    tal_finding "$1" FAIL "$3 wanted $4 got ${got:-none}"
    fails=$((fails + 1))
  fi
}
pre() { CUTOVER_FILE="$w/CUTOVER.md" FINDINGS_FILE="$1" bash "$TAL_ROOT/scripts/cutover-preflight.sh" 2>&1 || true; }
g2() { CUTOVER_FILE="$w/CUTOVER.md" bash "$TAL_ROOT/scripts/g2-check.sh" 2>&1 || true; }

# ---- the good fixture -------------------------------------------------------
write_kube "$dom" 120 0 two
write_record 2099-01-01 "$today" "a 512 GB NVMe"
out="$(pre "$w/FINDINGS-go.md")"
line_is pf2-pass "$out" PF-2 PASS
line_is pf3-pass "$out" PF-3 PASS
line_is pf5-pass "$out" PF-5 PASS
line_is pf7-pass "$out" PF-7 PASS
line_is pf8-pass "$out" PF-8 PASS
line_is pf10-pass "$out" PF-10 PASS
out="$(g2)"
line_is g2-1-pass "$out" G2-1 PASS
line_is g2-2-pass "$out" G2-2 PASS
line_is g2-3-pass "$out" G2-3 PASS
line_is g2-4-brunos "$out" G2-4 BRUNO
line_is g2-5-pass "$out" G2-5 PASS
line_is g2-6-brunos "$out" G2-6 BRUNO
line_is g2-7-pass "$out" G2-7 PASS
line_is g2-8-pass "$out" G2-8 PASS

# ---- the broken fixtures ----------------------------------------------------
write_kube "vaultwarden-1.example-net.$(printf 'ts%s' '.net')" 3000 1 one
write_record 2000-01-01 2000-01-01 "<model and size>"
out="$(pre "$w/FINDINGS-nogo.md")"
line_is pf2-stale-drill "$out" PF-2 FAIL
line_is pf3-old-match "$out" PF-3 BRUNO
line_is pf5-old-backup "$out" PF-5 FAIL
line_is pf7-placeholder "$out" PF-7 FAIL
line_is pf8-nogo "$out" PF-8 FAIL
out="$(g2)"
line_is g2-2-mismatch "$out" G2-2 FAIL
line_is g2-5-software "$out" G2-5 FAIL
line_is g2-7-one-backup "$out" G2-7 FAIL

((fails == 0)) || tal_die "$fails cutover script checks were wrong"
tal_report "CUTOVER_SCRIPTS=pass"
