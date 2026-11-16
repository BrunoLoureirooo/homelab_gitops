#!/usr/bin/env bash
# Read-only pre-flight for the mini01 cutover (plan 15-07). Lists everything that
# must be true before any disk is swapped. It reads the OLD cluster
# (`kubectl get`), the standalone MinIO health endpoint, local files and the CI
# run list; it changes nothing anywhere.
#
#   cutover-preflight.sh
#
# Prints `PF-<n> <name> PASS|FAIL|BRUNO [note]`. BRUNO means "confirm this by
# hand". Exit 0 once the cluster was reachable (even with FAIL lines: read them),
# exit 2 with `cannot reach a cluster` when kubectl cannot talk to the old one.
#
# Env: KUBECONFIG/context as usual; MINIO_ENDPOINT (standalone MinIO base URL on
# victus, not committed) and MC_ALIAS (an `mc` alias for it) for PF-4;
# TAL_CACHE (default ./.cache) where fetch-assets.sh keeps the ISO.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
troot="$(cd "$here/.." && pwd)"
repo="$(cd "$troot/.." && pwd)"
cutover="${CUTOVER_FILE:-$troot/CUTOVER.md}" # the override exists for the offline test
findings="${FINDINGS_FILE:-$troot/FINDINGS.md}"
cache="${TAL_CACHE:-$PWD/.cache}"

pf() { # pf <n> <name> <PASS|FAIL|BRUNO> [note]
  printf 'PF-%s %s %s%s\n' "$1" "$2" "$3" "${4:+ $4}"
}
rec() { # rec KEY -> the value of a `KEY: value` line in CUTOVER.md
  [[ -f "$cutover" ]] || return 0
  grep -m1 "^$1:" "$cutover" | sed -E "s/^$1:[[:space:]]*//" || true
}
epoch_of() { # epoch_of YYYY-MM-DD
  date -d "$1" +%s 2>/dev/null || date -j -f %Y-%m-%d "$1" +%s 2>/dev/null || echo 0
}
day_of() { # the date part of "<PASS|...> YYYY-MM-DD"
  printf '%s' "$1" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n1
}

cluster=1
kubectl --request-timeout=5s get ns >/dev/null 2>&1 || cluster=0

# shellcheck source=/dev/null
. "$troot/versions.env"

# PF-1: the ISO is pinned by us and present locally.
st=PASS
note=""
if [[ "${ASSET_MINI01_ISO_SHA256:-}" =~ ^[0-9a-f]{64}$ ]]; then :; else
  st=FAIL
  note="ASSET_MINI01_ISO_SHA256 is not pinned"
fi
if [[ "$(rec SECURE-BOOT)" == try || "$(rec SECURE-BOOT)" == off ]]; then
  [[ "${ASSET_MINI01_ISO_SECUREBOOT_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || {
    st=FAIL
    note="ASSET_MINI01_ISO_SECUREBOOT_SHA256 is not pinned"
  }
fi
if ! ls "$cache"/talos-mini01-*.iso >/dev/null 2>&1; then
  st=FAIL
  note="${note:+$note; }no ISO in $cache: run talos/fetch-assets.sh mini01 iso"
fi
pf 1 iso-pinned "$st" "$note"

# PF-2: a restore drill passed after the last chart change.
drill="$(day_of "$(rec RESTORE-DRILL)")"
if [[ "$(rec RESTORE-DRILL)" == PASS* && -n "$drill" ]]; then
  changed="$(git -C "$repo" log -1 --format=%cs -- argocd talos/apps-src talos/values 2>/dev/null || true)"
  if [[ -z "$changed" || ! "$drill" < "$changed" ]]; then
    pf 2 restore-drill PASS "drill $drill"
  else
    pf 2 restore-drill FAIL "drill $drill is older than the last chart change $changed"
  fi
else
  pf 2 restore-drill FAIL "record 'RESTORE-DRILL: PASS <date>' in talos/CUTOVER.md after the 15-06 live drill"
fi

# PF-3: sealing key MATCH recorded in the last 7 days (the offline copy is yours).
match="$(day_of "$(rec SEALING-KEY-MATCH)")"
if [[ -n "$match" ]] && (($(date +%s) - $(epoch_of "$match") <= 7 * 86400)); then
  pf 3 sealing-key-match PASS "$match"
else
  pf 3 sealing-key-match BRUNO "run talos/dr/verify-sealing-key.sh on the offline copy, then record 'SEALING-KEY-MATCH: <date>'"
fi

# PF-4: the standalone MinIO answers (dry-run directory) and has the three buckets.
if [[ -z "${MINIO_ENDPOINT:-}" ]]; then
  pf 4 standalone-minio BRUNO "MINIO_ENDPOINT is not set"
elif ! curl -fsS -m 5 "${MINIO_ENDPOINT%/}/minio/health/live" >/dev/null 2>&1; then
  pf 4 standalone-minio FAIL "no health answer"
elif [[ -z "${MC_ALIAS:-}" ]] || ! command -v mc >/dev/null 2>&1; then
  pf 4 standalone-minio BRUNO "healthy; set MC_ALIAS and install mc to list the buckets"
else
  listing="$(mc ls "$MC_ALIAS" 2>/dev/null || true)"
  missing=""
  for b in velero-backups litestream immich-pg; do
    grep -q "$b" <<<"$listing" || missing="$missing $b"
  done
  if [[ -z "$missing" ]]; then pf 4 standalone-minio PASS "three buckets"; else pf 4 standalone-minio FAIL "missing buckets:$missing"; fi
fi

# PF-5: a completed Velero backup newer than 24 hours (old cluster).
if ((cluster)); then
  hours="$(kubectl -n velero get backups.velero.io -o json 2>/dev/null |
    jq -r '[.items[] | select(.status.phase == "Completed") | .status.completionTimestamp | fromdateiso8601] | max // 0 | if . == 0 then 9999 else ((now - .) / 3600 | floor) end' 2>/dev/null || echo 9999)"
  if [[ "$hours" =~ ^[0-9]+$ ]] && ((hours < 24)); then
    pf 5 velero-backup-fresh PASS "${hours}h old"
  else
    pf 5 velero-backup-fresh FAIL "newest completed backup is ${hours}h old (9999 means none)"
  fi
else
  pf 5 velero-backup-fresh BRUNO "no cluster"
fi

# PF-6: no Ansible deploy is running.
if command -v gh >/dev/null 2>&1 && running="$(gh run list --workflow deploy.yml --status in_progress --json databaseId --jq length 2>/dev/null)"; then
  if [[ "$running" == 0 ]]; then pf 6 no-deploy-running PASS; else pf 6 no-deploy-running FAIL "$running run(s) in progress"; fi
else
  pf 6 no-deploy-running BRUNO "gh unavailable: check the Actions tab by hand"
fi

# PF-7: the three disk-identity lines are filled by the operator.
st=PASS
note=""
for k in LIVE-DISK-CONFIRMED DISK-256-CONTENT BACKUP-DISK; do
  v="$(rec "$k")"
  if [[ -z "$v" || "$v" == "<"* ]]; then
    st=FAIL
    note="${note:+$note, }$k"
  fi
done
pf 7 disk-identity "$st" "${note:+empty: $note}"

# PF-8: gate G1.
if grep -q '^G1 DECISION: go' "$findings" 2>/dev/null; then pf 8 g1-go PASS; else pf 8 g1-go FAIL "no 'G1 DECISION: go' line in talos/FINDINGS.md"; fi

# PF-9: no decision is still DEFAULT.
if bash "$repo/.github/scripts/check-talos-config.sh" --require-decisions >/dev/null 2>&1; then
  pf 9 decisions-answered PASS
else
  pf 9 decisions-answered FAIL "run: bash .github/scripts/check-talos-config.sh --require-decisions"
fi

# PF-10: the first pass of the 256-disk copy verified.
if [[ "$(rec COPY-256-PRECOPY)" == NOT-NEEDED ]]; then pf 10 precopy-256 PASS "256 holds nothing to keep (recorded)"; elif [[ "$(rec COPY-256-PRECOPY)" == PASS ]]; then pf 10 precopy-256 PASS; else pf 10 precopy-256 FAIL "no 'COPY-256-PRECOPY: PASS' in talos/CUTOVER.md"; fi

# Both Toshibas are formatted, and they are the same model: each is pinned by serial.
if [[ -f "$troot/secrets/disks-mini01.sops.yaml" ]]; then pf 11 disk-inventory PASS; else pf 11 disk-inventory FAIL "no talos/secrets/disks-mini01.sops.yaml (see talos/secrets/README.md section 5)"; fi

if ((!cluster)); then
  echo "cannot reach a cluster (PF-5 needs the old one)" >&2
  exit 2
fi
exit 0
