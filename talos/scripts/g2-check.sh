#!/usr/bin/env bash
# Read-only gate G2 aggregator for the Talos mini01 (plan 15-07 Task 5). It reads
# the NEW cluster and the drill record in talos/CUTOVER.md; it changes nothing.
#
#   g2-check.sh
#
# Prints `G2-<n> <name> PASS|FAIL|BRUNO [note]` (BRUNO: confirm by hand). Exit 0
# when the cluster was reachable, 2 with `cannot reach a cluster` otherwise.
#
# Env: MINI01 (the node's address for talosctl, not committed) for G2-6.
# Unverified details are marked in the notes: the Jellyfin log location, the
# `talosctl mounts` output format and the Immich table name.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
troot="$(cd "$here/.." && pwd)"
cutover="${CUTOVER_FILE:-$troot/CUTOVER.md}" # the override exists for the offline test
ns=homeserver
bot_ns=cp-reserva-bot # the WhatsApp bot has its own namespace on the live cluster

g2() { printf 'G2-%s %s %s%s\n' "$1" "$2" "$3" "${4:+ $4}"; }
rec() {
  [[ -f "$cutover" ]] || return 0
  grep -m1 "^$1:" "$cutover" | sed -E "s/^$1:[[:space:]]*//" || true
}

if ! kubectl --request-timeout=5s get ns >/dev/null 2>&1; then
  for n in 1:node-ready 2:vaultwarden-domain 3:immich 4:cp-bot-session 5:jellyfin-qsv 6:toshiba 7:hourly-backup; do
    g2 "${n%%:*}" "${n#*:}" BRUNO "no cluster"
  done
  g2 8 upgrade-rehearsal "$([[ "$(rec UPGRADE-REHEARSAL)" == PASS ]] && echo PASS || echo FAIL)"
  g2 9 copy-kept BRUNO "confirm on victus that the COPY-256-DIR directory still exists"
  echo "cannot reach a cluster" >&2
  exit 2
fi

# G2-1: the node is Ready.
ready="$(kubectl get node mini01 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
if [[ "$ready" == True ]]; then g2 1 node-ready PASS; else g2 1 node-ready FAIL "Ready=${ready:-unknown}"; fi

# G2-2: Vaultwarden's DOMAIN equals the name the tailnet ingress got.
dom="$(kubectl -n "$ns" get deploy -o json 2>/dev/null |
  jq -r '[.items[] | select(.metadata.name | test("vaultwarden")) | .spec.template.spec.containers[].env[]? | select(.name == "DOMAIN") | .value][0] // ""' | sed -E 's#^https?://##; s#/.*$##')"
host="$(kubectl -n "$ns" get ingress -o json 2>/dev/null |
  jq -r '[.items[] | select(.metadata.name | test("vaultwarden")) | .status.loadBalancer.ingress[0].hostname][0] // ""')"
if [[ -n "$dom" && "$dom" == "$host" ]]; then
  g2 2 vaultwarden-domain PASS MATCH
else
  g2 2 vaultwarden-domain FAIL "MISMATCH (a duplicate device name such as <name>-1 is the usual cause: delete the stale device and restart the proxy pod)"
fi

# G2-3: Immich pods Ready and the database holds the recorded asset count.
notready="$(kubectl -n "$ns" get pods -o json 2>/dev/null |
  jq -r '[.items[] | select(.metadata.name | test("immich")) | select(.status.phase != "Succeeded") | select(any(.status.conditions[]?; .type == "Ready" and .status != "True"))] | length')"
want="$(rec PRE-CUTOVER-ASSET-COUNT)"
primary="$(kubectl -n "$ns" get pods -l cnpg.io/cluster=immich-pg,cnpg.io/instanceRole=primary -o name 2>/dev/null | head -n1)"
got=""
if [[ -n "$primary" ]]; then
  for t in asset assets; do
    got="$(kubectl -n "$ns" exec "$primary" -c postgres -- psql -U postgres -d immich -tAc "select count(*) from $t" 2>/dev/null | tr -d ' \r' || true)"
    [[ "$got" =~ ^[0-9]+$ ]] && break
    got=""
  done
fi
if [[ "$notready" != 0 ]]; then
  g2 3 immich FAIL "$notready immich pod(s) not Ready"
elif [[ ! "$want" =~ ^[0-9]+$ ]]; then
  g2 3 immich FAIL "no numeric 'PRE-CUTOVER-ASSET-COUNT:' in talos/CUTOVER.md"
elif [[ "$got" == "$want" ]]; then
  g2 3 immich PASS "assets=$got"
else
  g2 3 immich FAIL "assets restored=${got:-unreadable} recorded=$want"
fi

# G2-4: the cp bot runs and its session volume is Bound (the WhatsApp login is yours).
bot="$(kubectl -n "$bot_ns" get pods -o json 2>/dev/null | jq -r '[.items[] | select(.metadata.name | test("cp-reserva")) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length')"
pvc="$(kubectl -n "$bot_ns" get pvc -o json 2>/dev/null | jq -r '[.items[] | select(.metadata.name | test("cp-reserva")) | select(.status.phase == "Bound")] | length')"
if [[ "$bot" =~ ^[1-9] && "$pvc" =~ ^[1-9] ]]; then
  g2 4 cp-bot-session BRUNO "pod Ready, PVC Bound; confirm WhatsApp is still logged in"
else
  g2 4 cp-bot-session FAIL "bot pods Ready=$bot, Bound PVCs=$pvc"
fi

# G2-5: a hardware transcode shows in the newest FFmpeg log (log path unverified).
log="$(kubectl -n "$ns" exec deploy/jellyfin -- sh -c 'ls -t /config/log/FFmpeg.Transcode-*.log 2>/dev/null | head -n1' 2>/dev/null || true)"
if [[ -z "$log" ]]; then
  g2 5 jellyfin-qsv FAIL "no transcode log found: play a file that forces a transcode, or record JELLYFIN-QSV: PASS by hand"
elif kubectl -n "$ns" exec deploy/jellyfin -- grep -q -i -E 'qsv|vaapi' "$log" 2>/dev/null; then
  g2 5 jellyfin-qsv PASS "qsv or vaapi in the newest transcode log"
else
  g2 5 jellyfin-qsv FAIL "newest transcode log has no qsv or vaapi (software transcode?)"
fi

# G2-6: the Toshiba is mounted on the node (mounts output format unverified).
if [[ -z "${MINI01:-}" ]] || ! command -v talosctl >/dev/null 2>&1; then
  g2 6 toshiba BRUNO "set MINI01 and install talosctl, or run: talosctl -n <node> mounts | grep /var/mnt/media"
elif talosctl -n "$MINI01" mounts 2>/dev/null | grep -q '/var/mnt/media'; then
  g2 6 toshiba PASS
else
  g2 6 toshiba FAIL "/var/mnt/media not in talosctl mounts"
fi

# G2-7: the backup schedule repeats. The cadence is DAILY now (hourly was the first plan): two
# Completed backups of schedule velero-homeserver-nightly at least 20 h apart. The older schedule
# homeserver-hourly still passes on its own terms (two backups at least 50 min apart).
span_of() {
  kubectl -n velero get backups.velero.io -l "velero.io/schedule-name=$1" -o json 2>/dev/null |
    jq -r '[.items[] | select(.status.phase == "Completed") | .status.completionTimestamp | fromdateiso8601] | if length < 2 then -1 else (max - min) end'
}
span_n="$(span_of velero-homeserver-nightly)"
span_h="$(span_of homeserver-hourly)"
if [[ "$span_n" =~ ^[0-9]+$ ]] && ((span_n >= 72000)); then
  g2 7 daily-backup PASS "span $((span_n / 3600)) h"
elif [[ "$span_h" =~ ^[0-9]+$ ]] && ((span_h >= 3000)); then
  g2 7 hourly-backup PASS "span $((span_h / 60)) min"
else
  g2 7 daily-backup FAIL "need two Completed backups from schedule velero-homeserver-nightly at least 20 h apart (span=${span_n:--1})"
fi

# G2-8 and G2-9 come from the drill record and your own check.
if [[ "$(rec UPGRADE-REHEARSAL)" == PASS ]]; then g2 8 upgrade-rehearsal PASS; else g2 8 upgrade-rehearsal FAIL "no 'UPGRADE-REHEARSAL: PASS' in talos/CUTOVER.md"; fi
if [[ "$(rec COPY-256-DIR)" == NOT-NEEDED ]]; then
  g2 9 copy-kept PASS "256 held nothing to keep (recorded)"
elif [[ -n "$(rec COPY-256-DIR)" ]]; then
  g2 9 copy-kept BRUNO "confirm on victus that that directory still exists"
else
  g2 9 copy-kept FAIL "no 'COPY-256-DIR:' in talos/CUTOVER.md"
fi
exit 0
