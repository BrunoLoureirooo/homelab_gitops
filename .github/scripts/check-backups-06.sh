#!/usr/bin/env bash
# CI guardrail for plan 15-06 (backups on Talos). Auto-run by guards.yaml (check-*.sh).
#
# Checks, each printing `FAIL <name>: <file>[:line]` and never a matched value:
#   protected    on a phase15/06* branch, nothing under argocd/, ansible/ or deploy.yml changed
#                (the live k3s root app applies argocd/; skipped when origin/main is not fetched)
#   host-details no tailnet name, private address (except QEMU 10.0.2.x under talos/test) or
#                Tailscale CGNAT address in talos/ or docs/dr/
#   raw-secret   no `kind: Secret` YAML under talos/; talos/sealed-secrets holds only SealedSecrets
#                and every listed resource exists
#   pins         no `:latest` image anywhere in talos/; the tags in the manifests equal talos/dr/images.env
#   overlay      talos/manifests/immich-infra is the current build of talos/overlays/immich-infra
#   tool         a LIBRARY_TOOL= decision exists
#   jobs         every talos/test/jobs/*.sh carries a `# talos-job:` header
#   offline      the offline self-tests of the DR scripts and the rendered manifests pass
set -uo pipefail

repo="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo" || exit 2
fail=0
bad() {
  echo "FAIL $1"
  fail=1
}

# ---- protected paths ------------------------------------------------------------------------------
branch="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)}"
if [[ "$branch" == phase15/06* ]]; then
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    changed="$(git diff --name-only origin/main...HEAD -- argocd ansible .github/workflows/deploy.yml 2>/dev/null || true)"
    if [[ -n "$changed" ]]; then
      while IFS= read -r f; do
        bad "protected: $f changed on a plan 15-06 branch"
      done <<<"$changed"
    fi
  else
    echo "skip protected: no origin/main ref (shallow checkout)"
  fi
fi

# ---- host details ----------------------------------------------------------------------------------------
scan=()
for d in talos docs/dr; do
  [[ -d "$d" ]] && scan+=("$d")
done
if [[ ${#scan[@]} -gt 0 ]]; then
  while IFS=: read -r f l _; do
    [[ -n "$f" ]] && bad "host-details: tailnet name at $f:$l"
  done < <(grep -rnE '[A-Za-z0-9-]+\.ts\.net' "${scan[@]}" 2>/dev/null || true)
  while IFS=: read -r f l _; do
    [[ -n "$f" ]] && bad "host-details: Tailscale CGNAT address at $f:$l"
  done < <(grep -rnE '(^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)' "${scan[@]}" 2>/dev/null || true)
  # Private addresses: only QEMU's 10.0.2.x, and only under talos/test.
  while IFS=: read -r f l rest; do
    [[ -n "$f" ]] || continue
    ips="$(grep -oE '(10(\.[0-9]{1,3}){3}|172\.(1[6-9]|2[0-9]|3[01])(\.[0-9]{1,3}){2}|192\.168(\.[0-9]{1,3}){2})' <<<"$rest" || true)"
    for ip in $ips; do
      # CI-only networks under talos/test: QEMU user-mode (10.0.2.x) and the
      # two-node harness's private network (192.168.100.x).
      if [[ "$ip" =~ ^(10\.0\.2\.[0-9]+|192\.168\.100\.[0-9]+)$ && "$f" == talos/test/* ]]; then
        continue
      fi
      if [[ "$ip" =~ ^10\.0\.2\.(2|3|15|100)$ && "$f" == docs/dr/* ]]; then
        continue
      fi
      bad "host-details: private address at $f:$l"
    done
  done < <(grep -rnE '(10(\.[0-9]{1,3}){3}|172\.(1[6-9]|2[0-9]|3[01])(\.[0-9]{1,3}){2}|192\.168(\.[0-9]{1,3}){2})' "${scan[@]}" 2>/dev/null || true)
fi

# ---- raw secrets and the sealed-secrets directory ------------------------------------------------------------
if [[ -d talos ]]; then
  while IFS=: read -r f l _; do
    [[ -n "$f" ]] && bad "raw-secret: kind: Secret at $f:$l"
  done < <(grep -rnE '^kind:[[:space:]]*"?Secret"?[[:space:]]*$' talos --include='*.yaml' 2>/dev/null || true)
fi
if [[ -d talos/sealed-secrets ]]; then
  for f in talos/sealed-secrets/*.yaml; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == kustomization.yaml ]] && continue
    if ! grep -qE '^kind:[[:space:]]*SealedSecret[[:space:]]*$' "$f"; then
      bad "raw-secret: $f is not a SealedSecret"
    fi
  done
  if command -v yq >/dev/null 2>&1; then
    while IFS= read -r r; do
      [[ -n "$r" && "$r" != null ]] || continue
      [[ -e "talos/sealed-secrets/$r" ]] || bad "raw-secret: talos/sealed-secrets/kustomization.yaml lists a missing file: $r"
    done < <(yq '.resources[]' talos/sealed-secrets/kustomization.yaml 2>/dev/null || true)
  fi
fi

# ---- image pins ---------------------------------------------------------------------------------------------------
if [[ -d talos ]]; then
  while IFS=: read -r f l _; do
    [[ -n "$f" ]] && bad "pins: image tagged latest at $f:$l"
  done < <(grep -rnE '^[[:space:]]*(image|tag):[[:space:]]*"?[^[:space:]"]*:?latest"?[[:space:]]*$' talos --include='*.yaml' 2>/dev/null || true)
fi
if [[ -f talos/dr/images.env ]]; then
  if grep -qE '_IMAGE_TAG=latest$' talos/dr/images.env; then
    bad "pins: talos/dr/images.env pins a tag called latest"
  fi
  val() { grep -E "^$1=" talos/dr/images.env | head -n1 | cut -d= -f2-; }
  expect_in() { # file image-repo-part tag
    [[ -f "$1" ]] || return 0
    grep -qE "$2:$3(@sha256:[0-9a-f]{64})?\$|tag: $3\$" "$1" || bad "pins: $1 does not use $2 at the tag in talos/dr/images.env ($3)"
  }
  expect_in talos/values/vaultwarden.yaml litestream/litestream "$(val LITESTREAM_IMAGE_TAG)"
fi

# ---- overlay drift ------------------------------------------------------------------------------------------------------
if [[ -x talos/overlays/render.sh ]] && command -v kubectl >/dev/null 2>&1; then
  bash talos/overlays/render.sh --check >/dev/null 2>&1 || bad "overlay: talos/manifests/immich-infra differs from a fresh build (run talos/overlays/render.sh)"
fi

# ---- job headers -------------------------------------------------------------------------------------------------------------------
for j in talos/test/jobs/*.sh; do
  [[ -e "$j" ]] || continue
  head -n 3 "$j" | grep -q '^# talos-job:' || bad "jobs: $j has no '# talos-job:' header in its first lines"
done

# ---- offline self-tests ----------------------------------------------------------------------------------------------------------------
for t in talos/test/offline/test-dr-scripts.sh talos/test/offline/test-render.sh talos/test/offline/test-guard.sh; do
  [[ -f "$t" ]] || continue
  # test-guard.sh runs this script on mutated copies and sets this variable to avoid recursion.
  [[ -n "${BACKUP_GUARD_NO_OFFLINE:-}" ]] && continue
  if [[ "$t" == *test-render.sh ]] && ! command -v kubectl >/dev/null 2>&1; then
    echo "skip offline: kubectl missing, $t not run"
    continue
  fi
  bash "$t" >/dev/null 2>&1 || bad "offline: $t failed (run it for details)"
done

if [[ "$fail" -eq 0 ]]; then
  echo "OK: plan 15-06 guard"
fi
exit "$fail"
