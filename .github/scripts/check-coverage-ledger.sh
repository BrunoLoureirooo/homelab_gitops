#!/usr/bin/env bash
# Keep docs/mini01-coverage.md honest (plan 15-09, adapted from the Phase 1 ledger
# check). Prints `LEDGER-BAD <row>: <reason>` per problem and exits 1:
#   - a row whose disposition is not one of DECLARED MANUAL-DOCUMENTED EPHEMERAL
#     RESTORED DRILL-PENDING, or is UNCOVERED
#   - DECLARED: the Detail path must exist (enforced once talos/G2-PASSED exists
#     or LEDGER_STRICT=1; before that a missing path is a LEDGER-WARN)
#   - MANUAL-DOCUMENTED: the Detail anchor (docs/rebuild-node.md#slug) must match a
#     heading of docs/rebuild-node.md
#   - EPHEMERAL: a reason of at least five words
#   - RESTORED: the Drill id has a PASS row in the drill record of
#     docs/rebuild-node.md
#   - DRILL-PENDING: the Drill id is in the drill catalogue
#   - the file contains no address, UUID, 64-hex fingerprint or token text
#
# Env: CL_ROOT (repository root, default: this repository), used by the self-test.
set -uo pipefail

root="${CL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ledger="$root/docs/mini01-coverage.md"
rb="$root/docs/rebuild-node.md"

if [[ ! -f "$ledger" ]]; then
  echo "OK (no coverage ledger)"
  exit 0
fi

bad=0
flag() { # flag <row> <reason>
  echo "LEDGER-BAD $1: $2"
  bad=1
}

strict=0
[[ -e "$root/talos/G2-PASSED" || "${LEDGER_STRICT:-0}" == 1 ]] && strict=1

slug() { # the GitHub anchor of a heading
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9 _-]//g; s/ /-/g'
}
slugs="$(grep -E '^#{1,6} ' "$rb" 2>/dev/null | sed -E 's/^#+ //' | while IFS= read -r h; do slug "$h"; done)"
catalogue="$(grep -oE '^- D-[A-Z0-9]+' "$rb" 2>/dev/null | sed 's/^- //')"
passed="$(grep -E '^\| D-[A-Z0-9]+ \| PASS ' "$rb" 2>/dev/null | awk -F'|' '{gsub(/ /,"",$2); print $2}')"

trim() { sed -E 's/^ +//; s/ +$//' <<<"$1"; }

n=0
while IFS= read -r line; do
  n=$((n + 1))
  [[ "$line" == "| "* ]] || continue
  IFS='|' read -r _ item cat disp detail drill _ <<<"$line"
  item="$(trim "$item")"
  cat="$(trim "$cat")"
  disp="$(trim "$disp")"
  detail="$(trim "$detail")"
  drill="$(trim "$drill")"
  # Header and separator rows.
  [[ "$item" == Item || "$item" == ---* ]] && continue
  case "$disp" in
    DECLARED)
      if [[ -z "$detail" ]]; then
        flag "$item" "DECLARED needs a path"
      elif [[ ! -e "$root/$detail" ]]; then
        if ((strict)); then flag "$item" "DECLARED path does not exist: $detail"; else echo "LEDGER-WARN $item: path does not exist yet: $detail"; fi
      fi
      ;;
    MANUAL-DOCUMENTED)
      anchor="${detail#docs/rebuild-node.md#}"
      if [[ "$detail" != docs/rebuild-node.md#* ]] || ! grep -qxF "$anchor" <<<"$slugs"; then
        flag "$item" "MANUAL-DOCUMENTED anchor not found in docs/rebuild-node.md: $detail"
      fi
      ;;
    EPHEMERAL)
      words="$(wc -w <<<"$detail" | tr -d ' ')"
      ((words >= 5)) || flag "$item" "EPHEMERAL needs a reason of at least five words"
      ;;
    RESTORED)
      grep -qxF "$drill" <<<"$passed" || flag "$item" "RESTORED needs a PASS drill record row for '$drill'"
      ;;
    DRILL-PENDING)
      grep -qxF "$drill" <<<"$catalogue" || flag "$item" "DRILL-PENDING needs a drill id from the catalogue (got '$drill')"
      ;;
    UNCOVERED) flag "$item" "UNCOVERED is not allowed" ;;
    *) flag "${item:-row $n}" "unknown disposition '$disp'" ;;
  esac
done <"$ledger"

# Names only, never values.
if grep -qE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$ledger"; then flag file "an address-shaped value appears"; fi
if grep -qiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$ledger"; then flag file "a UUID appears"; fi
if grep -qE '[0-9a-f]{64}' "$ledger"; then flag file "a 64-hex fingerprint appears"; fi
if grep -qE 'tskey-|AGE-SECRET-KEY|-----BEGIN' "$ledger"; then flag file "token or key text appears"; fi

if ((bad)); then exit 1; fi
echo "OK: coverage ledger"
