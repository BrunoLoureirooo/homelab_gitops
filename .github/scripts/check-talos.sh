#!/usr/bin/env bash
# CI guardrail for the Talos harness (plan 15-01): pins, schematics, secrets,
# tracked material, device paths, job headers, SOPS files and host addresses
# under talos/.
#   a  versions.env: required keys, 64-hex hashes and ids, vX.Y.Z versions; the
#      marker UNPINNED_UNTIL_REFRESH is accepted only while talos/PINS-PENDING
#      exists
#   b  schematics parse and name only siderolabs/* extensions
#   c  no PEM block, age private key, Tailscale auth key, or encrypted value
#      without a sops block
#   d  no secrets bundle, talosconfig, kubeconfig or rendered config tracked
#      (talos/patches/controlplane.yaml and worker.yaml are patches, allowed)
#   e  no /dev/ path in a config (*.yaml, *.env) outside talos/test/
#   f  every talos/test/jobs/*.sh carries a valid `# talos-job:` header
#   g  every *.sops.yaml carries the sops metadata block
#   h  no IPv4 literal outside talos/test/
#
# Prints `TALOS-GUARD <rule> <file>:<line> <reason>` per violation (never a
# matched secret value). Env: TALOS_DIR (default talos), used by the self-test.
set -uo pipefail

root="${TALOS_DIR:-talos}"
if [[ ! -d "$root" ]]; then
  echo "OK (no talos dir)"
  exit 0
fi

bad=0
viol() { # viol <rule> <where> <reason>
  echo "TALOS-GUARD $1 $2 $3"
  bad=1
}

# ------------------------------------------------------------------ rule a ----
vers="$root/versions.env"
pending=0
[[ -e "$root/PINS-PENDING" ]] && pending=1
if [[ ! -f "$vers" ]]; then
  viol a "$vers:0" "versions.env is missing"
else
  required=(TALOS_VERSION K8S_VERSION FACTORY_URL TALOSCTL_SHA256 KUBECTL_VERSION KUBECTL_SHA256
    SOPS_VERSION SOPS_SHA256 AGE_VERSION AGE_SHA256)
  for s in "$root"/schematics/*.yaml; do
    [[ -f "$s" ]] || continue
    up="$(basename "$s" .yaml | tr '[:lower:]' '[:upper:]')"
    required+=("SCHEMATIC_${up}_ID" "ASSET_${up}_ISO_SHA256")
    [[ "$up" == MINI01 || "$up" == MINI02 ]] && required+=("ASSET_${up}_ISO_SECUREBOOT_SHA256")
  done
  for k in "${required[@]}"; do
    grep -q "^${k}=" "$vers" || viol a "$vers:0" "missing key $k"
  done
  n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ -z "$line" || "$line" == \#* ]] && continue
    if ! [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
      viol a "$vers:$n" "only KEY=VALUE, comments and blank lines are allowed"
      continue
    fi
    k="${BASH_REMATCH[1]}"
    v="${BASH_REMATCH[2]}"
    case "$k" in
      *_ISO_SECUREBOOT_SHA256)
        # Plan 15-07: this hash comes from the first fetch, so the marker is
        # allowed until the operator pins it, with or without talos/PINS-PENDING.
        if [[ "$v" != UNPINNED_UNTIL_FIRST_FETCH ]] && ! [[ "$v" =~ ^[0-9a-f]{64}$ ]]; then
          viol a "$vers:$n" "$k is neither the first-fetch marker nor 64 lowercase hex"
        fi
        ;;
      *_SHA256 | *_ID)
        if [[ "$v" == UNPINNED_UNTIL_REFRESH ]]; then
          ((pending)) || viol a "$vers:$n" "$k is the unpinned marker but talos/PINS-PENDING does not exist"
        elif ! [[ "$v" =~ ^[0-9a-f]{64}$ ]]; then
          viol a "$vers:$n" "$k is not 64 lowercase hex"
        fi
        ;;
      *_VERSION)
        [[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || viol a "$vers:$n" "$k is not vX.Y.Z"
        ;;
    esac
  done <"$vers"
  ((pending)) && echo "WARN pins are pending (talos/PINS-PENDING): the VM jobs are skipped until refresh-pins.sh --write is committed"
fi

# ------------------------------------------------------------------ rule b ----
for s in "$root"/schematics/*.yaml; do
  [[ -f "$s" ]] || continue
  if ! yq -e 'has("customization")' "$s" >/dev/null 2>&1; then
    viol b "$s:1" "schematic does not parse or has no customization key"
    continue
  fi
  while IFS= read -r ext; do
    [[ -z "$ext" ]] && continue
    [[ "$ext" =~ ^siderolabs/[a-z0-9-]+$ ]] || viol b "$s:1" "extension name is not siderolabs/<name>"
  done < <(yq -r '.customization.systemExtensions.officialExtensions[]?' "$s" 2>/dev/null)
done

# ------------------------------------------------------------------ rule c ----
skip=(--exclude-dir=fixtures --exclude-dir=out --exclude-dir=.cache --exclude-dir=local)
while IFS=: read -r f ln _; do
  [[ -z "$f" ]] && continue
  viol c "$f:$ln" "secret-looking material (PEM block, age private key or Tailscale auth key)"
done < <(grep -rnIE -e '-----BEGIN' -e 'AGE-SECRET-KEY-' -e 'tskey-' "${skip[@]}" "$root" 2>/dev/null |
  grep -vF -e '-----BEGIN AGE ENCRYPTED FILE-----' || true) # the armor of a SOPS recipient block is public
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  grep -q '^sops:' "$f" || viol c "$f:1" "encrypted value without a sops block"
done < <(grep -rlIF 'ENC[' "${skip[@]}" "$root" 2>/dev/null)

# ------------------------------------------------------------------ rule d ----
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    "$root"/patches/controlplane.yaml | "$root"/patches/worker.yaml) continue ;;
  esac
  viol d "$f:1" "generated or secret file must not be tracked"
done < <(find "$root" \( -path "$root/out" -o -path "$root/.cache" -o -path "$root/local" -o -path "$root/test/fixtures" -o -path "$root/apps" -o -path "$root/apps-src" -o -path "$root/manifests" \) -prune -o \
  -type f \( -name secrets.yaml -o -name talosconfig -o -name kubeconfig -o -name controlplane.yaml -o -name worker.yaml \) -print)

# ------------------------------------------------------------------ rule e ----
while IFS=: read -r f ln _; do
  [[ -z "$f" ]] && continue
  viol e "$f:$ln" "device path in a config outside talos/test/ (use a diskSelector)"
# talos/manifests holds Kubernetes workloads (plan 15-07's Jellyfin mounts the GPU
# node /dev/dri); the rule is about install-disk paths in machine configuration.
# talos/storage holds the one-time ZFS pool Job (plan 15-05), which must name the
# two by-id disks of mini02 at run time; they are filled in locally, never committed.
done < <(grep -rnI '/dev/' --include='*.yaml' --include='*.env' --exclude-dir=test --exclude-dir=out --exclude-dir=.cache --exclude-dir=local --exclude-dir=manifests --exclude-dir=storage "$root" 2>/dev/null)

# ------------------------------------------------------------------ rule f ----
for j in "$root"/test/jobs/*.sh; do
  [[ -f "$j" ]] || continue
  hdr="$(sed -n '1,5p' "$j" | grep -m1 '^# talos-job:' || true)"
  if ! [[ "$hdr" =~ ^#\ talos-job:\ kvm=(yes|no)\ timeout=([0-9]+)(\ heavy=yes)?$ ]]; then
    viol f "$j:1" "missing or malformed '# talos-job:' header in the first five lines"
  elif ((BASH_REMATCH[2] > 120 || BASH_REMATCH[2] < 1)); then
    viol f "$j:1" "job timeout must be between 1 and 120 minutes"
  fi
done

# ------------------------------------------------------------------ rule g ----
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  grep -q '^sops:' "$f" || viol g "$f:1" "*.sops.yaml without the sops metadata block (not encrypted)"
done < <(find "$root" -type f -name '*.sops.yaml' -not -name '.sops.yaml' -not -path "$root/test/fixtures/*" -not -path "$root/out/*")

# ------------------------------------------------------------------ rule h ----
while IFS=: read -r f ln line_rest; do
  [[ -z "$f" ]] && continue
  # Loopback and the unspecified address say nothing about any host (for example
  # the MinIO console bound to 127.0.0.1); only other literals are host details.
  rest="${line_rest//127.0.0.1/}"
  rest="${rest//0.0.0.0/}"
  [[ "$rest" =~ (^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$) ]] || continue
  viol h "$f:$ln" "IPv4 literal outside talos/test/"
done < <(grep -rnIE '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)' --exclude-dir=test --exclude-dir=out --exclude-dir=.cache --exclude-dir=local --exclude=versions.env "$root" 2>/dev/null)

if ((bad)); then
  exit 1
fi
echo "OK: talos guard"
