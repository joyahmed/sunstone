#!/usr/bin/env bash
# Regression battery for ai-memory-commit.sh.
#
# WHY THIS FILE EXISTS: this hook is the one that PUBLISHES. It runs at SessionEnd,
# resolves a repository, commits it and pushes it - unattended, on every machine,
# every session. And every one of its failure modes is silent on purpose, because a
# hook that breaks a session end is worse than a hook that does nothing. The
# consequence is that it has failed silently more than once and nothing said so: a
# session whose only change was its outbox exited having staged nothing, and the
# memory it was carrying reached no other machine, with no error anywhere.
#
#   bash ai-memory-commit.test.sh          (HOOK=/path/to/hook to point it elsewhere)
#
# ⛔ EVERY CASE BELOW RUNS UNDER A FAKE $HOME, AND THAT IS STRUCTURAL, NOT CAREFUL.
# The hook does not take a repository argument. It reads $HOME/.claude/ai-memory-path
# and commits whatever that names. So a battery that "runs it in a scratch
# directory" is not exercising the scratch directory at all - it is committing the
# REAL memory repo, pushing it, and then reading the real repo's log back as if
# those commits were its own results. That misreading nearly happened by hand while
# these expectations were being established, with a dirty real tree on disk.
# The defence is construction: every invocation below gets HOME set to a directory
# this script made with mktemp and deletes again on exit - on success, on failure
# and on interrupt. Nothing here names a real repo, a real home or a real branch,
# so there is no path from this file to one.
#
# ⚠️ A PREREQUISITE THAT IS MISSING EXITS 2, NOT 0. "Could not run the hook" must
# never be reported as "the hook is fine" - that is the same silence this battery
# exists to end. 0 = all green, 1 = a real failure, 2 = did not run.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="${HOOK:-$HERE/../ai-memory-commit.sh}"

[ -f "$HOOK" ] || { echo "hook not found beside the test: $HOOK"; exit 2; }
git --version >/dev/null 2>&1 || { echo "no git on PATH - this hook IS git, there is nothing to test without it"; exit 2; }

REAL_HOME="${HOME:-}"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/ai-memory-commit-test.XXXXXX") || {
	echo "could not create a temp dir - refusing to run, because the only alternative is running against the real HOME"; exit 2; }
cleanup() { [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT INT TERM HUP

# ⛔ git reads config from three places and two of them sit OUTSIDE the fake HOME,
# so the fake HOME alone does not isolate it. A leaked GIT_DIR would point these
# scratch commits at a real repository; an inherited core.hooksPath or
# commit.gpgsign would make the scratch repo behave unlike the one the assertions
# below describe. Cut all of it off once, here. (A git too old to honour
# GIT_CONFIG_GLOBAL falls back to the fake HOME's .gitconfig, which does not
# exist - so the isolation holds either way.)
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_TERMINAL_PROMPT=0

pass=0; fail=0

ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n         want: %s\n         got:  %s\n' "$1" "$2" "$3"; }
t()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains '$2'" "$3" ;; esac; }

# ⚠️ mktemp, not a counter. This is always called as `h=$(new_home)` and a command
# substitution is a SUBSHELL, so an incremented counter inside it is discarded the
# moment the function returns and every case would be handed the SAME directory.
# That is not cosmetic: the first draft of this battery did exactly that, and the
# both-dirty case then dirtied files an earlier case had already committed in what
# it believed was its own private repo, saw a clean tree, and reported 0 commits
# where 2 were correct. mktemp cannot regress that way.
new_home() {
	_h=$(mktemp -d "$TMPROOT/home.XXXXXX") || return 1
	mkdir -p "$_h/.claude"
	printf '%s' "$_h"
}

# The scratch repo in the shape the hook expects of a real memory repo: a memory
# dir, its SIBLING bus dir - the sibling relationship is the whole reason the bus
# needed its own line in the hook - and a sunstone.conf naming both. Seeded with
# one commit so "dirty" and "clean" are distinguishable and so HEAD can be detached
# in the last case.
#
# ⚠️ NO REMOTE IS CONFIGURED, DELIBERATELY. The hook's last act is an opportunistic
# push, and the contract is that a push it cannot make is harmless: it must still
# exit 0 and must not undo the commits it just made. A repo with nowhere to push is
# the cheapest way to hold it to that, and it keeps this battery off the network.
new_memrepo() {
	_h="$1"; _r="$_h/scratch-memory-repo"
	mkdir -p "$_r/claude-setup/memory" "$_r/claude-setup/session-bus" "$_r/claude-setup/config"
	printf 'MEMORY_DIR=claude-setup/memory\nBUS_DIR=claude-setup/session-bus\n' \
		> "$_r/claude-setup/config/sunstone.conf"
	: > "$_r/claude-setup/memory/.gitkeep"
	: > "$_r/claude-setup/session-bus/.gitkeep"
	git -C "$_r" init --quiet >/dev/null 2>&1
	git -C "$_r" config user.email "hook-tests@example.invalid" >/dev/null 2>&1
	git -C "$_r" config user.name  "Hook Tests" >/dev/null 2>&1
	git -C "$_r" config commit.gpgsign false >/dev/null 2>&1
	git -C "$_r" add -A >/dev/null 2>&1
	git -C "$_r" commit --quiet -m "seed" >/dev/null 2>&1
	# THIS is the line that makes the hook operate on the scratch repo rather than
	# on whatever the machine's real memory repo happens to be.
	printf '%s\n' "$_r" > "$_h/.claude/ai-memory-path"
	printf '%s' "$_r"
}

commits_in() { git -C "$1" rev-list --count HEAD 2>/dev/null || echo 0; }
subject_of() { git -C "$1" log -1 --format=%s 2>/dev/null; }
staged_in()  { git -C "$1" diff --cached --name-only 2>/dev/null; }
ondisk()     { [ -f "$1" ] && echo yes || echo no; }

# ⛔ THE ASSERTION THIS WHOLE FILE IS REALLY FOR. The framework's own pre-commit
# guard REFUSES a commit that stages paths both inside and outside MEMORY_DIR. So
# if the hook ever collapsed its two commits into one `add` of both directories,
# that guard would reject it and the hook would commit NOTHING AT ALL - losing the
# memory and the bus note together, silently, which is the exact failure the
# two-commit split exists to prevent. The scratch repo deliberately has no such
# guard installed: a guard here would turn the regression into a visible error,
# and the point is to catch the SHAPE itself, on a repo that would have allowed it.
mixed_commits_in() { # <repo> <how many commits to look back>
	_r="$1"; _n="$2"; _mixed=0
	for _c in $(git -C "$_r" rev-list -n "$_n" HEAD 2>/dev/null); do
		_names=$(git -C "$_r" show --name-only --format= "$_c" 2>/dev/null)
		_m=$(printf '%s\n' "$_names" | grep -c '^claude-setup/memory/' || true)
		_b=$(printf '%s\n' "$_names" | grep -c '^claude-setup/session-bus/' || true)
		[ "$_m" -gt 0 ] && [ "$_b" -gt 0 ] && _mixed=$((_mixed+1))
	done
	printf '%s' "$_mixed"
}

# The isolation assertion is printed FIRST, because if it ever fails nothing below
# it can be believed - the results would be a real repository's.
echo "isolation - if this pair ever fails, ignore everything after it:"
if [ -n "$REAL_HOME" ] && [ "$(new_home)" = "$REAL_HOME" ]; then
	bad "the fake HOME is not the real HOME" "a temp dir" "the real HOME"
else
	ok "the fake HOME is not the real HOME"
fi
h=$(new_home)
case "$h" in "$TMPROOT"/*) ok "the fake HOME is under this run's mktemp dir, removed on exit" ;;
	*) bad "the fake HOME is under this run's mktemp dir, removed on exit" "under $TMPROOT" "$h" ;; esac

# ⛔ THE CASE THAT WAS DROPPED ON THE FLOOR ENTIRELY. BUS_DIR is MEMORY_DIR's
# sibling, not its child, so staging the memory tree by path never touched it - and
# the hook's "nothing to commit" fast path keyed on the memory tree ALONE. A
# session whose only change was its closing note to the other machines therefore
# exited before staging anything, and that note was still untracked at the next
# pull. Invisible to every other machine, with no error and no warning.
echo "only the bus dir is dirty - the closing note must still land:"
h=$(new_home); r=$(new_memrepo "$h")
before=$(commits_in "$r")
printf 'a note to the other machines\n' > "$r/claude-setup/session-bus/outbox-scratch.md"
HOME="$h" bash "$HOOK"; rc=$?
t "exactly 1 commit"                          1 "$(( $(commits_in "$r") - before ))"
has "its subject marks it as a bus/team commit" "TEAM:" "$(subject_of "$r")"
t "exits 0 although there is no remote to push to" 0 "$rc"
t "leaves nothing staged behind"              "" "$(staged_in "$r")"

# The original case, and the one that must not regress while the bus half is fixed.
echo "only the memory dir is dirty:"
h=$(new_home); r=$(new_memrepo "$h")
before=$(commits_in "$r")
printf '# a memory\n' > "$r/claude-setup/memory/scratch-topic.md"
HOME="$h" bash "$HOOK"; rc=$?
t "exactly 1 commit"                          1 "$(( $(commits_in "$r") - before ))"
has "its subject is memory-style"             "memory:" "$(subject_of "$r")"
has "its subject names the file that changed" "scratch-topic" "$(subject_of "$r")"
t "exits 0"                                   0 "$rc"
t "leaves nothing staged behind"              "" "$(staged_in "$r")"

echo "both dirs are dirty - two commits, and NEITHER may mix the two:"
h=$(new_home); r=$(new_memrepo "$h")
before=$(commits_in "$r")
printf '# a memory\n' > "$r/claude-setup/memory/scratch-topic.md"
printf 'a note to the other machines\n' > "$r/claude-setup/session-bus/outbox-scratch.md"
HOME="$h" bash "$HOOK"; rc=$?
made=$(( $(commits_in "$r") - before ))
t "exactly 2 commits"                         2 "$made"
t "⛔ no single commit holds paths from both dirs" 0 "$(mixed_commits_in "$r" "$made")"
t "exits 0"                                   0 "$rc"
t "leaves nothing staged behind"              "" "$(staged_in "$r")"
t "the working tree is clean afterwards"      "" "$(git -C "$r" status --porcelain)"

# The cheap exit: no index touched, no network, no commit.
echo "neither dir is dirty:"
h=$(new_home); r=$(new_memrepo "$h")
before=$(commits_in "$r")
HOME="$h" bash "$HOOK"; rc=$?
t "0 commits"                                 0 "$(( $(commits_in "$r") - before ))"
t "exits 0"                                   0 "$rc"
t "stages nothing"                            "" "$(staged_in "$r")"

# ⚠️ A commit made on a detached HEAD is on no branch: the moment a branch is
# checked back out the session's memory is gone from the tree, and the sync hook -
# having no branch to push either - never recovers it. Refusing is the correct
# behaviour, and refusing is only safe if the files are LEFT ALONE, which is what
# the last two assertions are for: the next session is what picks them up.
echo "detached HEAD, both dirs dirty - refuse, and leave the files where they are:"
h=$(new_home); r=$(new_memrepo "$h")
git -C "$r" checkout --detach --quiet HEAD >/dev/null 2>&1
before=$(commits_in "$r")
printf '# a memory\n' > "$r/claude-setup/memory/scratch-topic.md"
printf 'a note to the other machines\n' > "$r/claude-setup/session-bus/outbox-scratch.md"
HOME="$h" bash "$HOOK"; rc=$?
t "0 commits"                                 0 "$(( $(commits_in "$r") - before ))"
t "stages nothing"                            "" "$(staged_in "$r")"
t "exits 0"                                   0 "$rc"
t "the memory file is still on disk for the next session" yes "$(ondisk "$r/claude-setup/memory/scratch-topic.md")"
t "the bus file is still on disk for the next session"    yes "$(ondisk "$r/claude-setup/session-bus/outbox-scratch.md")"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
