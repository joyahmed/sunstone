#!/usr/bin/env bash
# ai-memory-sync.sh - SessionStart hook.
# 1. Locates the user's memory repo (portable across machines via ~/.claude/ai-memory-path).
# 2. Fast-forward pulls it (offline-safe, short timeout) so the memory is fresh.
# 3. Runs the memory repo's claude-setup/session-start.d/*.sh, if any, and
#    injects the memory file (MEMORY_FILE, default claude-setup/memory/ABOUT-ME.md)
#    plus whatever those scripts printed into Claude's context as additionalContext.
#
# No failure mode is ever FATAL: no repo, no network, no python, no timeout
# binary - the session still starts cleanly, just without the memory injection.
# But "not fatal" is not "not said". Being OFFLINE is quiet and marks the
# injected memory as possibly stale; every OTHER failure is REPORTED into the
# session with git's own error and the exact command that fixes it, because a
# memory layer that silently serves last week's beliefs is worse than one that
# says "I could not update".

set -u

# --- how a problem reaches the session -------------------------------------
# This hook's ONE channel into the session is stdout: the JSON at the bottom
# carries additionalContext, and bare stdout is added to context too. A report
# about the sync therefore has to ride in that same channel or it reaches
# nobody - a hook's stderr goes to a log no session reads.
#
# SYNC_WARN is that report, and it is EMPTY on a healthy machine BY CONTRACT: a
# notice that prints on every start is scrolled past within a day, and then the
# one start where it mattered is scrolled past with it.
SYNC_WARN=""

# emit_warn_only - print SYNC_WARN as context and exit, for the early returns
# that have no memory file to inject. Structured when python3 is here, plain
# text when it is not; never fatal either way.
emit_warn_only() {
  [ -n "$SYNC_WARN" ] || exit 0
  export SYNC_WARN
  if command -v python3 >/dev/null 2>&1; then
    python3 - 2>/dev/null <<'PY' && exit 0
import json, os
w = os.environ.get("SYNC_WARN", "").strip()
if not w:
    raise SystemExit(1)
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "WARNING - " + w,
}}))
PY
  fi
  printf 'WARNING - %s\n' "$SYNC_WARN"
  exit 0
}

# --- locate the repo -------------------------------------------------------
# The single line in ~/.claude/ai-memory-path names the clone. With no path
# file there is one generic fallback, $HOME/.ai-memory - if that is a git
# repo it is used, otherwise there is nothing to do.
PATH_FILE="${HOME}/.claude/ai-memory-path"
REPO=""
NAMED=""
if [ -f "$PATH_FILE" ]; then
  # Trim, never squeeze: a path may contain spaces. Same as the .js twin's trim().
  NAMED="$(head -n1 "$PATH_FILE" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  REPO="$NAMED"
fi
for cand in "$REPO" "$HOME/.ai-memory"; do
  if [ -n "$cand" ] && [ -e "$cand/.git" ]; then
    REPO="$cand"; break
  fi
  REPO=""
done
# ⚠️ "this machine has no memory repo" and "the memory repo is somewhere this
# machine cannot look" are DIFFERENT answers, and only the first may be silent.
# ~/.claude/ai-memory-path is per-machine and routinely holds another machine's
# path - a Windows C:/Users/<name>/... under Linux, a drive that is not mounted -
# and in that state this hook used to exit 0, indistinguishable from a box that
# simply has no memory repo. It is neither "missing" nor "offline": it is CANNOT
# VERIFY, and a session about to run without the user's memory has to be told
# which of the three it is.
if [ -z "$REPO" ] && [ -n "$NAMED" ]; then
  why="it exists but is not a git repository"
  case "$NAMED" in
    [A-Za-z]:[/\\]*|//*|\\\\*)
      why="it is another platform's path (a Windows or UNC path this OS cannot open)" ;;
    *) [ -d "$NAMED" ] || why="there is no such directory on this machine" ;;
  esac
  SYNC_WARN="MEMORY SYNC COULD NOT BE VERIFIED - ~/.claude/ai-memory-path names \"$NAMED\" but $why, so the memory repo could not be read, refreshed or checked. This is NOT \"no memory\" and NOT offline: the path is most likely another machine's. Fix it by writing THIS machine's clone path into ~/.claude/ai-memory-path. No memory was injected this session."
  emit_warn_only
fi
[ -z "$REPO" ] && exit 0   # genuinely nothing to do: no path file, no fallback clone

# --- read sunstone.conf (optional) -----------------------------------------
# POSIX KEY=VALUE lines, '#' comments, values may be double-quoted. The file
# is user content, so it is grepped rather than sourced. Absent file → defaults.
CONF="$REPO/claude-setup/config/sunstone.conf"
conf_get() {
  # conf_get KEY DEFAULT - last matching line wins; an empty value falls back
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
# watchdog itself - the command goes to the background and is killed on time.
# The .js twin gets the same bound for free from execFileSync's `timeout`.
#
# GIT_TERMINAL_PROMPT=0 on every branch: a hook has no terminal to answer a
# credential prompt on, and a prompt waiting on stdin is precisely the hang
# being guarded against.
#
# ⚠️ The output is CAPTURED into RUN_OUT, not discarded. It used to go straight
# to /dev/null, and that is half of why a broken sync was indistinguishable from
# an offline one: the only evidence of WHICH failure had happened was thrown
# away before anything could classify it. It is still never printed from here -
# the caller decides whether a session needs to see it.
RUN_OUT=""
run() {
  local secs="$1"; shift
  local t=""
  RUN_OUT=""
  if command -v timeout >/dev/null 2>&1; then
    t=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    t=gtimeout
  fi
  if [ -n "$t" ]; then
    RUN_OUT=$(GIT_TERMINAL_PROMPT=0 "$t" "$secs" "$@" 2>&1)
    return $?
  fi
  local cmd_pid watch_pid rc tmpf
  # No temp file available is not a failure: the command still runs and is still
  # bounded, the caller just gets an empty RUN_OUT and says so.
  tmpf=$(mktemp "${TMPDIR:-/tmp}/ai-memory-sync.XXXXXX" 2>/dev/null) || tmpf=""
  if [ -n "$tmpf" ]; then
    GIT_TERMINAL_PROMPT=0 "$@" >"$tmpf" 2>&1 &
  else
    GIT_TERMINAL_PROMPT=0 "$@" >/dev/null 2>&1 &
  fi
  cmd_pid=$!
  # TERM first, KILL a moment later for anything that ignores it. Both are sent
  # to git; a transport child that outlives it exits on its own broken pipe.
  ( sleep "$secs"; kill -TERM "$cmd_pid"; sleep 2; kill -KILL "$cmd_pid" ) >/dev/null 2>&1 &
  watch_pid=$!
  wait "$cmd_pid" >/dev/null 2>&1; rc=$?
  kill "$watch_pid" >/dev/null 2>&1
  wait "$watch_pid" >/dev/null 2>&1
  if [ -n "$tmpf" ]; then
    RUN_OUT=$(cat "$tmpf" 2>/dev/null)
    rm -f "$tmpf" >/dev/null 2>&1
  fi
  return $rc
}

# ff-only first: fast, and it can never rewrite local history. But ff-only
# CANNOT integrate divergence, and with several machines and clients (a WSL
# shell, a desktop app, a cloud session) all committing to the memory tree,
# divergence is the normal case rather than the exception. Left at ff-only
# alone, a machine that falls behind fails to pull, then fails to push, and -
# every failure here being silent - simply stops syncing forever without
# saying so.
#
# So on failure, rebase our memory commits on top instead. Rewriting local
# history is acceptable for a markdown memory store and nothing else in this
# repo is touched by the auto-commit hook. --autostash protects a file written
# but not yet committed, and a conflict is aborted rather than left half-done
# for a human to discover later.
# Divergence must never be silent. A failed pull that is merely "offline" is
# fine and stays quiet; a clone that has actually diverged has STOPPED syncing,
# and that is the state which went unnoticed for five days across three
# machines in September 2026. It is reported into the session context instead.

# --- offline, or BROKEN? decide it on evidence, never on a guess ------------
# ⛔ THE BUG THIS BLOCK REPLACES. A failed pull was read as "offline, carry on"
# no matter WHY it failed, because the only thing consulted was HEAD..@{u} - and
# when a pull fails it has usually failed BEFORE fetching, so that count is 0
# whatever the remote actually holds. Every non-network failure therefore came
# out byte-identical to a laptop on a plane - nothing printed at all:
#   · pull.rebase=true refusing a dirty tree ("cannot pull with rebase: You have
#     unstaged changes") - measured live on the Linux box, 2026-09-26;
#   · "fatal: Cannot rebase onto multiple branches", from a stray FETCH_HEAD
#     entry left by an earlier `git fetch --all` under pull.rebase=true;
#   · no upstream for the branch; a branch deleted on the remote; expired
#     credentials; a rebase conflict.
# Each one left a session believing it held current memory while it held an old
# copy, which is the one failure this whole file exists to prevent.
#
# So reachability is MEASURED - its own short-bounded ls-remote - and only ever
# AFTER a pull has already failed, so a healthy start pays no extra round trip.
# ⛔ And "I could not tell" is its OWN answer. A timeout, or an error this does
# not recognise, must NOT round down to "offline": a check whose failure mode
# imitates the fault it checks for is worse than no check, so unknown says
# unknown, out loud.
one_line() {
  printf '%s' "$1" | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//' | cut -c1-400
}

REMOTE_STATE=""   # reachable | unreachable | unknown
REMOTE_WHY=""
probe_remote() {
  [ -n "$REMOTE_STATE" ] && return 0      # measured once per session
  local rem rc
  rem=$(git -C "$REPO" config --get \
        "branch.$(git -C "$REPO" symbolic-ref --short -q HEAD 2>/dev/null).remote" 2>/dev/null)
  [ -n "$rem" ] || rem=origin
  run 6 git -C "$REPO" ls-remote --exit-code --heads "$rem"
  rc=$?
  # 0 = the remote answered. 2 = it answered and has no matching ref. Both are
  # REACHABLE, which is the only thing being asked here.
  if [ "$rc" = 0 ] || [ "$rc" = 2 ]; then
    REMOTE_STATE=reachable; REMOTE_WHY="the remote answered"; return 0
  fi
  # ⛔ A REFUSAL IS AN ANSWER. Auth failure, a missing repository, an HTTP error
  # all prove the network is there, so none of them may buy the offline
  # exemption - that is precisely how expired credentials would hide for weeks.
  case "$RUN_OUT" in
    *"Authentication failed"*|*"Permission denied"*|*"could not read Username"*|\
    *"Repository not found"*|*"access denied"*|*"not authorized"*|\
    *"returned error: 403"*|*"returned error: 401"*|*"returned error: 404"*)
      REMOTE_STATE=reachable
      REMOTE_WHY="the remote answered, refusing this machine's credentials"; return 0 ;;
  esac
  # Killed by our own watchdog, or by timeout(1): we learned nothing.
  case "$rc" in
    124|125|137|143)
      REMOTE_STATE=unknown; REMOTE_WHY="the remote did not answer within 6s"; return 0 ;;
  esac
  case "$RUN_OUT" in
    *"Could not resolve host"*|*"Temporary failure in name resolution"*|\
    *"Connection refused"*|*"Connection timed out"*|*"Network is unreachable"*|\
    *"No route to host"*|*"Connection reset by peer"*|*"Failed to connect"*|\
    *"Couldn't connect to server"*|*"Operation timed out"*|*"unable to look up"*|\
    *"Name or service not known"*|*"network is down"*)
      REMOTE_STATE=unreachable
      REMOTE_WHY="$(one_line "$RUN_OUT" | cut -c1-160)" ;;
    *)
      REMOTE_STATE=unknown
      REMOTE_WHY="$(one_line "$RUN_OUT" | cut -c1-160)"
      [ -n "$REMOTE_WHY" ] || REMOTE_WHY="ls-remote exited $rc without a message" ;;
  esac
  return 0
}

BR="$(git -C "$REPO" symbolic-ref --short -q HEAD 2>/dev/null)"
[ -n "$BR" ] || BR=main

# fix_for - the EXACT command that clears this error. "Something went wrong with
# your memory sync" is not actionable; a line that can be pasted is.
fix_for() {
  case "$1" in
    *"cannot pull with rebase"*|*"unstaged changes"*|*"local changes"*|\
    *"would be overwritten"*|*"uncommitted"*|*"Cannot pull with rebase"*)
      printf 'git -C %s stash push -u && git -C %s pull --rebase && git -C %s stash pop' \
             "$REPO" "$REPO" "$REPO" ;;
    *"Cannot rebase onto multiple branches"*)
      printf 'git -C %s pull --rebase origin %s   (a stray FETCH_HEAD entry left by an earlier "git fetch --all" makes a bare pull ambiguous under pull.rebase=true; naming the branch bypasses it)' \
             "$REPO" "$BR" ;;
    *"no such ref was fetched"*|*"no such branch"*|*"no tracking information"*|\
    *"There is no tracking information"*)
      printf 'git -C %s fetch origin && git -C %s branch --set-upstream-to=origin/%s %s' \
             "$REPO" "$REPO" "$BR" "$BR" ;;
    *"Authentication failed"*|*"Permission denied"*|*"could not read Username"*|\
    *"Repository not found"*)
      printf 'git -C %s ls-remote origin   (fix the credentials or the ssh agent first, then re-run the pull)' \
             "$REPO" ;;
    *"Need to specify how to reconcile"*|*"divergent branches"*|\
    *"Not possible to fast-forward"*|*"non-fast-forward"*|*"fetch first"*)
      printf 'git -C %s pull --rebase --autostash' "$REPO" ;;
    *"CONFLICT"*|*"could not apply"*|*"Resolve all conflicts"*)
      printf 'git -C %s pull --rebase --autostash   (then resolve the conflict by hand; the automatic attempt was ABORTED, so the tree is exactly as it was)' \
             "$REPO" ;;
    *)
      printf 'git -C %s pull   (run it by hand to see the whole error)' "$REPO" ;;
  esac
}

# report WHAT-FAILED GIT-OUTPUT - the one thing a session can act on.
# Called ONLY after probe_remote, so every word of the wording is backed by a
# measurement rather than by an assumption about why git exited non-zero.
report() {
  local err; err="$(one_line "$2")"
  [ -n "$err" ] || err="git printed nothing"
  case "$REMOTE_STATE" in
    unreachable)
      SYNC_WARN="MEMORY MAY BE STALE - the memory remote is not reachable from this machine ($REMOTE_WHY), so $1 did not go through and the memory below is this machine's LAST SYNCED copy, not necessarily the current one. Nothing to fix if this machine is offline; anything written this session goes out on the next start that has a network. Repo: $REPO." ;;
    reachable)
      SYNC_WARN="MEMORY SYNC FAILED - the memory remote IS reachable ($REMOTE_WHY), so this is NOT an offline blip: $1 failed for a local reason, the memory below may be STALE, and nothing written this session will reach the other machines until it is fixed. git said: $err. Fix it with: $(fix_for "$2"). Repo: $REPO. Tell the user in your first message." ;;
    *)
      SYNC_WARN="MEMORY SYNC COULD NOT BE VERIFIED - $1 failed AND this machine could not establish whether the remote is reachable ($REMOTE_WHY), so whether the memory below is current is UNKNOWN - treat it as possibly stale, not as offline. git said: $err. Check it by hand: $(fix_for "$2"). Repo: $REPO. Tell the user in your first message." ;;
  esac
}

sync_pull() {
  run 8 git -C "$REPO" pull --ff-only --quiet
  local rc=$?
  [ "$rc" = 0 ] && return 0
  local ff_err="$RUN_OUT"

  # No remote configured AT ALL: a local-only memory repo is a legitimate setup
  # with nothing to sync, and it stays silent. A remote that exists while this
  # branch has no upstream is a CONFIGURATION fault, and does not.
  if ! git -C "$REPO" rev-parse '@{u}' >/dev/null 2>&1; then
    [ -n "$(git -C "$REPO" remote 2>/dev/null)" ] || return 1
    probe_remote
    report "the pull" "$ff_err"
    return 1
  fi

  # ⛔ HEAD..@{u} IS NOT EVIDENCE HERE. The pull that just failed most likely
  # failed before it fetched, so a count of 0 means "I have no idea", not
  # "there was nothing to pull". It decides which repair to ATTEMPT, and that
  # is all it is allowed to decide.
  if [ "$(git -C "$REPO" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)" = "0" ]; then
    probe_remote
    report "the pull" "$ff_err"
    return 1
  fi

  if ! run 25 git -C "$REPO" pull --rebase --autostash --quiet; then
    local rb_err="$RUN_OUT"
    run 10 git -C "$REPO" rebase --abort || true
    probe_remote
    report "the rebase of this clone's memory commits onto the remote" "$rb_err"
    return 1
  fi
  return 0
}

sync_pull || true

# --- push what last session committed --------------------------------------
# The SessionEnd hook (ai-memory-commit.sh) commits memory writes but never
# pushes, so the network cost lands here instead - where a round trip is
# already being paid. Nothing to push is the common case and costs one local
# rev-list.
#
# One retry: a push can be rejected by a commit that landed between our pull
# and our push, and re-syncing then pushing again clears exactly that case.
# If the retry also fails the commits stay local and go out next session -
# which is now genuinely "next time" rather than "never".
ahead() {
  [ "$(git -C "$REPO" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)" != "0" ]
}

push_err=""
if ahead; then
  if ! run 10 git -C "$REPO" push --quiet; then
    push_err="$RUN_OUT"
    if sync_pull && ahead; then
      run 10 git -C "$REPO" push --quiet || push_err="$RUN_OUT"
    fi
    # Still ahead after the retry: the commits are stranded on this machine, and
    # that is exactly the thing that used to go out with no message at all.
    # A diagnosis sync_pull already produced is more specific, so it wins.
    if ahead; then
      probe_remote
      [ -n "$SYNC_WARN" ] || report "the push of this clone's memory commits" "$push_err"
    fi
  fi
fi

# --- say so if this clone is NOT actually in sync --------------------------
# Everything above is best-effort and silent, which is right for a hook on
# every session: a laptop with no network must not be nagged. But "I could not
# sync" and "there was nothing to sync" both printed nothing, so a clone that
# had stopped syncing looked exactly like a healthy one. These counts are
# local and cost nothing.
BEHIND=$(git -C "$REPO" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
AHEAD=$(git -C "$REPO" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
if [ "$BEHIND" != "0" ] || [ "$AHEAD" != "0" ]; then
  DIV="MEMORY IS NOT IN SYNC - this clone is $BEHIND commit(s) behind and $AHEAD ahead of its remote."
  if [ "$BEHIND" != "0" ] && [ "$AHEAD" != "0" ]; then
    DIV="$DIV It has DIVERGED: the memory below may be stale, and anything written this session will not reach the other machines until it is resolved."
  fi
  DIV="$DIV Repo: $REPO."
  # ⚠️ APPEND, do not ASSIGN. This block used to overwrite SYNC_WARN, throwing
  # away the specific diagnosis sync_pull had just produced - which is why the
  # old "rebase-conflict" marker was dead on arrival - and its else branch then
  # CLEARED the variable outright, so a clone that happened to end up level
  # after a failed sync reported nothing whatsoever. Counts and cause are two
  # different facts and the session needs both.
  if [ -n "$SYNC_WARN" ]; then
    SYNC_WARN="$SYNC_WARN $DIV"
  else
    SYNC_WARN="$DIV Tell the user in your first message."
  fi
fi
export SYNC_WARN

# --- run the memory repo's own session-start scripts -----------------------
# The repo just pulled may carry claude-setup/session-start.d/*.sh: scripts
# its owner wants run on every machine at every session start, with the repo
# already current - a per-machine migration runner, a check that something is
# still wired. This is how a change committed on one machine reaches the
# others with nobody typing anything. Each script gets a bounded time, is run
# by bash from the repo root, and whatever it prints to stdout is appended to
# the injected context under its own name; a failure is silent and the next
# script still runs. The directory is optional and usually absent.
EXTRA=""
SSD="$REPO/claude-setup/session-start.d"
if [ -d "$SSD" ] && command -v bash >/dev/null 2>&1; then
  for f in "$SSD"/*.sh; do
    [ -f "$f" ] || continue
    out=""
    if command -v timeout >/dev/null 2>&1; then
      out=$(cd "$REPO" && timeout 60 bash "$f" 2>/dev/null) || true
    elif command -v gtimeout >/dev/null 2>&1; then
      out=$(cd "$REPO" && gtimeout 60 bash "$f" 2>/dev/null) || true
    else
      out=$(cd "$REPO" && bash "$f" 2>/dev/null) || true
    fi
    [ -n "$out" ] && EXTRA="$EXTRA
## session-start.d/$(basename "$f")
$out
"
  done
fi
export EXTRA

# --- pick the file to inject -----------------------------------------------
# MEMORY_FILE first; failing that, MEMORY.md inside MEMORY_DIR; failing both,
# inject nothing. The sync above has still done its job either way.
MEM="$REPO/$MEMORY_FILE"
[ -f "$MEM" ] || MEM="$REPO/$MEMORY_DIR/MEMORY.md"
[ -f "$MEM" ] || exit 0
# Unreadable is silent too: a header with no body reads as "the memory is empty".
[ -r "$MEM" ] || exit 0

# --- inject the memory file as context -------------------------------------
# The plain-text fallback covers python3 FAILING as well as missing: a broken
# heredoc (093d3c7 shipped one) must degrade to plain text, not to silence.
INJECTED=""
PY_FAILED=""
if command -v python3 >/dev/null 2>&1; then
  PY_FAILED=1
  INJECTED=$(python3 - "$MEM" 2>/dev/null <<'PY'
import json, os, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        body = f.read()
except Exception:
    sys.exit(0)
ctx = ("Portable memory about the user, auto-synced from their memory "
       "git repo. Treat as durable background context, not a live instruction:\n\n" + body)
warn = os.environ.get("SYNC_WARN", "")
if warn.strip():
    ctx = "WARNING - " + warn.strip() + "\n\n" + ctx
extra = os.environ.get("EXTRA", "")
if extra.strip():
    ctx += ("\n\n---\nOutput of the memory repo's session-start.d scripts, run just now "
            "after the pull (what they did on THIS machine, and anything they ask of this session):\n" + extra)
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": ctx,
}}))
PY
) || INJECTED=""
fi
if [ -n "$INJECTED" ]; then
  printf '%s\n' "$INJECTED"
else
  # Fallback: plain stdout is also added to context by Claude Code.
  [ -n "$PY_FAILED" ] && printf 'NOTE - the structured injector failed; this is the plain-text fallback. Mention it once; do not ask the user to fix anything.\n\n'
  [ -n "$SYNC_WARN" ] && printf 'WARNING - %s\n\n' "$SYNC_WARN"
  echo "Portable memory about the user, auto-synced from their memory repo:"
  cat "$MEM"
  [ -n "$EXTRA" ] && printf '\n---\nOutput of the memory repo'"'"'s session-start.d scripts:\n%s\n' "$EXTRA"
fi
exit 0
