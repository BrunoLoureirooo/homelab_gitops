#!/usr/bin/env bash
# Talos-specific no-secrets sweep (plan 15-09 Task 3, R21 adapted). Complements
# check-talos.sh (which looks inside talos/) by judging the WHOLE tracked tree.
# Prints `TALOS-SECRETS <rule> <file> <reason>` per problem (never the matched
# value) and exits 1:
#   a  a tracked file with a secret-bearing name: secrets.yaml, talosconfig,
#      controlplane.yaml, worker.yaml, kubeconfig*, *.agekey, age.key, keys.txt
#      (talos/patches/controlplane.yaml and worker.yaml are role patches, allowed;
#       encrypted *.sops.yaml files are allowed)
#   b  a talos/**/*.sops.yaml without its top-level `sops:` metadata block
#   c  a tracked file with an age private key marker, a Tailscale auth key, a
#      PEM private key block or a Talos bootstrap token (the guard scripts that
#      spell the patterns out are skipped)
#   d  talos/.gitignore does not ignore out/ and local/ (where rendered configs and
#      local answers live)
#   e  a workflow that echoes a secrets context, or enables set -x in a file that
#      uses secrets
#
# Env: TS_ROOT (repository root, default: this repository) and TS_FILELIST (a file
# with one tracked path per line) replace the git listing, for the self-test.
set -uo pipefail

root="${TS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$root" || exit 2

list="$(mktemp)"
trap 'rm -f "$list"' EXIT
if [[ -n "${TS_FILELIST:-}" ]]; then
  cp "$TS_FILELIST" "$list"
else
  git ls-files >"$list"
fi

bad=0
viol() { # viol <rule> <file> <reason>
  echo "TALOS-SECRETS $1 $2 $3"
  bad=1
}

# The marker strings are assembled so this script never contains them literally.
age_marker="AGE-SECRET-""KEY-"
ts_marker="tskey""-(auth|client|api)-[A-Za-z0-9]{6,}"
pem_marker="-----BEGIN ""[A-Z ]*PRIVATE KEY"

while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  base="$(basename "$f")"
  case "$f" in
    talos/patches/controlplane.yaml | talos/patches/worker.yaml) ;;
    argocd/apps/*) ;; # Argo CD Applications, one of which is named secrets.yaml
    *.sops.yaml) ;;
    *)
      case "$base" in
        secrets.yaml | talosconfig | controlplane.yaml | worker.yaml | kubeconfig* | *.agekey | age.key | keys.txt)
          viol a "$f" "secret-bearing file name is tracked"
          ;;
      esac
      ;;
  esac
  case "$f" in
    talos/.sops.yaml | talos/*/.sops.yaml) ;; # the SOPS configuration, not an encrypted file
    talos/*.sops.yaml)
      grep -qE '^sops:' "$f" || viol b "$f" "SOPS file without its sops: metadata block"
      ;;
  esac
  case "$f" in
    .github/scripts/check-*.sh) continue ;;
  esac
  if grep -qIE "$age_marker|$ts_marker|$pem_marker" "$f" 2>/dev/null; then
    viol c "$f" "key or token marker found"
  fi
  if grep -qIE '(^|[^A-Za-z0-9])token:[[:space:]]*[a-z0-9]{6}\.[a-z0-9]{16}([^a-z0-9]|$)' "$f" 2>/dev/null; then
    viol c "$f" "Talos bootstrap token shape found"
  fi
done <"$list"

if [[ -f talos/.gitignore ]]; then
  for need in out/ local/; do
    grep -qxF "$need" talos/.gitignore || viol d talos/.gitignore "does not ignore $need"
  done
fi

while IFS= read -r w; do
  [[ -f "$w" ]] || continue
  if grep -nE 'echo[^#]*\$\{\{[[:space:]]*secrets\.' "$w" >/dev/null 2>&1; then
    viol e "$w" "echoes a secrets context"
  fi
  if grep -qE 'secrets\.' "$w" && grep -qE '^[[:space:]]*(run:.*)?set[[:space:]]+-[a-z]*x' "$w"; then
    viol e "$w" "set -x in a workflow that uses secrets"
  fi
done < <(grep -E '^\.github/workflows/.*\.ya?ml$' "$list")

if ((bad)); then exit 1; fi
echo "OK: talos secrets sweep"
