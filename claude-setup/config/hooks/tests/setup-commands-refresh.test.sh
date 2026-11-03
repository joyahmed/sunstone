#!/usr/bin/env bash
# Regression battery for setup.sh's install_copy_safe() - the subset-safe copy
# that ~/.claude/commands/*.md is installed with when LINK_COMMANDS is unset,
# i.e. on every machine that never configured anything.
#
# WHY THIS EXISTS. Commands were installed as plain copies and nothing refreshed
# them, so they drifted: measured on one box, three of six installed commands
# were STRICT SUBSETS of their repo copy with zero lines of their own - never
# refreshed since the missing sections landed, one of which was the rule that
# keeps an unattended run from failing its own commit every slice. The obvious
# repair (copy over them every run) is the one that must NOT be made, because
# the same directory is where a person edits a slash command by hand: a refresh
# that cannot tell "out of date" from "edited" buys the drift fix by silently
# destroying work. So install_copy_safe has FIVE answers, and this battery is
# the proof that it gives the right one in each - including the two NEGATIVE
# controls, since a refresher that refreshes everything is as wrong as one that
# refreshes nothing.
#
#   absent    → installed, silently (the normal first install; unchanged)
#   identical → nothing at all: no copy, no backup, no output on a re-run
#   subset    → REFRESHED, backed up first, and the backup lands OUTSIDE the
#               commands directory (a .bak in there registers as a command)
#   diverged  → KEPT byte-for-byte and named on stdout. Never replaced.
#   symlink   → skipped entirely, broken ones included: a link is the user's
#               LINK_COMMANDS=1 answer and already tracks the repo
#
#   bash setup-commands-refresh.test.sh        (SETUP=/path/to/setup.sh)
#
# ⛔ NOTHING HERE TOUCHES THE REAL ~/.claude. setup.sh is never RUN - its three
# relevant functions are extracted by name and eval'd into this shell, against a
# fake HOME under $TMPDIR. Running the installer to test one function would
# rewrite the machine's own commands, hooks and settings, which is the opposite
# of a test. The extraction is verified before use: a renamed or reshaped
# function exits 2 (did not run) rather than passing vacuously.
#
# ⚠️ A MISSING PREREQUISITE EXITS 2, NOT 0 - "could not exercise it" must never
# be reported as "it works". 0 = green, 1 = a real failure, 2 = did not run.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SETUP="${SETUP:-$HERE/../../../../setup.sh}"

[ -f "$SETUP" ] || { echo "setup.sh not found at $SETUP - set SETUP=/path/to/it"; exit 2; }
for t in awk cmp cp date ln; do
	command -v "$t" >/dev/null 2>&1 || { echo "no $t - install_copy_safe cannot be exercised"; exit 2; }
done

# extract <name> - the definition of a top-level function of setup.sh, from its
# `name() {` line to the first line that is exactly `}`. Every function in that
# file is written that way; if one ever is not, the guard below catches it.
extract() {
	awk -v f="$1" '
		$0 == f "() {" { inside = 1 }
		inside         { print }
		inside && $0 == "}" { exit }
	' "$SETUP"
}

# The three functions under test, plus the two they call. Pulled in dependency
# order purely for readability - eval order does not matter for shell functions.
for fn in backup is_stale_subset install_copy_safe; do
	src=$(extract "$fn")
	case "$src" in
		"$fn"'() {'*'}') ;;
		*) echo "could not extract $fn() from $SETUP - it was renamed or reshaped, so this battery is no longer testing it"; exit 2 ;;
	esac
	eval "$src" || { echo "extracted $fn() does not parse"; exit 2; }
done

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/setup-cmd-refresh.XXXXXX") || {
	echo "could not create a temp dir - refusing to run against the real ~/.claude"; exit 2; }
cleanup() { [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT INT TERM HUP

# setup.sh sets these; the extracted functions read them.
YELLOW=""; NC=""

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n         want: %s\n         got:  %s\n' "$1" "$2" "$3"; }
clip() { printf '%s' "$1" | tr '\n' '|' | cut -c1-400; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "output contains '$2'" "$(clip "$3")" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1" "output does NOT contain '$2'" "$(clip "$3")" ;; *) ok "$1" ;; esac; }
same()  { if cmp -s "$2" "$3"; then ok "$1"; else bad "$1" "$2 identical to $3" "they differ"; fi; }
differs() { if cmp -s "$2" "$3"; then bad "$1" "$2 NOT identical to $3" "they are identical"; else ok "$1"; fi; }

# ── the fixture: a repo's commands/ and a fake ~/.claude/commands/ ────────────
REPO="$TMPROOT/repo/claude-setup/commands"
CFG="$TMPROOT/home/.claude"
LIVE="$CFG/commands"
BACKUP_DIR="$CFG/backups"          # what backup() reads; setup.sh's own default
mkdir -p "$REPO" "$LIVE"

# Every repo copy carries a section a never-refreshed install would be missing.
for name in absent identical subset diverged linked broken; do
	printf 'line one\nline two\nline three\nthe rule that landed later\n' > "$REPO/$name.md"
done

# absent.md   - deliberately not installed: the normal first-install path.
# identical.md - byte-identical.
cp "$REPO/identical.md" "$LIVE/identical.md"
# ⛔ NEGATIVE CONTROL. STRICT SUBSET: every line of it is in the repo copy and
# the repo copy has one it lacks. The exact shape measured on the real machine
# (zero lines of its own). This one MUST be refreshed.
printf 'line one\nline two\nline three\n' > "$LIVE/subset.md"
# ⛔ NEGATIVE CONTROL, the other way. DIVERGED: a line of its own, so it may be
# somebody's deliberate edit. Kept, whatever else is true of it - note it is
# ALSO missing the repo's later line, so a naive "is it out of date?" test would
# happily overwrite it.
printf 'line one\nline two\nmy own local tweak\n' > "$LIVE/diverged.md"
cp "$LIVE/diverged.md" "$TMPROOT/diverged.expected"
# linked.md  - a symlink to the repo file: LINK_COMMANDS=1 was used here.
ln -s "$REPO/linked.md" "$LIVE/linked.md"
# broken.md  - a symlink to nowhere. Still the user's link, and `[ -e ]` is
# FALSE for it, which is why install_copy_safe tests `[ -L ]` first.
ln -s "$TMPROOT/nowhere/gone.md" "$LIVE/broken.md"

run_all() {   # every command, in one pass, the way step_commands does
	for name in absent identical subset diverged linked broken; do
		install_copy_safe "$REPO/$name.md" "$LIVE/$name.md"
	done
}

echo "── pass 1: a machine whose commands have drifted ──"
OUT1=$(run_all 2>&1)

# 1. absent → installed, and quietly: an install is not a repair to report.
if [ -f "$LIVE/absent.md" ] && [ ! -L "$LIVE/absent.md" ]; then ok "absent: installed"; else
	bad "absent: installed" "$LIVE/absent.md is a regular file" "missing or a link"; fi
same     "absent: installed content matches the repo" "$REPO/absent.md" "$LIVE/absent.md"
hasnt    "absent: says nothing (it is an install, not a refresh)" "absent.md" "$OUT1"

# 2. identical → untouched and silent. No backup clutter on a re-run, which is
#    the property that makes it safe to run setup twice in a row.
same  "identical: left matching the repo" "$REPO/identical.md" "$LIVE/identical.md"
hasnt "identical: says nothing" "identical.md" "$OUT1"

# 3. subset → refreshed, announced, and backed up first.
same "subset: REFRESHED to the repo copy" "$REPO/subset.md" "$LIVE/subset.md"
has  "subset: says it refreshed it" "refreshed: $LIVE/subset.md" "$OUT1"
has  "subset: says it backed it up" "backed up: $LIVE/subset.md" "$OUT1"
n_bak=$(find "$BACKUP_DIR" -name 'subset.md.bak.*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$n_bak" = "1" ]; then ok "subset: exactly one backup, in $BACKUP_DIR"; else
	bad "subset: exactly one backup, in $BACKUP_DIR" "1 file" "$n_bak"; fi
bak=$(find "$BACKUP_DIR" -name 'subset.md.bak.*' 2>/dev/null | head -n1)
if [ -n "$bak" ] && grep -q 'line three' "$bak" && ! grep -q 'the rule that landed later' "$bak"; then
	ok "subset: the backup holds the OLD content"
else
	bad "subset: the backup holds the OLD content" "the pre-refresh bytes" "${bak:-no backup at all}"
fi
# ⛔ THE RULE A .bak BREAKS. A <name>.md.bak.<stamp> inside ~/.claude/commands
# registers AS A SLASH COMMAND - an out-of-date one, one pick away from being
# used. Backups go outside the directory anything enumerates.
stray=$(find "$LIVE" -name '*.bak*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$stray" = "0" ]; then ok "subset: no .bak left inside the commands directory"; else
	bad "subset: no .bak left inside the commands directory" "0" "$stray"; fi

# 4. diverged → byte-for-byte untouched, named, and NOT backed up (nothing was
#    replaced, so there is nothing to keep a copy of).
same     "diverged: left byte-for-byte as the person wrote it" "$TMPROOT/diverged.expected" "$LIVE/diverged.md"
differs  "diverged: NOT overwritten with the repo copy" "$REPO/diverged.md" "$LIVE/diverged.md"
has      "diverged: named on stdout" "kept $LIVE/diverged.md as it is" "$OUT1"
has      "diverged: tells the person how to decide" "diff it against $REPO/diverged.md" "$OUT1"
d_bak=$(find "$BACKUP_DIR" -name 'diverged.md.bak.*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$d_bak" = "0" ]; then ok "diverged: no backup (nothing was replaced)"; else
	bad "diverged: no backup (nothing was replaced)" "0" "$d_bak"; fi

# 5. symlink → skipped entirely. Converting it back to a copy would re-create
#    the very drift LINK_COMMANDS=1 was set to end.
if [ -L "$LIVE/linked.md" ] && [ "$(readlink "$LIVE/linked.md")" = "$REPO/linked.md" ]; then
	ok "symlink: still the link it was"
else
	bad "symlink: still the link it was" "a symlink to $REPO/linked.md" "$(ls -l "$LIVE/linked.md" 2>&1)"
fi
hasnt "symlink: says nothing" "linked.md" "$OUT1"
if [ -L "$LIVE/broken.md" ] && [ ! -e "$LIVE/broken.md" ]; then
	ok "broken symlink: left alone rather than silently replaced by a copy"
else
	bad "broken symlink: left alone" "still a dangling symlink" "$(ls -l "$LIVE/broken.md" 2>&1)"
fi

echo "── pass 2: the same machine, setup run again (idempotence) ──"
OUT2=$(run_all 2>&1)
# Everything except the diverged warning is now a no-op: the first pass either
# refreshed the file or deliberately declined to, and neither is redone.
hasnt "re-run: nothing refreshed" "refreshed:" "$OUT2"
hasnt "re-run: nothing backed up" "backed up:" "$OUT2"
has   "re-run: the diverged file is named again (it is still unresolved)" "kept $LIVE/diverged.md" "$OUT2"
n_bak2=$(find "$BACKUP_DIR" -name '*.bak.*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$n_bak2" = "1" ]; then ok "re-run: still exactly one backup in total"; else
	bad "re-run: still exactly one backup in total" "1" "$n_bak2"; fi
same "re-run: diverged file STILL untouched" "$TMPROOT/diverged.expected" "$LIVE/diverged.md"

# ── the predicate itself, at the boundary ────────────────────────────────────
# install_copy_safe is only as safe as is_stale_subset, and two shapes decide
# everything: a REORDERED file counts as edited (order is content), and an equal
# line-set with no missing line is not "out of date" at all.
printf 'line three\nline two\nline one\nthe rule that landed later\n' > "$TMPROOT/reordered.md"
if is_stale_subset "$TMPROOT/reordered.md" "$REPO/absent.md"; then
	bad "predicate: a reordered file is not 'stale'" "false" "true"
else
	ok "predicate: a reordered file is not 'stale' (same lines, nothing missing)"
fi
: > "$TMPROOT/empty.md"
if is_stale_subset "$TMPROOT/empty.md" "$REPO/absent.md"; then
	ok "predicate: an empty live file IS a subset (nothing of its own to lose)"
else
	bad "predicate: an empty live file IS a subset" "true" "false"
fi
if is_stale_subset "$REPO/absent.md" "$TMPROOT/empty.md"; then
	bad "predicate: an EMPTY repo copy never licenses a refresh" "false" "true"
else
	ok "predicate: an EMPTY repo copy never licenses a refresh"
fi

echo
printf 'pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
