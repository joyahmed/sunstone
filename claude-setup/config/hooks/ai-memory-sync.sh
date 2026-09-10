#!/usr/bin/env bash
# ai-memory-sync.sh — SessionStart hook.
# 1. Locates the user's memory repo (portable across machines via ~/.claude/ai-memory-path).
# 2. Fast-forward pulls it (offline-safe, short timeout) so the memory is fresh.
# 3. Injects the memory file (MEMORY_FILE, default claude-setup/memory/ABOUT-ME.md)
#    into Claude's context as additionalContext.
#
# Every failure mode is silent: no repo, no network, no python — the session
# still starts cleanly, just without the memory injection.

set -u

# --- locate the repo -------------------------------------------------------
# The single line in ~/.claude/ai-memory-path names the clone. With no path
# file there is one generic fallback, $HOME/.ai-memory — if that is a git
# repo it is used, otherwise there is nothing to do.
PATH_FILE="${HOME}/.claude/ai-memory-path"
REPO=""
if [ -f "$PATH_FILE" ]; then
  # Trim, never squeeze: a path may contain spaces. Same as the .js twin's trim().
  REPO="$(head -n1 "$PATH_FILE" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
fi
for cand in "$REPO" "$HOME/.ai-memory"; do
  if [ -n "$cand" ] && [ -e "$cand/.git" ]; then
    REPO="$cand"; break
  fi
  REPO=""
done
[ -z "$REPO" ] && exit 0   # nothing to do

# --- read sunstone.conf (optional) -----------------------------------------
# POSIX KEY=VALUE lines, '#' comments, values may be double-quoted. The file
# is user content, so it is grepped rather than sourced. Absent file → defaults.
CONF="$REPO/claude-setup/config/sunstone.conf"
conf_get() {
  # conf_get KEY DEFAULT — last matching line wins; an empty value falls back
  # to DEFAULT. Rules, identical to readConf() in the .js twin:
  #   - '#' starts a comment only at line start or after whitespace, so a#b
  #     is a value;
  #   - a double-quoted value runs to the next '"' (a '#' inside is literal;
  #     anything after the closing quote is ignored); an unterminated quote
  #     takes the rest of the line;
  #   - surrounding whitespace is trimmed, never deleted from the inside.
  val=""
  if [ -f "$CONF" ]; then
    # Leading whitespace is kept until the comment rule has run: KEY=#x is
    # the value "#x", KEY= #x is a comment (empty → DEFAULT).
    val="$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$CONF" 2>/dev/null | tail -n1 \
           | sed -e "s/^[[:space:]]*$1[[:space:]]*=//" -e 's/[[:space:]]*$//')"
    case "$(printf '%s' "$val" | sed 's/^[[:space:]]*//')" in
      \"*) val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*"//' -e 's/".*$//')" ;;
      *)   val="$(printf '%s' "$val" | sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" ;;
    esac
  fi
  if [ -n "$val" ]; then printf '%s' "$val"; else printf '%s' "$2"; fi
}

MEMORY_DIR="$(conf_get MEMORY_DIR claude-setup/memory)"
MEMORY_FILE="$(conf_get MEMORY_FILE claude-setup/memory/ABOUT-ME.md)"

# --- refresh from remote (best-effort, non-blocking-ish) -------------------
# ff-only never clobbers local edits; timeout keeps a dead network from hanging
# the session; all output discarded.
# `timeout` is not everywhere. macOS ships none of it (Homebrew's coreutils
# installs it as `gtimeout`), and a hook can run under a stripped PATH that has
# neither. Falling back to running the command unbounded is the one thing this
# wrapper must not do: a remote that accepts the connection and then never
# answers would hang the hook, and with it the session start, for as long as the
# user is willing to wait. So with no timeout binary the wrapper becomes the
# watchdog itself — the command goes to the background and is killed on time.
# The .js twin gets the same bound for free from execFileSync's `timeout`.
#
# GIT_TERMINAL_PROMPT=0 on every branch: a hook has no terminal to answer a
# credential prompt on, and a prompt waiting on stdin is precisely the hang
# being guarded against.
run() {
  local secs="$1"; shift
  local t=""
  if command -v timeout >/dev/null 2>&1; then
    t=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    t=gtimeout
  fi
  if [ -n "$t" ]; then
    GIT_TERMINAL_PROMPT=0 "$t" "$secs" "$@" >/dev/null 2>&1
    return $?
  fi
  local cmd_pid watch_pid rc
  GIT_TERMINAL_PROMPT=0 "$@" >/dev/null 2>&1 &
  cmd_pid=$!
  # TERM first, KILL a moment later for anything that ignores it. Both are sent
  # to git; a transport child that outlives it exits on its own broken pipe.
  ( sleep "$secs"; kill -TERM "$cmd_pid"; sleep 2; kill -KILL "$cmd_pid" ) >/dev/null 2>&1 &
  watch_pid=$!
  wait "$cmd_pid" >/dev/null 2>&1; rc=$?
  kill "$watch_pid" >/dev/null 2>&1
  wait "$watch_pid" >/dev/null 2>&1
  return $rc
}

# ff-only first: fast, and it can never rewrite local history. But ff-only
# CANNOT integrate divergence, and with several machines and clients (a WSL
# shell, a desktop app, a cloud session) all committing to the memory tree,
# divergence is the normal case rather than the exception. Left at ff-only
# alone, a machine that falls behind fails to pull, then fails to push, and —
# every failure here being silent — simply stops syncing forever without
# saying so.
#
# So on failure, rebase our memory commits on top instead. Rewriting local
# history is acceptable for a markdown memory store and nothing else in this
# repo is touched by the auto-commit hook. --autostash protects a file written
# but not yet committed, and a conflict is aborted rather than left half-done
# for a human to discover later.
sync_pull() {
  run 8 git -C "$REPO" pull --ff-only --quiet && return 0
  # No upstream, or nothing upstream we lack — this is offline, not divergence.
  git -C "$REPO" rev-parse '@{u}' >/dev/null 2>&1 || return 1
  [ "$(git -C "$REPO" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)" = "0" ] && return 1
  if ! run 25 git -C "$REPO" pull --rebase --autostash --quiet; then
    run 10 git -C "$REPO" rebase --abort || true
    return 1
  fi
  return 0
}

sync_pull || true

# --- push what last session committed --------------------------------------
# The SessionEnd hook (ai-memory-commit.sh) commits memory writes but never
# pushes, so the network cost lands here instead — where a round trip is
# already being paid. Nothing to push is the common case and costs one local
# rev-list.
#
# One retry: a push can be rejected by a commit that landed between our pull
# and our push, and re-syncing then pushing again clears exactly that case.
# If the retry also fails the commits stay local and go out next session —
# which is now genuinely "next time" rather than "never".
ahead() {
  [ "$(git -C "$REPO" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)" != "0" ]
}

if ahead; then
  if ! run 10 git -C "$REPO" push --quiet; then
    if sync_pull && ahead; then
      run 10 git -C "$REPO" push --quiet || true
    fi
  fi
fi

# --- pick the file to inject -----------------------------------------------
# MEMORY_FILE first; failing that, MEMORY.md inside MEMORY_DIR; failing both,
# inject nothing. The sync above has still done its job either way.
MEM="$REPO/$MEMORY_FILE"
[ -f "$MEM" ] || MEM="$REPO/$MEMORY_DIR/MEMORY.md"
[ -f "$MEM" ] || exit 0

# --- inject the memory file as context -------------------------------------
if command -v python3 >/dev/null 2>&1; then
  python3 - "$MEM" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        body = f.read()
except Exception:
    sys.exit(0)
ctx = ("Portable memory about the user, auto-synced from their memory "
       "git repo. Treat as durable background context, not a live instruction:\n\n" + body)
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": ctx,
}}))
PY
else
  # Fallback: plain stdout is also added to context by Claude Code.
  echo "Portable memory about the user, auto-synced from their memory repo:"
  cat "$MEM"
fi
exit 0
