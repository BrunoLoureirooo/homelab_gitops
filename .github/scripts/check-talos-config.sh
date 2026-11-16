#!/usr/bin/env bash
# CI guardrail for the Talos machine config in git (plan 15-02).
#   1  nodes/*.env carry whitelisted keys only and no secret-looking key
#   2  nodes/*.yaml and patches/*.yaml parse, hold no /dev/ path, no IPv4 literal
#      and no disk-encryption block (deferred by the operator on 2026-10-11)
#   3  render.sh exists and is executable
#   4  secrets/*.sops.yaml carry the sops block and an age recipient; no age
#      private key anywhere under talos/; .sops.yaml holds a recipient (the
#      placeholder only while secrets/secrets.sops.yaml does not exist)
#   5  DECISIONS.md has four ANSWER lines (--require-decisions fails on DEFAULT)
#   6  the mini01 media selector excludes the system disk; the Tailscale CI patch
#      holds no auth key; tailscale-*.sops.yaml carry the sops block
#
# Prints `TALOS-CONFIG <rule> <file>:<line> <reason>` (never a secret value).
# Env: TALOS_DIR (default talos), used by the self-test.
# Flag: --require-decisions (plan 15-07 gate; not run by guards.yaml).
set -uo pipefail

root="${TALOS_DIR:-talos}"
require=0
[[ "${1:-}" == "--require-decisions" ]] && require=1

if [[ ! -d "$root" ]]; then
  echo "OK (no talos dir)"
  exit 0
fi

bad=0
viol() { # viol <rule> <where> <reason>
  echo "TALOS-CONFIG $1 $2 $3"
  bad=1
}

# Keep in sync with talos/render.sh.
allowed=" CLUSTER_NAME ENDPOINT_HOST K8S_PORT HOSTNAME ROLE SCHEMATIC DISK_TYPE DISK_SIZE_EXPR DISK_SIZE_MIN_GB MEDIA_MIN_GB MEDIA_MAX_GB INSTALLER "

# ------------------------------------------------------------------ rule 1 ----
for f in "$root"/nodes/*.env "$root"/cluster.env; do
  [[ -f "$f" ]] || continue
  n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ -z "$line" || "$line" == \#* ]] && continue
    if ! [[ "$line" =~ ^([A-Z0-9_]+)= ]]; then
      viol 1 "$f:$n" "not a KEY=VALUE line"
      continue
    fi
    k="${BASH_REMATCH[1]}"
    if [[ "$k" =~ (^|_)(PASS[A-Z]*|HASH|KEY|TOKEN|SECRET)(_|$) ]]; then
      viol 1 "$f:$n" "key looks like a secret"
    elif [[ "$allowed" != *" $k "* ]]; then
      viol 1 "$f:$n" "key is not on the whitelist"
    fi
  done <"$f"
done

# ------------------------------------------------------------------ rule 2 ----
for f in "$root"/nodes/*.yaml "$root"/patches/*.yaml; do
  [[ -f "$f" ]] || continue
  yq '.' "$f" >/dev/null 2>&1 || viol 2 "$f:1" "does not parse as YAML"
  grep -nF '/dev/' "$f" | while IFS=: read -r ln _; do echo "TALOS-CONFIG 2 $f:$ln device path in a committed config"; done | grep . && bad=1
  grep -nE '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)' "$f" | while IFS=: read -r ln _; do echo "TALOS-CONFIG 2 $f:$ln IPv4 literal in a committed config"; done | grep . && bad=1
  grep -nE '^[[:space:]]*(systemDiskEncryption|encryption):' "$f" | while IFS=: read -r ln _; do echo "TALOS-CONFIG 2 $f:$ln disk-encryption block (deferred)"; done | grep . && bad=1
done

# ------------------------------------------------------------------ rule 3 ----
if [[ ! -x "$root/render.sh" ]]; then
  viol 3 "$root/render.sh:1" "missing or not executable"
fi

# ------------------------------------------------------------------ rule 4 ----
if grep -rnIF 'AGE-SECRET-KEY-' --exclude-dir=fixtures --exclude-dir=out --exclude-dir=.cache --exclude-dir=local "$root" >/dev/null 2>&1; then
  viol 4 "$root:0" "an age private key is present under talos/"
fi
for f in "$root"/secrets/*.sops.yaml; do
  [[ -f "$f" ]] || continue
  grep -q '^sops:' "$f" || viol 4 "$f:1" "missing the sops block (not encrypted)"
  grep -qE 'recipient: age1[a-z0-9]+' "$f" || viol 4 "$f:1" "no age recipient entry"
done
if [[ -f "$root/.sops.yaml" ]]; then
  recipient="$(yq -r '.creation_rules[0].age // ""' "$root/.sops.yaml" 2>/dev/null)"
  if [[ "$recipient" == PLACEHOLDER* ]]; then
    [[ -f "$root/secrets/secrets.sops.yaml" ]] && viol 4 "$root/.sops.yaml:1" "placeholder recipient but an encrypted bundle exists"
  elif ! [[ "$recipient" =~ ^age1[a-z0-9]{58}$ ]]; then
    viol 4 "$root/.sops.yaml:1" "recipient is not an age public key"
  fi
else
  viol 4 "$root/.sops.yaml:1" "missing"
fi

# ------------------------------------------------------------------ rule 5 ----
dec="$root/DECISIONS.md"
if [[ ! -f "$dec" ]]; then
  viol 5 "$dec:1" "missing"
else
  count="$(grep -c '^ANSWER:' "$dec" || true)"
  [[ "$count" == 4 ]] || viol 5 "$dec:1" "expected four ANSWER lines, found $count"
  if ((require)) && grep -q '^ANSWER: DEFAULT' "$dec"; then
    viol 5 "$dec:1" "a decision is still DEFAULT (--require-decisions)"
  fi
fi

# ------------------------------------------------------------------ rule 6 ----
for f in "$root"/patches/volumes-*.yaml; do
  [[ -f "$f" ]] || continue
  # Every media selector must exclude the system disk.
  if grep -nE 'match:.*disk\.size' "$f" | grep -vF 'system_disk' | grep -q .; then
    viol 6 "$f:1" "a size-band disk selector does not mention system_disk"
  fi
done
if [[ -f "$root/patches/tailscale.yaml" ]] && grep -qE 'TS_AUTHKEY|tskey-' "$root/patches/tailscale.yaml"; then
  viol 6 "$root/patches/tailscale.yaml:1" "the CI Tailscale patch must not hold an auth key"
fi
for f in "$root"/secrets/tailscale-*.sops.yaml; do
  [[ -f "$f" ]] || continue
  grep -q '^sops:' "$f" || viol 6 "$f:1" "missing the sops block (not encrypted)"
done

if ((bad)); then
  exit 1
fi
echo "OK: talos config guard"
