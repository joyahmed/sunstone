#!/usr/bin/env bash
# ai-memory-commit.sh - SessionEnd hook. The write half of memory sync.
#
# Commits anything written under the memory tree (MEMORY_DIR, default
# claude-setup/memory/) during the session, and - as a SECOND, SEPARATE commit -
# anything written to the session bus (BUS_DIR, default
# claude-setup/session-bus/).
# It then attempts a DETACHED, time-bounded push, and never waits for it. The
# session ends at the same speed whether the network is there or not.
#
# ⛔ Why the bus needs its own line here at all: it is MEMORY_DIR's SIBLING, not
# its child. Staging the memory tree by path therefore never touched it, so a
# session's closing summary to the other machines was committed nowhere and was
# still untracked at the next pull - invisible to every other machine, with no
# error and no warning. Worse, the "nothing to commit" fast path below keyed on
# the memory tree alone, so a session whose only dirty file was its outbox
# exited before staging anything at all.
#
# ⛔ And why they must be TWO commits, never one `add` of both paths: the
# framework's own pre-commit guard refuses any commit that stages paths both
# inside and outside MEMORY_DIR. A single mixed commit would be rejected by that
# guard and the whole hook would silently do nothing - the failure it is here to
# end.
#
# ⚠️ Why push here at all, when ai-memory-sync.sh pushes on the next
# SessionStart: because "the next SessionStart" means the next one ON THIS
# MACHINE. Close the laptop after your last session and open a different
# machine, and that memory is committed locally and reachable from nowhere -
# which is the exact case this whole layer exists to prevent. The next
# SessionStart remains the reliable path: it pulls first, resolves divergence,
# and surfaces a conflict while the user is present. This is the opportunistic
# one - fire-and-forget, --no-verify-free, and silent about failure, because
# anything it misses the next session still fixes.
#
# Scope is deliberately narrow: this stages those two directories by path, one
# per commit, and nothing else. An auto-commit is fine for a memory store and
# unacceptable for source, and the memory repo may hold both.
#
# The commit runs with --no-verify, on purpose. This hook stages one directory
# by path and commits only that pathspec, so a mixed-staging guard (the
# framework's pre-commit, which refuses a commit that mixes memory and source)
# is satisfied by construction and there is nothing left for it to check. The
# consequence is that repo-local hooks in the memory repo (pre-commit,
# commit-msg, prepare-commit-msg - husky, lint-staged, and the like) are
# bypassed for THIS ONE COMMIT only; every commit a person makes in that repo
# still runs them.
#
# Every failure mode is silent. A memory file that fails to commit is still on
# disk and will be picked up next time.
#
# ⛔ Because this hook both commits AND pushes, it is the thing that actually
# publishes on someone's behalf - not the next SessionStart, this one, right
# now, unattended. Any nested or forked `claude` process fires SessionEnd when
# IT exits too, so launching `claude` inside a captured pty - a common way to
# test launcher behaviour, terminal titling, or shell integration - runs this
# hook on that exit, and it will commit and push whatever is uncommitted under
# MEMORY_DIR or BUS_DIR, under a message its author never wrote. This has
# already happened: a half-finished edit was committed under a generated
# message and pushed before its author could write their own - and once
# pushed to a public remote it could not be quietly rewritten. BUS_DIR is the
# likelier of the two to catch someone out, because it is what gets written at
# the very end of a session, so it is the file most often sitting
# half-drafted at exactly the moment someone is testing. The rule: before any
# pty test that may run `claude`, have nothing uncommitted under MEMORY_DIR or
# BUS_DIR.

set -u

# --- locate the repo (same resolution order as ai-memory-sync.sh) ----------
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
[ -z "$REPO" ] && exit 0

# --- read sunstone.conf (optional, grepped never sourced) ------------------
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

MEM_DIR="$(conf_get MEMORY_DIR claude-setup/memory)"
# BUS_DIR is the key the session-bus notice hook already reads, deliberately:
# one name for one directory. A second key meaning the same thing is how two
# readers of this file end up disagreeing and a guard goes quiet.
BUS_DIR="$(conf_get BUS_DIR claude-setup/session-bus)"

# Each directory stands on its own: either may be absent from a given repo, and
# either may be clean. An empty variable below means "nothing to do for this
# one" and every later step skips it in silence.
[ -n "$MEM_DIR" ] && [ -d "$REPO/$MEM_DIR" ] || MEM_DIR=""
[ -n "$BUS_DIR" ] && [ -d "$REPO/$BUS_DIR" ] || BUS_DIR=""

# --- anything to commit? ---------------------------------------------------
# Cheap: a clean tree exits here having touched no index and no network. Both
# directories are asked, so a session whose only change is its outbox is no
# longer dropped on the floor here.
dirty_dir() {
  [ -n "$1" ] || return 1
  [ -n "$(git -C "$REPO" status --porcelain -- "$1" 2>/dev/null)" ]
}
dirty_dir "$MEM_DIR" || MEM_DIR=""
dirty_dir "$BUS_DIR" || BUS_DIR=""
if [ -z "$MEM_DIR" ] && [ -z "$BUS_DIR" ]; then
  exit 0
fi

# Refuse to run mid-rebase/merge - committing into that state makes a mess a
# human then has to unpick.
GIT_DIR="$(git -C "$REPO" rev-parse --git-dir 2>/dev/null)" || exit 0
case "$GIT_DIR" in /*) ;; *) GIT_DIR="$REPO/$GIT_DIR" ;; esac
for marker in MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD rebase-merge rebase-apply; do
  [ -e "$GIT_DIR/$marker" ] && exit 0
done

# Refuse on a detached HEAD too. A commit made there is on no branch: the moment
# the user checks a branch back out the session's memory is gone from the tree,
# and - the sync hook having no branch to push either - nothing ever recovers
# it. Refusing leaves the files on disk, where the next session picks them up.
# (An unborn branch is fine: symbolic-ref resolves before the first commit.)
git -C "$REPO" symbolic-ref -q HEAD >/dev/null 2>&1 || exit 0

# --- stage and commit ONE directory, alone ---------------------------------
# commit_dir DIR SUBJECT_PREFIX. One pathspec per call and one pathspec per
# commit: never `add` both directories together, or the mixed-staging guard
# described at the top of this file rejects the commit and nothing lands.
# Returns 0 only when a commit was actually created; every failure resets what
# it staged and returns non-zero, so one half failing cannot strand the other.
COMMITTED=0
commit_dir() {
  dir="$1"; prefix="$2"
  [ -n "$dir" ] || return 1

  git -C "$REPO" add -- "$dir" >/dev/null 2>&1 || return 1

  # `add` can still leave nothing staged (e.g. ignored files only).
  git -C "$REPO" diff --cached --quiet -- "$dir" 2>/dev/null && return 1

  # Name what changed so the log stays readable without opening the diff.
  # Basenames without .md, joined as 'a, b, c' and capped at 90 characters -
  # byte-for-byte what the .js twin produces. (Not `paste -sd', '`: paste
  # CYCLES its delimiter list, giving 'a,b c,d'. Not `xargs basename`: a name
  # with a space would be split in two.)
  #
  # core.quotePath=false because git's default is to octal-escape and double-quote
  # any path that is not pure ASCII, which would put `r\303\251sum\303\251.md"` in the
  # subject line - and the stray closing quote also defeats the `.md` strip.
  staged="$(git -C "$REPO" -c core.quotePath=false diff --cached --name-only -- "$dir" 2>/dev/null)"
  files="$(printf '%s\n' "$staged" | sed -e 's#.*/##' -e 's/\.md$//' \
           | awk 'length($0) { s = s (n++ ? ", " : "") $0 } END { print substr(s, 1, 90) }')"
  count="$(printf '%s\n' "$staged" | grep -c . 2>/dev/null || echo 0)"

  # A failed commit must not leave the tree staged. The usual causes are
  # environmental and outlast the session - no committer identity yet, a signing
  # key this non-interactive hook cannot unlock, a locked index - so the staging
  # would still be there on the user's next commit in that repo, where it is
  # either swept into an unrelated commit or refused outright by the framework's
  # own mixed-staging guard. Put the index back and stay silent: the files are on
  # disk and the next session commits them.
  if ! git -C "$REPO" commit --quiet --no-verify \
       -m "${prefix} ${count} file(s) from a session - ${files}" \
       -- "$dir" >/dev/null 2>&1; then
    git -C "$REPO" reset --quiet -- "$dir" >/dev/null 2>&1 || true
    return 1
  fi

  COMMITTED=1
  return 0
}

# Memory first, then the bus - two commits, in that order, each skipped in
# silence when its directory is absent or clean.
commit_dir "$MEM_DIR" "memory:" || true
commit_dir "$BUS_DIR" "✅TEAM:" || true

# Nothing committed - nothing to push, and nothing left staged.
[ "$COMMITTED" = 1 ] || exit 0

# ── Opportunistic push ────────────────────────────────────────────────────
#
# Detached on purpose: `setsid` where it exists, a plain background subshell
# otherwise. The hook returns immediately either way, so a hung or absent
# network cannot make ending a session feel slow - the failure mode that made
# this hook refuse to touch the network in the first place.
#
# Bounded twice over: GIT_TERMINAL_PROMPT=0 so a credential prompt cannot wait
# on a stdin nobody is watching, and a hard kill after PUSH_TIMEOUT. `timeout`
# is not on stock macOS, so gtimeout and then a self-watchdog stand in for it -
# the same ladder ai-memory-sync.sh climbs.
#
# --no-verify is deliberate: the framework's own pre-push guard is interactive
# by design, and a guard asking a question with nobody there is a hang. The
# guard still covers every push a human makes.
#
# ⛔ Only the current branch, never --force, never a new remote. If the push is
# rejected - diverged, no upstream, no remote at all - that is the normal case
# and the next SessionStart handles it properly, with a pull first.
PUSH_TIMEOUT="${SUNSTONE_PUSH_TIMEOUT:-20}"

git -C "$REPO" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || exit 0

push_bounded() {
  if command -v timeout >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 timeout "$PUSH_TIMEOUT" git -C "$REPO" push --quiet --no-verify >/dev/null 2>&1
  elif command -v gtimeout >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 gtimeout "$PUSH_TIMEOUT" git -C "$REPO" push --quiet --no-verify >/dev/null 2>&1
  else
    GIT_TERMINAL_PROMPT=0 git -C "$REPO" push --quiet --no-verify >/dev/null 2>&1 &
    local pid=$!
    ( sleep "$PUSH_TIMEOUT"; kill -TERM "$pid"; sleep 2; kill -KILL "$pid" ) >/dev/null 2>&1 &
    wait "$pid" >/dev/null 2>&1
  fi
}

# `trap '' HUP` rather than setsid or nohup: the subshell has to outlive this
# hook, and ignoring SIGHUP is all that takes - no second interpreter to hand
# the function to, and nothing that behaves differently across platforms.
( trap '' HUP; push_bounded ) >/dev/null 2>&1 &

exit 0
