# shellcheck shell=bash
# Shared guards for the backup and restore scripts in talos/dr/.
# Sourced, never executed. Plan 15-06.
#
# Exit codes used by every script that sources this file:
#   1 usage or unexpected failure, 3 refused (wrong context), 4 refused (target exists),
#   5 precondition not met (backup not Completed, tool missing).

TALOS_CI_CONTEXT_PREFIX="admin@talos-ci"

dr_die() {
  local code="$1"
  shift
  echo "$*" >&2
  exit "$code"
}

dr_need() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || dr_die 5 "missing tool: $t"
  done
}

# dr_guard_context MODE LIVE_CONTEXT
#   MODE is "ci" or "live" (from --ci / --live CONTEXT).
#   ci   : the current kubectl context must be admin@talos-ci (or admin@talos-ci-<n>).
#   live : the context typed after --live must equal the current context exactly.
# Prints the context it accepted. Never prints cluster contents.
dr_guard_context() {
  local mode="${1:-}" typed="${2:-}" current
  current="$(kubectl config current-context 2>/dev/null || true)"
  [[ -n "$current" ]] || dr_die 3 "refused: no current kubectl context"
  case "$mode" in
    ci)
      case "$current" in
        "$TALOS_CI_CONTEXT_PREFIX" | "$TALOS_CI_CONTEXT_PREFIX"-*) ;;
        *) dr_die 3 "refused: --ci only runs against the Talos CI context (current context is not it)" ;;
      esac
      ;;
    live)
      [[ -n "$typed" ]] || dr_die 3 "refused: --live needs the context typed back"
      [[ "$typed" == "$current" ]] || dr_die 3 "refused: typed context does not match the current context"
      ;;
    *) dr_die 3 "refused: choose --ci or --live CONTEXT" ;;
  esac
  echo "context ok: $current"
}
