#!/usr/bin/env bash
# Merge the findings of every Talos CI job into one file and one table.
#
#   collect.sh [--out DIR] <dir>...
#
# Reads every findings-<job>.txt below the given directories (the layout of
# `gh run download`) and writes
#   <out>/findings.txt     FINDING lines, one per id (the last job in sorted
#                          file order wins), sorted, plus a STORAGE_VERDICT= line
#   <out>/FINDINGS-ci.md   markdown table: id, class (from the criteria), verdict,
#                          note, job
# STORAGE_VERDICT=topolvm when LVM-IN-POD and TOPOLVM-ON-TALOS are both PASS,
# local-path when STORAGE-USERVOL-LOCALPATH is PASS and the TopoLVM case is not,
# none otherwise. Plan 15-03 reads that line.
# Portable to bash 3.2.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
criteria="${G1_CRITERIA:-$here/../g1-criteria.tsv}"
out="."
if [[ "${1:-}" == --out ]]; then
  out="${2:?--out needs a directory}"
  shift 2
fi
[[ $# -ge 1 ]] || {
  echo "usage: collect.sh [--out DIR] <dir>..." >&2
  exit 64
}
mkdir -p "$out"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

: >"$work/all.tsv"
while IFS= read -r f; do
  job="$(basename "$f" .txt)"
  job="${job#findings-}"
  # id <TAB> verdict <TAB> job <TAB> note
  awk -v job="$job" '$1 == "FINDING" && NF >= 3 {
      note = ""
      for (i = 4; i <= NF; i++) note = note (i > 4 ? " " : "") $i
      print $2 "\t" $3 "\t" job "\t" note
    }' "$f" >>"$work/all.tsv"
done < <(find "$@" -type f -name 'findings-*.txt' | sort)

# last occurrence of an id wins
awk -F'\t' '{ line[$1] = $0 } END { for (k in line) print line[k] }' "$work/all.tsv" | sort >"$work/merged.tsv"

verdict_of() {
  local v
  v="$(awk -F'\t' -v id="$1" '$1 == id { print $2 }' "$work/merged.tsv")"
  echo "${v:-MISSING}"
}

storage=none
if [[ "$(verdict_of LVM-IN-POD)" == PASS && "$(verdict_of TOPOLVM-ON-TALOS)" == PASS ]]; then
  storage=topolvm
elif [[ "$(verdict_of STORAGE-USERVOL-LOCALPATH)" == PASS ]]; then
  storage=local-path
fi

{
  awk -F'\t' '{ print "FINDING " $1 " " $2 " " $4 }' "$work/merged.tsv"
  echo "STORAGE_VERDICT=${storage}"
} >"$out/findings.txt"

{
  echo "| id | class | verdict | note | job |"
  echo "|---|---|---|---|---|"
  while IFS=$'\t' read -r id verdict job note; do
    class="$(grep -v '^#' "$criteria" | awk -F'\t' -v id="$id" '$1 == id { print $2 }')"
    echo "| ${id} | ${class:-extra} | ${verdict} | ${note//|/\\|} | ${job} |"
  done <"$work/merged.tsv"
  echo
  echo "STORAGE_VERDICT=${storage}"
} >"$out/FINDINGS-ci.md"

echo "collect: $(wc -l <"$work/merged.tsv" | tr -d ' ') findings, STORAGE_VERDICT=${storage}"
