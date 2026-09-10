#!/usr/bin/env bash
# ai-memory-commit.sh — SessionEnd hook. The write half of memory sync.
#
# Commits anything written under the memory tree (MEMORY_DIR, default
# claude-setup/memory/) during the session.
# It then attempts a DETACHED, time-bounded push, and never waits for it. The
# session ends at the same speed whether the network is there or not.
#
# ⚠️ Why push here at all, when ai-memory-sync.sh pushes on the next
# SessionStart: because "the next SessionStart" means the next one ON THIS
# MACHINE. Close the laptop after your last session and open a different
# machine, and that memory is committed locally and reachable from nowhere —
# which is the exact case this whole layer exists to prevent. The next
# SessionStart remains the reliable path: it pulls first, resolves divergence,
# and surfaces a conflict while the user is present. This is the opportunistic
# one — fire-and-forget, --no-verify-free, and silent about failure, because
# anything it misses the next session still fixes.
#
# Scope is deliberately narrow: this stages ONE directory by path and nothing
# else. An auto-commit is fine for a memory store and unacceptable for source,
# and the memory repo may hold both.
#
# The commit runs with --no-verify, on purpose. This hook stages the memory
# tree by path and commits only that pathspec, so a mixed-staging guard (the
# framework's pre-commit, which refuses a commit that mixes memory and source)
# is satisfied by construction and there is nothing left for it to check. The
# consequence is that repo-local hooks in the memory repo (pre-commit,
# commit-msg, prepare-commit-msg — husky, lint-staged, and the like) are
# bypassed for THIS ONE COMMIT only; every commit a person makes in that repo
# still runs them.
#
# Every failure mode is silent. A memory file that fails to commit is still on
# disk and will be picked up next time.

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

MEM_DIR="$(conf_get MEMORY_DIR claude-setup/memory)"
[ -d "$REPO/$MEM_DIR" ] || exit 0

# --- anything to commit? ---------------------------------------------------
# Cheap: a clean tree exits here having touched no index and no network.
if [ -z "$(git -C "$REPO" status --porcelain -- "$MEM_DIR" 2>/dev/null)" ]; then
  exit 0
fi

# Refuse to run mid-rebase/merge — committing into that state makes a mess a
# human then has to unpick.
GIT_DIR="$(git -C "$REPO" rev-parse --git-dir 2>/dev/null)" || exit 0
case "$GIT_DIR" in /*) ;; *) GIT_DIR="$REPO/$GIT_DIR" ;; esac
for marker in MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD rebase-merge rebase-apply; do
  [ -e "$GIT_DIR/$marker" ] && exit 0
done

# Refuse on a detached HEAD too. A commit made there is on no branch: the moment
# the user checks a branch back out the session's memory is gone from the tree,
# and — the sync hook having no branch to push either — nothing ever recovers
# it. Refusing leaves the files on disk, where the next session picks them up.
# (An unborn branch is fine: symbolic-ref resolves before the first commit.)
git -C "$REPO" symbolic-ref -q HEAD >/dev/null 2>&1 || exit 0

# --- stage only the memory directory ---------------------------------------
git -C "$REPO" add -- "$MEM_DIR" >/dev/null 2>&1 || exit 0

# `add` can still leave nothing staged (e.g. ignored files only).
git -C "$REPO" diff --cached --quiet -- "$MEM_DIR" 2>/dev/null && exit 0

# Name what changed so the log stays readable without opening the diff.
# Basenames without .md, joined as 'a, b, c' and capped at 90 characters —
# byte-for-byte what the .js twin produces. (Not `paste -sd', '`: paste
# CYCLES its delimiter list, giving 'a,b c,d'. Not `xargs basename`: a name
# with a space would be split in two.)
#
# core.quotePath=false because git's default is to octal-escape and double-quote
# any path that is not pure ASCII, which would put `r\303\251sum\303\251.md"` in the
# subject line — and the stray closing quote also defeats the `.md` strip.
STAGED="$(git -C "$REPO" -c core.quotePath=false diff --cached --name-only -- "$MEM_DIR" 2>/dev/null)"
FILES="$(printf '%s\n' "$STAGED" | sed -e 's#.*/##' -e 's/\.md$//' \
         | awk 'length($0) { s = s (n++ ? ", " : "") $0 } END { print substr(s, 1, 90) }')"
COUNT="$(printf '%s\n' "$STAGED" | grep -c . 2>/dev/null || echo 0)"

# A failed commit must not leave the memory tree staged. The usual causes are
# environmental and outlast the session — no committer identity yet, a signing
# key this non-interactive hook cannot unlock, a locked index — so the staging
# would still be there on the user's next commit in that repo, where it is
# either swept into an unrelated commit or refused outright by the framework's
# own mixed-staging guard. Put the index back and stay silent: the files are on
# disk and the next session commits them.
if ! git -C "$REPO" commit --quiet --no-verify \
     -m "memory: ${COUNT} file(s) from a session — ${FILES}" \
     -- "$MEM_DIR" >/dev/null 2>&1; then
  git -C "$REPO" reset --quiet -- "$MEM_DIR" >/dev/null 2>&1 || true
  exit 0
fi

# ── Opportunistic push ────────────────────────────────────────────────────
#
# Detached on purpose: `setsid` where it exists, a plain background subshell
# otherwise. The hook returns immediately either way, so a hung or absent
# network cannot make ending a session feel slow — the failure mode that made
# this hook refuse to touch the network in the first place.
#
# Bounded twice over: GIT_TERMINAL_PROMPT=0 so a credential prompt cannot wait
# on a stdin nobody is watching, and a hard kill after PUSH_TIMEOUT. `timeout`
# is not on stock macOS, so gtimeout and then a self-watchdog stand in for it —
# the same ladder ai-memory-sync.sh climbs.
#
# --no-verify is deliberate: the framework's own pre-push guard is interactive
# by design, and a guard asking a question with nobody there is a hang. The
# guard still covers every push a human makes.
#
# ⛔ Only the current branch, never --force, never a new remote. If the push is
# rejected — diverged, no upstream, no remote at all — that is the normal case
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
# hook, and ignoring SIGHUP is all that takes — no second interpreter to hand
# the function to, and nothing that behaves differently across platforms.
( trap '' HUP; push_bounded ) >/dev/null 2>&1 &

exit 0
