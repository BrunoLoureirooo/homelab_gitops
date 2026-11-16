#!/usr/bin/env bash
# Copy a disk's data to another disk and prove the copy with a sha256 manifest
# compared on both sides (plan 15-07, the HARD STOP before the 256 GB disk leaves
# victus). operator-run on victus. NEVER writes to SRC and never uses --delete.
#
#   disk256-copy.sh copy   SRC DEST [--final]   rsync SRC/ to DEST/, then verify
#   disk256-copy.sh verify SRC DEST [--final]   only compare the two manifests
#
# --final labels the second pass (after the freeze); behaviour is identical.
# Output: one line, `COPY-VERIFY PASS|FAIL files=<n> bytes=<n> [pass=final]`, then
# `DIFF <path>` for every file that differs or exists on one side only (at most
# 50). Exit 0 on PASS, 1 on FAIL, 2 on a refusal or bad usage. Needs lsblk and
# findmnt (Linux): without them it refuses.
#
# Refuses when: DEST is inside SRC; SRC and DEST sit on the same physical disk;
# SRC is the root filesystem; SRC or DEST does not exist (DEST is created by
# `copy` when its parent exists).
#
# Env: D256_RSYNC_OPTS overrides the rsync options (default -aHAX --numeric-ids),
# for hosts whose rsync lacks ACL/xattr support.
set -euo pipefail

usage() {
  echo "usage: disk256-copy.sh copy|verify SRC DEST [--final]" >&2
  exit 2
}
refuse() {
  echo "REFUSED: $*" >&2
  exit 2
}

mode="${1:-}"
src_arg="${2:-}"
dest_arg="${3:-}"
label=""
case "${4:-}" in
  "") ;;
  --final) label=" pass=final" ;;
  *) usage ;;
esac
[[ "$mode" == copy || "$mode" == verify ]] || usage
[[ -n "$src_arg" && -n "$dest_arg" ]] || usage

command -v lsblk >/dev/null 2>&1 || refuse "lsblk not found: run this on victus (Linux)"
command -v findmnt >/dev/null 2>&1 || refuse "findmnt not found: run this on victus (Linux)"

[[ -d "$src_arg" ]] || refuse "SRC is not a directory"
src="$(cd "$src_arg" && pwd -P)"
if [[ "$mode" == copy && ! -d "$dest_arg" ]]; then
  parent="$(dirname "$dest_arg")"
  [[ -d "$parent" ]] || refuse "parent of DEST does not exist"
  mkdir "$dest_arg"
fi
[[ -d "$dest_arg" ]] || refuse "DEST is not a directory"
dest="$(cd "$dest_arg" && pwd -P)"

case "$dest/" in
  "$src"/*) refuse "DEST is inside SRC" ;;
esac
[[ "$src" != "/" ]] || refuse "SRC is the root filesystem"

source_dev() { findmnt -no SOURCE --target "$1" | head -n1; }
physical_disk() {
  local dev pk
  dev="$1"
  pk="$(lsblk -no PKNAME "$dev" 2>/dev/null | head -n1 || true)"
  [[ -n "$pk" ]] || pk="$(basename "$dev")"
  printf '%s' "$pk"
}

src_dev="$(source_dev "$src")"
dest_dev="$(source_dev "$dest")"
root_dev="$(source_dev /)"
[[ -n "$src_dev" && -n "$dest_dev" ]] || refuse "cannot find the device of SRC or DEST"
[[ "$src_dev" != "$root_dev" ]] || refuse "SRC is on the root filesystem"
[[ "$(physical_disk "$src_dev")" != "$(physical_disk "$dest_dev")" ]] || refuse "SRC and DEST are on the same physical disk"

if [[ "$mode" == copy ]]; then
  # shellcheck disable=SC2086
  rsync ${D256_RSYNC_OPTS:--aHAX --numeric-ids} "$src/" "$dest/" >/dev/null
fi

sha_of_list() { # reads NUL-separated paths on stdin, prints "hash  path"
  if command -v sha256sum >/dev/null 2>&1; then xargs -0 sha256sum; else xargs -0 shasum -a 256; fi
}

manifest() { # manifest <dir> <out>
  local dir="$1" out="$2"
  (
    cd "$dir"
    {
      find . -type f -print0 | LC_ALL=C sort -z | sha_of_list | sed -E 's/^([0-9a-f]{64})  (.*)$/F:\2\t\1/'
      find . -type d -empty -print | LC_ALL=C sort | sed -E 's/^(.*)$/D:\1\tempty/'
      while IFS= read -r -d '' l; do
        printf 'L:%s\t%s\n' "$l" "$(readlink "$l")"
      done < <(find . -type l -print0 | LC_ALL=C sort -z)
    } | LC_ALL=C sort
  ) >"$out"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
manifest "$src" "$tmp/src"
manifest "$dest" "$tmp/dest"

files="$(grep -c '^F:' "$tmp/src" || true)"
bytes=0
if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
  bytes="$(cd "$src" && find . -type f -printf '%s\n' | awk '{s+=$1} END{print s+0}')"
else
  bytes="$(cd "$src" && find . -type f -exec stat -f %z {} + | awk '{s+=$1} END{print s+0}')"
fi

if cmp -s "$tmp/src" "$tmp/dest"; then
  echo "COPY-VERIFY PASS files=$files bytes=$bytes$label"
  exit 0
fi

echo "COPY-VERIFY FAIL files=$files bytes=$bytes$label"
awk -F'\t' 'NR==FNR{a[$1]=$2;next}{b[$1]=$2} END{for(k in a) if(!(k in b)||a[k]!=b[k]) print k; for(k in b) if(!(k in a)) print k}' "$tmp/src" "$tmp/dest" |
  LC_ALL=C sort -u >"$tmp/diff"
head -n 50 "$tmp/diff" | sed 's/^/DIFF /'
total="$(wc -l <"$tmp/diff" | tr -d ' ')"
((total <= 50)) || echo "... and $((total - 50)) more"
exit 1
