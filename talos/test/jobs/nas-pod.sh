#!/usr/bin/env bash
# talos-job: kvm=yes timeout=30
# Plan 15-05 Task 2: the Samba pod over a plain directory in the CI cluster
# (a stand-in for the ZFS dataset; the pool itself is proven by zfs-mirror.sh).
# A client pod writes a file over SMB and reads it back byte for byte.
#
# Needs the 15-01 harness (lib.sh, talos_ci_up/talos_ci_down).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
talos_dir="$(cd "$here/../.." && pwd)"
# shellcheck source=/dev/null
. "$talos_dir/test/lib.sh"
# shellcheck source=/dev/null
. "$talos_dir/test/nas-lib.sh"

name=nas-pod
trap 'talos_ci_down "$name" || true' EXIT
talos_ci_up "$name"

nas_up
token="nas-$(date +%s)-$$"

out="$(nas_client nas-put "echo $token > /tmp/up.txt; put /tmp/up.txt ci-check.txt; get ci-check.txt /tmp/down.txt; !cat /tmp/down.txt")"
if grep -qx "$token" <<<"$out"; then
  tal_report "ASSERT smb-roundtrip PASS"
else
  tal_report "ASSERT smb-roundtrip FAIL"
  tal_finding NAS-POD FAIL "file written over SMB did not read back"
  exit 1
fi

# A second client sees the file the first one stored (data is on the pod's volume).
listing="$(nas_client nas-ls "ls")"
if grep -q 'ci-check.txt' <<<"$listing"; then
  tal_report "ASSERT share-listing PASS"
else
  tal_report "ASSERT share-listing FAIL"
  tal_finding NAS-POD FAIL "second client does not see the stored file"
  exit 1
fi
tal_finding NAS-POD PASS "Samba pod serves a share and a client reads back what it wrote"
