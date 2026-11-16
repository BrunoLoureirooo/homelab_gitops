#!/usr/bin/env bash
# CI guardrail (SPEC R21): this repo is public, so planning docs, images,
# scripts, tests and the phase-1 Ansible additions must not carry host
# details: private IPv4 addresses, tailnet names, MAC addresses or SSH key
# fingerprints. Only the QEMU user-network addresses used by CI are allowed.
#
# Prints `<file>:<line>: <pattern-name>` and NEVER the matched value, so a
# failing CI log does not re-publish what it caught.
#
# Env: CHECK_ROOT (default .), used by tests to scan a planted fixture.
set -uo pipefail

root="${CHECK_ROOT:-.}"
cd "$root" || exit 2

paths=(
  .planning docs images scripts tests talos
  ansible/roles/tailscale_join ansible/roles/svc_tang
  ansible/roles/luks_clevis_enroll ansible/roles/luks_unlock
  ansible/tailscale.yml ansible/tang.yml
  ansible/luks-clevis-enroll.yml ansible/luks-unlock.yml
  ansible/group_vars/svc_tang.yml ansible/vars
)

present=()
for p in "${paths[@]}"; do
  if [[ -e "$p" ]]; then
    present+=("$p")
  else
    echo "skip $p (not present)"
  fi
done

if [[ ${#present[@]} -eq 0 ]]; then
  echo "OK: no host details"
  exit 0
fi

# QEMU user-mode networking addresses (host, DNS, guest, first DHCP lease).
allow='^10\.0\.2\.(2|3|15|100)$'

b64='[A-Za-z0-9+/]'
declare -a names=(rfc1918 tailnet mac ssh-fingerprint)
declare -a regexes=(
  '(^|[^0-9.])(10(\.[0-9]{1,3}){3}|172\.(1[6-9]|2[0-9]|3[01])(\.[0-9]{1,3}){2}|192\.168(\.[0-9]{1,3}){2})([^0-9]|$)'
  '[A-Za-z0-9-]+\.ts\.net'
  '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}'
  "SHA256:${b64}{43}"
)

bad=0
for i in "${!names[@]}"; do
  name="${names[$i]}"
  while IFS=: read -r file line rest; do
    [[ -z "$file" ]] && continue
    if [[ "$name" == "rfc1918" ]]; then
      # Extract the address(es) on the line and drop allow-listed ones.
      hit=0
      while IFS= read -r ip; do
        [[ "$ip" =~ $allow ]] && continue
        # The CI-only private network of the Talos two-node harness.
        if [[ "$file" == talos/test/* && "$ip" =~ ^192\.168\.100\.[0-9]+$ ]]; then continue; fi
        # QEMU's user-mode network (guest 10.0.2.15, host 10.0.2.2, ...), CI only.
        if [[ "$file" == talos/test/* && "$ip" =~ ^10\.0\.2\.[0-9]+$ ]]; then continue; fi
        hit=1
      done < <(printf '%s\n' "$rest" | grep -oE '(10(\.[0-9]{1,3}){3}|172\.(1[6-9]|2[0-9]|3[01])(\.[0-9]{1,3}){2}|192\.168(\.[0-9]{1,3}){2})')
      ((hit)) || continue
    fi
    if [[ "$name" == "mac" && "$file" == talos/test/* ]]; then
      # QEMU's own 52:54:00 prefix is used for the fixed CI MAC addresses.
      hit=0
      while IFS= read -r m; do
        [[ "$m" =~ ^52:54:00: ]] || hit=1
      done < <(printf '%s\n' "$rest" | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}')
      ((hit)) || continue
    fi
    echo "$file:$line: $name"
    bad=1
  done < <(grep -rnE "${regexes[$i]}" "${present[@]}" 2>/dev/null)
done

# Tailscale CGNAT addresses (100.64.0.0/10) are host details under talos/.
if [[ -d talos ]]; then
  while IFS=: read -r file line _; do
    [[ -z "$file" ]] && continue
    echo "$file:$line: tailscale-cgnat"
    bad=1
  done < <(grep -rnE '(^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])(\.[0-9]{1,3}){2}([^0-9]|$)' talos 2>/dev/null)
fi

if ((bad)); then
  exit 1
fi
echo "OK: no host details"
