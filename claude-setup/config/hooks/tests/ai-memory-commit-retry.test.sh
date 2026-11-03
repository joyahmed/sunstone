#!/usr/bin/env bash
# ai-memory-commit (.sh AND .js): ONE rebase-and-retry after a rejected push.
#
# WHY (2026-11-01): a session-end push is rejected whenever another box pushed
# first. health-box-a.md was right locally from 09:18Z and still stale on origin at
# 11:51Z, so every box read a false row. The hook now retries once - only on a clean
# tree, aborting any failed rebase. This battery proves the three outcomes on two
# real clones of a bare origin: lands / skipped (dirty) / aborted (conflict).
#
# Same isolation as ai-memory-commit.test.sh: fake HOME under mktemp, no real repo,
# git config cut off. Exit 0 = green, 1 = failure, 2 = could not run.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SH_HOOK="$HERE/../ai-memory-commit.sh"
JS_HOOK="$HERE/../ai-memory-commit.js"
[ -f "$SH_HOOK" ] && [ -f "$JS_HOOK" ] || { echo "hooks not found"; exit 2; }
git --version >/dev/null 2>&1 || { echo "no git"; exit 2; }
HAVE_NODE=1; command -v node >/dev/null 2>&1 || HAVE_NODE=0

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/ai-memory-retry-test.XXXXXX") || exit 2
trap 'rm -rf "$TMPROOT"' EXIT INT TERM HUP
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
export SUNSTONE_PUSH_TIMEOUT=10

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n         want: %s\n         got:  %s\n' "$1" "$2" "$3"; }
t()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

cfg() { git -C "$1" config user.email t@example.invalid; git -C "$1" config user.name T; git -C "$1" config commit.gpgsign false; git -C "$1" config pull.rebase false; }

# origin (bare) + box A (the hook's repo, under a fake HOME) + box B (the other box)
setup() {
	d=$(mktemp -d "$TMPROOT/case.XXXXXX"); h="$d/home"; mkdir -p "$h/.claude"
	git init --quiet --bare -b main "$d/origin.git"
	git init --quiet -b main "$d/seed"; cfg "$d/seed"
	mkdir -p "$d/seed/claude-setup/memory" "$d/seed/claude-setup/session-bus" "$d/seed/claude-setup/config"
	printf 'MEMORY_DIR=claude-setup/memory\nBUS_DIR=claude-setup/session-bus\n' > "$d/seed/claude-setup/config/sunstone.conf"
	printf 'old row\n' > "$d/seed/claude-setup/session-bus/health-a.md"
	: > "$d/seed/claude-setup/memory/.gitkeep"; printf 'x\n' > "$d/seed/README"
	git -C "$d/seed" add -A; git -C "$d/seed" commit --quiet -m seed
	git -C "$d/seed" remote add origin "$d/origin.git"; git -C "$d/seed" push --quiet -u origin main
	git clone --quiet "$d/origin.git" "$d/a"; cfg "$d/a"
	git clone --quiet "$d/origin.git" "$d/b"; cfg "$d/b"
	printf '%s\n' "$d/a" > "$h/.claude/ai-memory-path"
	# box B pushes first, so A is now behind and its plain push will be rejected
	printf 'b note\n' > "$d/b/claude-setup/session-bus/outbox-b.md"
	git -C "$d/b" add -A; git -C "$d/b" commit --quiet -m "b first"; git -C "$d/b" push --quiet
}
run_hook() { # <sh|js>
	if [ "$1" = sh ]; then HOME="$h" bash "$SH_HOOK"; else HOME="$h" node "$JS_HOOK" </dev/null; fi
}
# the push is detached: poll origin for up to 20 s
origin_has_row() { for _ in $(seq 40); do
	git -C "$d/origin.git" show main:claude-setup/session-bus/health-a.md 2>/dev/null | grep -q "new row" && { echo yes; return; }
	sleep 0.5; done; echo no; }
settle() { sleep 4; }  # let a detached child that should NOT push finish trying
mid_rebase() { [ -d "$d/a/.git/rebase-merge" ] || [ -d "$d/a/.git/rebase-apply" ] && echo yes || echo no; }

for kind in sh js; do
	[ "$kind" = js ] && [ "$HAVE_NODE" = 0 ] && { echo "js: node missing - skipped (NOT a pass)"; fail=$((fail+1)); continue; }
	echo "[$kind] A is behind, tree clean -> the row must land on origin:"
	setup; printf 'new row\n' > "$d/a/claude-setup/session-bus/health-a.md"
	t0=$(date +%s); run_hook $kind; landed=$(origin_has_row); t1=$(date +%s)
	t "row landed on origin" yes "$landed"
	t "B's commit kept on origin" yes "$(git -C "$d/origin.git" log --format=%s main | grep -qx 'b first' && echo yes || echo no)"
	t "A not left mid-rebase" no "$(mid_rebase)"
	echo "         (origin commits: $(git -C "$d/origin.git" rev-list --count main), landed in $((t1-t0))s)"

	echo "[$kind] A is behind, an unrelated file is dirty -> no retry, nothing rebased:"
	setup; printf 'new row\n' > "$d/a/claude-setup/session-bus/health-a.md"; printf 'wip\n' >> "$d/a/README"
	run_hook $kind; settle
	t "origin does NOT have the row (left for SessionStart)" no "$(git -C "$d/origin.git" show main:claude-setup/session-bus/health-a.md | grep -q 'new row' && echo yes || echo no)"
	t "the local commit is kept" yes "$(git -C "$d/a" show HEAD:claude-setup/session-bus/health-a.md | grep -q 'new row' && echo yes || echo no)"
	t "the dirty file is untouched" yes "$(grep -q wip "$d/a/README" && echo yes || echo no)"
	t "A not left mid-rebase" no "$(mid_rebase)"

	echo "[$kind] A is behind with a CONFLICT -> rebase aborted, nothing half-done:"
	setup
	printf 'b row\n' > "$d/b/claude-setup/session-bus/health-a.md"; git -C "$d/b" commit --quiet -am "b row"; git -C "$d/b" push --quiet
	printf 'new row\n' > "$d/a/claude-setup/session-bus/health-a.md"
	run_hook $kind; settle
	t "A not left mid-rebase" no "$(mid_rebase)"
	t "A's commit still on its branch" yes "$(git -C "$d/a" show HEAD:claude-setup/session-bus/health-a.md | grep -q 'new row' && echo yes || echo no)"
	t "origin keeps B's row, never forced" "b row" "$(git -C "$d/origin.git" show main:claude-setup/session-bus/health-a.md)"
	t "A's tree is clean" "" "$(git -C "$d/a" status --porcelain)"
done

echo; echo "retry battery: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
