#!/usr/bin/env bash
# G1 gate (plan 15-04): turn a findings file into G1=go|no-go|incomplete.
#
#   g1-gate.sh <findings-file> [--criteria FILE]
#
# Findings are lines `FINDING <id> <PASS|FAIL|UNKNOWN|HARDWARE-ONLY> <note>`
# (the last line for an id wins; other lines are ignored). The rules live in
# talos/g1-criteria.tsv, not here:
#   must    PASS, else FAIL -> no-go; UNKNOWN, HARDWARE-ONLY or missing -> incomplete
#   known   determined (PASS, or FAIL where the table allows it); UNKNOWN or
#           missing -> incomplete; RESET-NEGATIVE-CONTROL must be PASS
#   should  a non-PASS row is printed as G1-CONSEQUENCE and never blocks
#   info    recorded only
# An any-of row (members column) passes when any member is PASS.
# While talos/PINS-PENDING exists the result is `incomplete`: the VM jobs were
# skipped, so a green run proves nothing.
#
# Output: G1-ROW lines, G1-CONSEQUENCE lines, G1-REASON lines, then one line
# G1=go|no-go|incomplete. Exit 0 go, 1 no-go, 2 incomplete (no-go wins).
# Env G1_PINS_PENDING_FILE overrides the PINS-PENDING path (self-test).
# Portable to bash 3.2 (no associative arrays).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
findings="${1:-}"
[[ -n "$findings" && -f "$findings" ]] || {
  echo "usage: g1-gate.sh <findings-file> [--criteria FILE]" >&2
  exit 64
}
shift
criteria="$here/g1-criteria.tsv"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --criteria)
      criteria="${2:?--criteria needs a file}"
      shift 2
      ;;
    *)
      echo "unknown argument $1" >&2
      exit 64
      ;;
  esac
done
[[ -f "$criteria" ]] || {
  echo "no criteria file $criteria" >&2
  exit 64
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# id <TAB> verdict, the last line of an id wins.
awk '$1 == "FINDING" && NF >= 3 { v[$2] = $3; if (!($2 in o)) { o[$2] = ++n } } END { for (k in v) print k "\t" v[k] }' "$findings" | sort >"$work/last.tsv"

verdict_of() { # verdict_of <id>
  local v
  v="$(awk -F'\t' -v id="$1" '$1 == id { print $2 }' "$work/last.tsv")"
  echo "${v:-MISSING}"
}

nogo=0
incomplete=0
: >"$work/known.txt"
reason() { echo "G1-REASON $*"; }

pins="${G1_PINS_PENDING_FILE:-$here/PINS-PENDING}"
if [[ -e "$pins" ]]; then
  incomplete=1
  reason "talos/PINS-PENDING exists: the VM jobs were skipped, nothing was proven"
fi

sep=$'\x1f'
grep -v '^#' "$criteria" | awk -F'\t' -v s="$sep" 'NR > 1 && NF >= 6 { print $1 s $2 s $3 s $4 s $5 s $6 }' >"$work/rows.txt"

while IFS="$sep" read -r id class _owner allowed members consequence; do
  [[ -n "$id" ]] || continue
  echo "$id" >>"$work/known.txt"
  v="$(verdict_of "$id")"
  if [[ -n "$members" ]]; then
    # any-of row: the verdict is derived from the members
    any=""
    firstfail=""
    other=""
    old_ifs="$IFS"
    IFS=','
    for m in $members; do
      IFS="$old_ifs"
      echo "$m" >>"$work/known.txt"
      mv="$(verdict_of "$m")"
      case "$mv" in
        PASS) any=PASS ;;
        FAIL) firstfail=FAIL ;;
        MISSING) ;;
        *) other="$mv" ;;
      esac
    done
    IFS="$old_ifs"
    if [[ -n "$any" ]]; then
      v=PASS
    elif [[ -n "$other" ]]; then
      v="$other"
    elif [[ -n "$firstfail" ]]; then
      v=FAIL
    else
      v=MISSING
    fi
  fi
  echo "G1-ROW $id $class $v"
  case "$class" in
    must)
      case "$v" in
        PASS) ;;
        FAIL)
          nogo=1
          reason "$id FAILED: $consequence"
          ;;
        *)
          incomplete=1
          reason "$id is $v (a must row needs PASS)"
          ;;
      esac
      ;;
    known)
      if [[ "$id" == RESET-NEGATIVE-CONTROL ]]; then
        if [[ "$v" != PASS ]]; then
          incomplete=1
          reason "$id is $v: $consequence"
        fi
      else
        case "$v" in
          PASS | FAIL) ;;
          *)
            incomplete=1
            reason "$id is $v (a known row must be determined)"
            ;;
        esac
      fi
      ;;
    should)
      ok=0
      [[ "$v" == PASS ]] && ok=1
      if [[ "$allowed" == *FAIL* && "$v" == FAIL ]]; then ok=1; fi
      if ((!ok)); then
        echo "G1-CONSEQUENCE $id ($v) $consequence"
      fi
      ;;
    info) ;;
    *)
      incomplete=1
      reason "criteria row $id has an unknown class $class"
      ;;
  esac
done <"$work/rows.txt"

# Findings the criteria do not know about are reported, never ignored.
awk -F'\t' 'NR == FNR { k[$1] = 1; next } !($1 in k) { print "G1-EXTRA " $1 " " $2 }' "$work/known.txt" "$work/last.tsv" | sort

if ((nogo)); then
  echo "G1=no-go"
  exit 1
elif ((incomplete)); then
  echo "G1=incomplete"
  exit 2
fi
echo "G1=go"
exit 0
