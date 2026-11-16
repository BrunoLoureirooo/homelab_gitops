#!/usr/bin/env bash
# talos-job: kvm=no timeout=10
# disk256-copy.sh against temp trees and fake lsblk/findmnt (no hardware):
#   identical copy -> PASS; one flipped byte -> FAIL naming the file; a file only
#   in DEST or missing from DEST -> FAIL; SRC is never changed; refusals for
#   DEST inside SRC, SRC and DEST on one physical disk, and SRC on the root fs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"

w="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$w"' EXIT
script="$TAL_ROOT/scripts/disk256-copy.sh"

# Fake devices: root on sda, SRC on sdb, DEST on sdc.
printf '%s\n' "/ /dev/sda2" "$w/src /dev/sdb1" "$w/dest /dev/sdc1" "$w/dest-same /dev/sdb2" "$w/src-root /dev/sda2" >"$w/mountmap"
printf '%s\n' "/dev/sda2 sda" "/dev/sdb1 sdb" "/dev/sdb2 sdb" "/dev/sdc1 sdc" >"$w/diskmap"
export FAKE_MOUNT_MAP="$w/mountmap" FAKE_DISK_MAP="$w/diskmap"
export PATH="$here/../fixtures/fakebin-disk:$PATH"

# macOS rsync lacks ACL and xattr flags: fall back for local runs only.
mkdir -p "$w/probe"
if ! rsync -aHAX --numeric-ids "$w/probe/" "$w/probe2/" >/dev/null 2>&1; then
  export D256_RSYNC_OPTS="-aH --numeric-ids"
fi

mkdir -p "$w/src/docs/deep/er" "$w/src/empty-dir" "$w/dest" "$w/src-root" "$w/dest-same"
printf 'alpha\n' >"$w/src/a.txt"
printf 'beta beta\n' >"$w/src/docs/b file with spaces.txt"
head -c 200000 /dev/urandom >"$w/src/docs/deep/er/blob.bin"
ln -s a.txt "$w/src/link-to-a"

tree_sum() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 cksum | cksum); }
src_before="$(tree_sum "$w/src")"

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

expect copy-pass 0 "COPY-VERIFY PASS" -- bash "$script" copy "$w/src" "$w/dest"
expect verify-pass 0 "COPY-VERIFY PASS files=3" -- bash "$script" verify "$w/src" "$w/dest"
expect final-label 0 "pass=final" -- bash "$script" verify "$w/src" "$w/dest" --final

# One flipped byte in DEST.
printf 'X' | dd of="$w/dest/docs/deep/er/blob.bin" bs=1 count=1 conv=notrunc 2>/dev/null
expect flipped-byte-fails 1 "DIFF F:./docs/deep/er/blob.bin" -- bash "$script" verify "$w/src" "$w/dest"
# Repair, then a file only in DEST.
cp "$w/src/docs/deep/er/blob.bin" "$w/dest/docs/deep/er/blob.bin"
expect repaired-passes 0 "COPY-VERIFY PASS" -- bash "$script" verify "$w/src" "$w/dest"
echo extra >"$w/dest/only-in-dest.txt"
expect extra-file-reported 1 "DIFF F:./only-in-dest.txt" -- bash "$script" verify "$w/src" "$w/dest"
rm -f "$w/dest/only-in-dest.txt"
# A file missing from DEST.
rm -f "$w/dest/a.txt"
expect missing-file-reported 1 "DIFF F:./a.txt" -- bash "$script" verify "$w/src" "$w/dest"
# copy repairs it (no --delete: nothing else disappears).
expect copy-repairs 0 "COPY-VERIFY PASS" -- bash "$script" copy "$w/src" "$w/dest"

# Refusals.
expect refuse-dest-inside-src 2 "DEST is inside SRC" -- bash "$script" copy "$w/src" "$w/src/docs"
expect refuse-same-disk 2 "same physical disk" -- bash "$script" copy "$w/src" "$w/dest-same"
expect refuse-root-fs 2 "root filesystem" -- bash "$script" copy "$w/src-root" "$w/dest"
expect refuse-usage 2 "usage" -- bash "$script" copy "$w/src"

# SRC is never changed.
if [[ "$(tree_sum "$w/src")" == "$src_before" ]]; then
  tal_finding src-untouched PASS "tree checksum unchanged"
else
  tal_finding src-untouched FAIL "SRC changed"
  fails=$((fails + 1))
fi

((fails == 0)) || tal_die "$fails disk256-copy behaviours were wrong"
tal_report "DISK256_COPY=pass"
