#!/usr/bin/env bash
# talos-job: kvm=no timeout=10
# The SOPS+age secrets path of render.sh with throwaway keys: encrypt a bundle
# and a Tailscale service config, render through the real `sops -d` code path,
# validate the result, and prove no plaintext bundle is left behind. A render
# without the age key must fail (negative control).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TAL_NEEDS_KVM=no
# shellcheck source=talos/test/lib.sh
. "$here/../lib.sh"

tal_prepare_runner
tal_install_sops_age

key="$TAL_WORK/age-key.txt"
age-keygen -o "$key" >/dev/null 2>&1
recipient="$(age-keygen -y "$key")"

sdir="$TAL_WORK/secrets"
tdir="$TAL_WORK/tmp"
mkdir -p "$sdir" "$tdir" "$TAL_WORK/plain"
talosctl gen secrets --force -o "$TAL_WORK/plain/bundle.yaml" >/dev/null
sops -e --age "$recipient" --input-type yaml --output-type yaml "$TAL_WORK/plain/bundle.yaml" >"$sdir/secrets.sops.yaml"

# A throwaway Tailscale auth key, assembled here and masked so no literal key
# shape is committed.
authkey="$(printf '%s%s%s' 'tsk' 'ey-' 'auth-ci-throwaway-0123456789')"
echo "::add-mask::$authkey"
cat >"$TAL_WORK/plain/ts.yaml" <<EOF
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: tailscale
environment:
  - TS_HOSTNAME=mini01
  - TS_AUTHKEY=$authkey
EOF
sops -e --age "$recipient" --input-type yaml --output-type yaml "$TAL_WORK/plain/ts.yaml" >"$sdir/tailscale-mini01.sops.yaml"
rm -rf "$TAL_WORK/plain"

export SOPS_AGE_KEY_FILE="$key"
TMPDIR="$tdir" TALOS_SECRETS_DIR="$sdir" bash "$TAL_ROOT/render.sh" mini01 --out "$TAL_WORK/r" >/dev/null
talosctl validate --config "$TAL_WORK/r/mini01.yaml" --mode metal
grep -q 'TS_AUTHKEY=' "$TAL_WORK/r/mini01.yaml" || tal_die "the encrypted Tailscale key was not delivered into the render"

# The plaintext bundle is removed when render.sh exits.
TMPDIR="$tdir" bash "$TAL_ROOT/render.sh" --check-secrets-clean
if find "$tdir" -name 'secrets*' | grep -q .; then
  tal_die "a plaintext secrets file was left in the render temp directory"
fi

# Negative control: without the age key the render must fail.
unset SOPS_AGE_KEY_FILE
if TMPDIR="$tdir" TALOS_SECRETS_DIR="$sdir" bash "$TAL_ROOT/render.sh" mini01 --out "$TAL_WORK/r2" >/dev/null 2>&1; then
  tal_die "render succeeded without the age key"
fi

tal_report "SOPS_ROUNDTRIP=ok"
tal_finding SOPS-ROUNDTRIP PASS "encrypted bundle and Tailscale key render, plaintext removed, render fails without the key"
