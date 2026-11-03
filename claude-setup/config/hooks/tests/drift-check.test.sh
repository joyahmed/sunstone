#!/usr/bin/env bash
# Regression battery for drift-check.sh's destination-first pass: it must
# also see what's AT a destination dir that neither repo shipped there, and
# classify it - untracked REAL entry (the case that hid docker-development
# in ~/.claude/skills and cost the fleet a night), untracked SYMLINK (milder,
# probably another source), a KNOWN-BENIGN entry owned by another tool or
# load-bearing for sunstone via a side channel (Claude Code's "synced" dir,
# hooks/claude-name.txt) that must stay silent, and a STALE BACKUP left by
# install.sh's backup() (named as its own class, not lumped with unknown
# drift).
#
# ⚠️ Runs the REAL drift-check.sh against a FAKE $REPO and a FAKE $CFG -
# never the box's own ~/.claude, so this battery is not at the mercy of
# whatever the machine running it actually has installed.
#
#   bash drift-check.test.sh
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="${SCRIPT:-$HERE/../../../scripts/drift-check.sh}"
[ -f "$SCRIPT" ] || { echo "drift-check.sh not found beside the test: $SCRIPT"; exit 2; }
command -v bash >/dev/null 2>&1 || { echo "no bash"; exit 2; }

_tmp="${TMPDIR:-/tmp}"; _tmp="${_tmp%/}"; [ -n "$_tmp" ] || _tmp=/tmp
TMPROOT=$(mktemp -d "$_tmp/drift-check-test.XXXXXX") || { echo "could not create a temp dir"; exit 2; }
cleanup() { [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT INT TERM HUP

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n         want: %s\n         got:  %s\n' "$1" "$2" "$3"; }

# mk_repo -> a scratch $REPO carrying the real drift-check.sh, two shipped
# skills (skill-a, skill-b) and two shipped hooks (hook-a.sh, hook-b.sh), so
# shipped_ratio has something to count in both categories.
mk_repo() {
	repo=$(mktemp -d "$TMPROOT/repo.XXXXXX")
	mkdir -p "$repo/claude-setup/scripts" "$repo/skills/skill-a" "$repo/skills/skill-b" \
		"$repo/claude-setup/config/hooks"
	cp "$SCRIPT" "$repo/claude-setup/scripts/drift-check.sh"
	echo '#!/usr/bin/env bash' > "$repo/claude-setup/config/hooks/hook-a.sh"
	echo '#!/usr/bin/env bash' > "$repo/claude-setup/config/hooks/hook-b.sh"
	printf '%s' "$repo"
}

# mk_cfg <repo> -> a scratch $CFG with skill-a/skill-b and hook-a.sh/hook-b.sh
# correctly symlinked back into <repo> - a fully linked, otherwise-clean box.
mk_cfg() {
	repo="$1"
	cfg=$(mktemp -d "$TMPROOT/cfg.XXXXXX")
	mkdir -p "$cfg/skills" "$cfg/hooks"
	ln -s "$repo/skills/skill-a" "$cfg/skills/skill-a"
	ln -s "$repo/skills/skill-b" "$cfg/skills/skill-b"
	ln -s "$repo/claude-setup/config/hooks/hook-a.sh" "$cfg/hooks/hook-a.sh"
	ln -s "$repo/claude-setup/config/hooks/hook-b.sh" "$cfg/hooks/hook-b.sh"
	touch "$cfg/settings.json"
	printf '%s' "$cfg"
}

# run <repo> <cfg> -> drift-check's combined stdout+stderr, isolated HOME so
# it never resolves this box's own ~/.ai-memory or ~/.claude/ai-memory-path.
run() {
	repo="$1"; cfg="$2"
	h=$(mktemp -d "$TMPROOT/home.XXXXXX")
	env -i HOME="$h" PATH="$PATH" CLAUDE_CONFIG_DIR="$cfg" \
		bash "$repo/claude-setup/scripts/drift-check.sh" 2>&1
}

echo "genuinely clean tree - no extras, plain linked line, exit 0:"
repo=$(mk_repo); cfg=$(mk_cfg "$repo")
out=$(run "$repo" "$cfg"); rc=$?
case "$out" in
	*"skills: 2/2 linked"*) ok "clean tree reports 2/2 linked" ;;
	*) bad "clean tree reports 2/2 linked" "skills: 2/2 linked" "$out" ;;
esac
case "$out" in *"~ "*) bad "clean tree has no warning marker" "no '~ ' line" "$out" ;; *) ok "clean tree has no warning marker" ;; esac
[ "$rc" = 0 ] && ok "clean tree exits 0" || bad "clean tree exits 0" "0" "$rc"
case "$out" in *"drift-check: clean"*) ok "clean tree's verdict says clean" ;; *) bad "clean tree's verdict says clean" "drift-check: clean" "$out" ;; esac

echo "untracked REAL directory (docker-development) - warned, named, verdict CLEAN WITH WARNINGS, exit 0:"
repo=$(mk_repo); cfg=$(mk_cfg "$repo")
mkdir -p "$cfg/skills/docker-development"
out=$(run "$repo" "$cfg"); rc=$?
case "$out" in *"~ skills:"*"1 real dir: docker-development"*) ok "real dir named as untracked real" ;;
	*) bad "real dir named as untracked real" "~ skills: ... 1 real dir: docker-development" "$out" ;; esac
case "$out" in *"drift-check: clean, 1 warning(s)"*) ok "verdict is clean-with-warnings" ;;
	*) bad "verdict is clean-with-warnings" "drift-check: clean, 1 warning(s)" "$out" ;; esac
[ "$rc" = 0 ] && ok "untracked real dir does not fail the gate" || bad "untracked real dir does not fail the gate" "0" "$rc"

echo "untracked SYMLINK - the milder class: noted, not warned, verdict stays plain clean:"
repo=$(mk_repo); cfg=$(mk_cfg "$repo")
ln -s /tmp "$cfg/skills/some-other-source"
out=$(run "$repo" "$cfg"); rc=$?
case "$out" in *"  skills:"*"1 symlink: some-other-source"*) ok "untracked symlink named on a plain note line" ;;
	*) bad "untracked symlink named on a plain note line" "  skills: ... 1 symlink: some-other-source" "$out" ;; esac
case "$out" in *"~ "*) bad "untracked symlink does not raise a warning" "no '~ ' line" "$out" ;; *) ok "untracked symlink does not raise a warning" ;; esac
case "$out" in *"drift-check: clean"*) ok "verdict stays plain clean" ;; *) bad "verdict stays plain clean" "drift-check: clean" "$out" ;; esac
[ "$rc" = 0 ] && ok "untracked symlink does not fail the gate" || bad "untracked symlink does not fail the gate" "0" "$rc"

echo "known-benign entries (synced/, a dotfile) - silent, never counted as drift:"
repo=$(mk_repo); cfg=$(mk_cfg "$repo")
mkdir -p "$cfg/skills/synced/some-uuid-dir" "$cfg/skills/.hidden-tool-dir"
touch "$cfg/skills/synced/.bucket-uuid_uuid"
out=$(run "$repo" "$cfg"); rc=$?
case "$out" in *"~ "*) bad "known-benign entries raise no warning" "no '~ ' line" "$out" ;; *) ok "known-benign entries raise no warning" ;; esac
case "$out" in *"1 untracked"*|*"2 untracked"*) bad "known-benign entries are not counted as untracked" "no 'N untracked'" "$out" ;;
	*) ok "known-benign entries are not counted as untracked" ;; esac
case "$out" in *"drift-check: clean"*) ok "verdict with only known-benign extras stays clean" ;;
	*) bad "verdict with only known-benign extras stays clean" "drift-check: clean" "$out" ;; esac
[ "$rc" = 0 ] && ok "known-benign entries do not fail the gate" || bad "known-benign entries do not fail the gate" "0" "$rc"

echo "hooks: per-category allowlist (claude-name.txt) - silent, load-bearing file stays unwarned:"
repo=$(mk_repo); cfg=$(mk_cfg "$repo")
printf 'box-a\n' > "$cfg/hooks/claude-name.txt"
out=$(run "$repo" "$cfg"); rc=$?
case "$out" in *"~ "*) bad "allowlisted hooks file raises no warning" "no '~ ' line" "$out" ;;
	*) ok "allowlisted hooks file raises no warning" ;; esac
case "$out" in *"drift-check: clean"*) ok "allowlisted hooks file leaves verdict plain clean" ;;
	*) bad "allowlisted hooks file leaves verdict plain clean" "drift-check: clean" "$out" ;; esac
[ "$rc" = 0 ] && ok "allowlisted hooks file does not fail the gate" || bad "allowlisted hooks file does not fail the gate" "0" "$rc"

echo "hooks: a stale install.sh backup (*.bak.<timestamp>) - named as its OWN class, not lumped with unknown drift:"
repo=$(mk_repo); cfg=$(mk_cfg "$repo")
touch "$cfg/hooks/session-bus-notice.js.bak.20260923_191521"
out=$(run "$repo" "$cfg"); rc=$?
case "$out" in *"~ hooks:"*"1 stale backup: session-bus-notice.js.bak.20260923_191521"*) ok "stale backup named on its own line" ;;
	*) bad "stale backup named on its own line" "~ hooks: ... 1 stale backup: session-bus-notice.js.bak.20260923_191521" "$out" ;; esac
case "$out" in *"real file"*) bad "stale backup is not called a plain untracked real file" "no 'real file'" "$out" ;;
	*) ok "stale backup is not called a plain untracked real file" ;; esac
case "$out" in *"drift-check: clean, 1 warning(s)"*) ok "stale backup's verdict is clean-with-warnings" ;;
	*) bad "stale backup's verdict is clean-with-warnings" "drift-check: clean, 1 warning(s)" "$out" ;; esac
[ "$rc" = 0 ] && ok "stale backup does not fail the gate" || bad "stale backup does not fail the gate" "0" "$rc"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
