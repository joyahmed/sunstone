#!/usr/bin/env bash
# drift-notice.sh - SessionStart hook. Runs drift-check.sh and injects its
# findings into context ONLY when something is flagged, so drift is visible
# the moment a session opens instead of discovered a week later by someone
# who happened to run the script by hand.
#
# NEVER BLOCKS, NEVER FAILS A SESSION START. Every failure mode - no framework
# checkout found, no bash, the check itself erroring - falls through to exit 0
# with nothing printed. A drift report is a courtesy, not a gate; a session
# must never fail to open because a diagnostic hook had a bad day.
#
# QUIET WHEN CLEAN, ON PURPOSE. drift-check.sh's own exit code says it best:
# 0 = clean, 1 = something flagged. Only the second case has anything worth a
# session's attention, and printing "all clean" every single time is exactly
# how a notice gets ignored (see memory-doctor-notice.sh, same reasoning).
#
# NOT THROTTLED BY TIME - measured, not assumed: drift-check.sh runs local
# file/readlink comparisons only (no network, no git fetch) and completes in
# well under a second on this machine. A calendar throttle would trade "the
# moment a session opens" for a cache that goes stale, for no measured
# benefit. What IS bounded is wall-clock PER RUN (see run()), because "fast
# today" is not a promise about every machine or every future check.
#
# Escape hatches:
#   DRIFT_NOTICE=off ...                  one shell, this session only
#   DRIFT_NOTICE=warn in sunstone.conf     the fleet, flipped by one line
# There is no "block" value - this hook only ever reports, never gates, so a
# block mode would be a lie the moment someone configured it.

set -u

case "${DRIFT_NOTICE:-}" in
  off | OFF | none | NONE | 0) exit 0 ;;
esac

# --- locate the framework checkout ------------------------------------------
# Same resolution order as memory-doctor-notice.sh: the recorded framework
# path, this hook's own location (a checkout running the hook in place), then
# the memory repo and a sibling directory named sunstone. Every candidate is
# verified by the presence of the script this hook actually needs.
CHECK_REL="claude-setup/scripts/drift-check.sh"
FRAMEWORK=""

try_cand() {
  [ -n "$1" ] && [ -f "$1/$CHECK_REL" ] && FRAMEWORK="$1"
}

if [ -f "${HOME}/.claude/sunstone-path" ]; then
  cand="$(head -n1 "${HOME}/.claude/sunstone-path" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  try_cand "$cand"
fi

if [ -z "$FRAMEWORK" ]; then
  self="$0"
  if command -v readlink >/dev/null 2>&1; then
    resolved="$(readlink -f "$0" 2>/dev/null)" && [ -n "$resolved" ] && self="$resolved"
  fi
  self_dir="$(cd "$(dirname "$self")" 2>/dev/null && pwd -P)" || self_dir=""
  [ -n "$self_dir" ] && try_cand "$(cd "$self_dir/../../.." 2>/dev/null && pwd -P)"
fi

if [ -z "$FRAMEWORK" ] && [ -f "${HOME}/.claude/ai-memory-path" ]; then
  MEMORY_REPO="$(head -n1 "${HOME}/.claude/ai-memory-path" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -n "$MEMORY_REPO" ] && try_cand "$MEMORY_REPO"
  [ -z "$FRAMEWORK" ] && [ -n "$MEMORY_REPO" ] && try_cand "$(dirname "$MEMORY_REPO")/sunstone"
fi

[ -z "$FRAMEWORK" ] && exit 0
[ -x "$(command -v bash 2>/dev/null)" ] || exit 0

# --- run it, bounded --------------------------------------------------------
OUT=""
RC=0
if command -v timeout >/dev/null 2>&1; then
  OUT=$(timeout 10 bash "$FRAMEWORK/$CHECK_REL" 2>&1); RC=$?
elif command -v gtimeout >/dev/null 2>&1; then
  OUT=$(gtimeout 10 bash "$FRAMEWORK/$CHECK_REL" 2>&1); RC=$?
else
  OUT=$(bash "$FRAMEWORK/$CHECK_REL" 2>&1); RC=$?
fi

[ "$RC" = "0" ] && exit 0   # clean - say nothing
[ -z "$OUT" ] && exit 0     # errored with no output to show - nothing to say either

# Only the flagged lines (those drift-check prefixed with "  ! ") plus the
# summary, so the notice stays short even when the report is long.
FLAGGED=$(printf '%s\n' "$OUT" | grep -E '^  ! ')
SUMMARY=$(printf '%s\n' "$OUT" | tail -n1)
[ -z "$FLAGGED" ] && FLAGGED="(no individual lines flagged - see summary)"

MSG="Config drift (from drift-check.sh, injected automatically):

${FLAGGED}

${SUMMARY}

Fix: re-run setup, or read claude-setup/scripts/drift-check.sh --help in the framework checkout."

if command -v python3 >/dev/null 2>&1; then
  python3 - "$MSG" <<'PY'
import json, sys
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": sys.argv[1],
}}))
PY
else
  printf '%s\n' "$MSG"
fi
exit 0
