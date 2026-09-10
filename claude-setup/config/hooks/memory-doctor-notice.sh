#!/usr/bin/env bash
# memory-doctor-notice.sh — SessionStart hook.
#
# Nobody runs memory-doctor by hand. A maintenance chore that depends on a
# person remembering it is a chore that never happens — so the system raises
# it instead.
#
# Runs the doctor in --brief mode and injects at most ONE line of context. It is
# deliberately quiet:
#   - nothing is printed when the stores are drained and the wiring is sound,
#     so this goes silent for good once the work is done rather than becoming
#     wallpaper;
#   - at most one notice per THROTTLE_HOURS, so it does not repeat inside a day
#     of back-to-back sessions;
#   - every failure mode is silent — no framework checkout, no node, no
#     network: the session starts clean, just without the notice.
#
# Disable with:  touch ~/.claude/.memory-doctor-off

set -u

[ -f "${HOME}/.claude/.memory-doctor-off" ] && exit 0

THROTTLE_HOURS=20
STAMP="${HOME}/.claude/.memory-doctor-last"

# --- throttle --------------------------------------------------------------
if [ -f "$STAMP" ]; then
  last=$(cat "$STAMP" 2>/dev/null || echo 0)
  now=$(date +%s)
  case "$last" in (*[!0-9]*|'') last=0 ;; esac
  [ $(( now - last )) -lt $(( THROTTLE_HOURS * 3600 )) ] && exit 0
fi

# --- locate the framework checkout -----------------------------------------
# memory-doctor.js lives in the sunstone framework, not in the user's memory
# repo, and this hook is COPIED to ~/.claude/hooks/ by setup, so its own
# location normally says nothing. The doctor also resolves the framework from
# its own __dirname (for the wiring check), so it cannot simply be copied next
# to this hook — the framework checkout has to be found. Resolution order:
#   1. ~/.claude/sunstone-path — one line, the framework clone. setup.sh
#      should write this; it is the only route that survives every layout.
#   2. this hook's own location, symlinks resolved, for a checkout that runs
#      the hook in place (<framework>/claude-setup/config/hooks/ → <framework>).
#   3. the memory repo from ~/.claude/ai-memory-path (or $HOME/.ai-memory):
#      first the repo itself, for the layout where the memory repo is a
#      framework checkout. Then, as a pure convenience guess, a sibling
#      directory named sunstone — for users who keep their clones side by
#      side. setup.sh does NOT create that layout (it clones the memory repo
#      into ~/.ai-memory by default), so nothing relies on this guess.
# Every candidate is verified by the presence of memory-doctor.js; a wrong
# guess costs nothing.
DOCTOR_REL="claude-setup/scripts/memory-doctor.js"
FRAMEWORK=""
cands=""
if [ -f "${HOME}/.claude/sunstone-path" ]; then
  # Trim, never squeeze: a path may contain spaces.
  cands="$(head -n1 "${HOME}/.claude/sunstone-path" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
fi
self="$0"
if command -v readlink >/dev/null 2>&1; then
  resolved="$(readlink -f "$0" 2>/dev/null)" && [ -n "$resolved" ] && self="$resolved"
fi
self_dir="$(cd "$(dirname "$self")" 2>/dev/null && pwd -P)" || self_dir=""
[ -n "$self_dir" ] && cands="$cands
$(cd "$self_dir/../../.." 2>/dev/null && pwd -P)"
MEMORY_REPO=""
if [ -f "${HOME}/.claude/ai-memory-path" ]; then
  MEMORY_REPO="$(head -n1 "${HOME}/.claude/ai-memory-path" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
fi
[ -z "$MEMORY_REPO" ] && [ -d "$HOME/.ai-memory/.git" ] && MEMORY_REPO="$HOME/.ai-memory"
if [ -n "$MEMORY_REPO" ]; then
  cands="$cands
$MEMORY_REPO
$(dirname "$MEMORY_REPO")/sunstone"
fi

while IFS= read -r cand; do
  if [ -n "$cand" ] && [ -f "$cand/$DOCTOR_REL" ]; then
    FRAMEWORK="$cand"; break
  fi
done <<EOC
$cands
EOC
[ -z "$FRAMEWORK" ] && exit 0

# --- find a node -----------------------------------------------------------
# `node` is often an nvm lazy-load shell function in the user's interactive
# shell, which does not exist in a hook's non-interactive shell. Resolve a real
# binary or give up quietly.
#
# ⚠️ Order matters, and a bare `$HOME/.nvm/versions/node/*/bin/node` glob gets
# it wrong: it yields the LEXICALLY first install, i.e. the oldest-sorting one,
# which on a machine that keeps several nvm versions is rarely the one the user
# runs and may be a half-removed install that no longer executes. When that
# happens the doctor produces nothing, the hook says nothing, and — no notice
# means no stamp — it repeats every single session. So ask nvm which version it
# considers the default, then take the newest, and only fall back to the raw
# glob (for a `sort` without -V) once the system paths have had their turn.
NVM_ROOT="${NVM_DIR:-$HOME/.nvm}"
NVM_DEFAULT=""
alias_val="$(head -n1 "$NVM_ROOT/alias/default" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
# `alias/default` holds either a version ("v22.1.0") or the name of another
# alias ("lts/jod"), which is itself a file holding the version. One
# indirection covers every layout nvm writes; anything else simply misses and
# the next candidate is tried.
case "${alias_val:-}" in
  v[0-9]*|[0-9]*) ;;
  ?*) alias_val="$(head -n1 "$NVM_ROOT/alias/$alias_val" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" ;;
esac
case "${alias_val:-}" in
  v[0-9]*|[0-9]*) NVM_DEFAULT="$NVM_ROOT/versions/node/v${alias_val#v}/bin/node" ;;
esac
# printf, not `ls`: the glob is already expanded by the shell, and with no
# match printf echoes the pattern unchanged — which then fails the -x test
# below like any other miss. A `sort` without -V leaves this empty, and the
# raw glob at the end of the list still covers that machine.
NVM_NEWEST="$(printf '%s\n' "$NVM_ROOT/versions/node/"*/bin/node 2>/dev/null | sort -V 2>/dev/null | tail -n1)"

NODE=""
for c in "$(command -v node 2>/dev/null)" \
         "$NVM_DEFAULT" "$NVM_NEWEST" \
         /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node \
         "$NVM_ROOT/versions/node/"*/bin/node; do
  [ -n "${c:-}" ] && [ -x "$c" ] && NODE="$c" && break
done
[ -z "$NODE" ] && exit 0

# --- ask the doctor for one line ------------------------------------------
LINE="$("$NODE" "$FRAMEWORK/$DOCTOR_REL" --brief 2>/dev/null)"
[ -z "$LINE" ] && exit 0   # drained and healthy — say nothing, record nothing

date +%s > "$STAMP" 2>/dev/null || true

if command -v python3 >/dev/null 2>&1; then
  python3 - "$LINE" <<'PY'
import json, sys
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Memory-system status (from memory-doctor, injected automatically so "
                         "nobody has to remember to run it):\n\n" + sys.argv[1],
}}))
PY
else
  echo "Memory-system status (from memory-doctor): $LINE"
fi
exit 0
