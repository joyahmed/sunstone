#!/usr/bin/env bash
# Regression battery for setup.sh's LINK_* self-heal: install_link_safe() for a
# single file and link_skill_safe() for a skill tree, the two functions that run
# when LINK_COMMANDS=1 / LINK_SKILLS=1 and the destination is still a plain copy.
#
# WHY THIS EXISTS. Those two functions decided "is this only an out-of-date copy
# of ours?" with is_stale_subset alone, and that predicate can only see staleness
# that ADDED lines. The moment an upstream commit REMOVES or REWORDS one, the
# installed copy holds a line the repo no longer has and reads exactly like a
# local edit - so setup kept it, every run, forever, while reporting success.
# Measured on two boxes: a Mac held ~/.claude/commands/supermode.md at 126 lines
# against a 131-line canonical through two byte-identical setup runs (only moving
# the copy aside by hand let the third one link it), and an Ubuntu box reported
# commands 0/8 and skills 0/45 linked with both keys set - install-doctor.sh and
# drift-check.sh calling that drifted while setup.sh called it done.
#
# is_old_copy (subset OR a past version of the path in git) is the fix, and this
# battery is the proof that each answer is the right one - including the negative
# controls, since a converter that converts everything is as wrong as one that
# converts nothing:
#
#   identical      → linked, NO backup, silent
#   stale subset   → linked, NO backup
#   an old release → linked, NO backup  (the bug: this used to stay a copy)
#   the same, CRLF → linked (git's clean filter plus the one \r retry)
#   diverged       → BACKED UP first, named loudly, then linked. Never deleted.
#   correct link   → untouched, silent
#   other link     → relinked, and what it pointed at is untouched
#   skill tree     → the same four answers, with the backup OUTSIDE the skills
#                    root (a <name>.bak.<stamp> in there registers as a skill)
#   second run     → ZERO new files anywhere under the fake ~/.claude, proved by
#                    diffing a full listing of the tree, not by re-reading a ratio
#
#   bash setup-link-selfheal.test.sh        (SETUP=/path/to/setup.sh)
#
# ⛔ NOTHING HERE TOUCHES THE REAL ~/.claude, and nothing RUNS setup.sh - the
# relevant functions are extracted by name and eval'd into this shell against a
# throwaway git repo and a fake HOME under $TMPDIR. The extraction is verified
# before use: a renamed or reshaped function exits 2 (did not run) rather than
# passing vacuously.
#
# ⚠️ A MISSING PREREQUISITE EXITS 2, NOT 0 - "could not exercise it" must never
# be reported as "it works". 0 = green, 1 = a real failure, 2 = did not run.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SETUP="${SETUP:-$HERE/../../../../setup.sh}"

[ -f "$SETUP" ] || { echo "setup.sh not found at $SETUP - set SETUP=/path/to/it"; exit 2; }
for t in awk cmp cp date diff find git ln tr; do
	command -v "$t" >/dev/null 2>&1 || { echo "no $t - the self-heal cannot be exercised"; exit 2; }
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

for fn in backup is_stale_subset is_old_release is_old_copy install_link install_link_safe skill_tree_stale link_skill_safe; do
	src=$(extract "$fn")
	case "$src" in
		"$fn"'() {'*'}') ;;
		*) echo "could not extract $fn() from $SETUP - it was renamed or reshaped, so this battery is no longer testing it"; exit 2 ;;
	esac
	eval "$src" || { echo "extracted $fn() does not parse"; exit 2; }
done

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/setup-link-selfheal.XXXXXX") || {
	echo "could not create a temp dir - refusing to run against the real ~/.claude"; exit 2; }
cleanup() { [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT INT TERM HUP

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n         want: %s\n         got:  %s\n' "$1" "$2" "$3"; }
clip() { printf '%s' "$1" | tr '\n' '|' | cut -c1-400; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "output contains '$2'" "$(clip "$3")" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1" "output does NOT contain '$2'" "$(clip "$3")" ;; *) ok "$1" ;; esac; }
same()  { if cmp -s "$2" "$3"; then ok "$1"; else bad "$1" "$2 identical to $3" "they differ"; fi; }
links() {  # <label> <path> <target>
	if [ -L "$2" ] && [ "$(readlink "$2")" = "$3" ]; then ok "$1"; else
		bad "$1" "$2 is a symlink to $3" "$(ls -ld "$2" 2>&1)"; fi
}
nbak() {  # <label> <dir> <pattern> <want>
	local n; n=$(find "$2" -name "$3" 2>/dev/null | wc -l | tr -d ' ')
	if [ "$n" = "$4" ]; then ok "$1"; else bad "$1" "$4 file(s) matching $3" "$n"; fi
}

# ── the fixture: a real git repo with two commits, and a fake ~/.claude ───────
# setup.sh's own variables. SCRIPT_DIR and OVERLAY_ROOT are what is_old_release
# resolves a source path against; only the framework root exists here, and
# OVERLAY_ROOT being empty is also the every-box-without-a-personal-repo case.
SCRIPT_DIR="$TMPROOT/repo"
OVERLAY_ROOT=""
YELLOW=""; NC=""
CMDSRC="$SCRIPT_DIR/claude-setup/commands"
SKILLSRC="$SCRIPT_DIR/skills"
CFG="$TMPROOT/home/.claude"
LIVE="$CFG/commands"
SKILLS="$CFG/skills"
BACKUP_DIR="$CFG/backups"          # what backup() reads; setup.sh's own default
mkdir -p "$CMDSRC" "$SKILLSRC/oldskill" "$SKILLSRC/cleanskill" "$SKILLSRC/divergedskill" "$LIVE" "$SKILLS"

# -c on every call rather than config in the repo: this box has a global
# core.hooksPath with commit guards behind it, and a test must not run them.
GIT="git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=$TMPROOT/nohooks"
$GIT -C "$SCRIPT_DIR" init -q || { echo "git init failed - cannot build the history this battery needs"; exit 2; }

# v1: the release a stale box is still holding. The middle line is the one the
# next commit REWORDS - the shape is_stale_subset cannot see.
write_v1() { printf 'first line\nread the queue first\nlast line\n' > "$1"; }
# v2: canonical, and one line longer, so the subset case has something to lack.
write_v2() { printf 'first line\nread the handoff first\nlast line\none more rule that landed later\n' > "$1"; }

for name in identical subset oldrelease crlf diverged linked elsewhere; do
	write_v1 "$CMDSRC/$name.md"
done
write_v1 "$SKILLSRC/oldskill/SKILL.md"
write_v1 "$SKILLSRC/cleanskill/SKILL.md"
write_v1 "$SKILLSRC/divergedskill/SKILL.md"
$GIT -C "$SCRIPT_DIR" add -A >/dev/null 2>&1
$GIT -C "$SCRIPT_DIR" commit -qm v1 >/dev/null 2>&1 || { echo "git commit failed - cannot build the history this battery needs"; exit 2; }
for name in identical subset oldrelease crlf diverged linked elsewhere; do
	write_v2 "$CMDSRC/$name.md"
done
write_v2 "$SKILLSRC/oldskill/SKILL.md"
write_v2 "$SKILLSRC/cleanskill/SKILL.md"
write_v2 "$SKILLSRC/divergedskill/SKILL.md"
$GIT -C "$SCRIPT_DIR" add -A >/dev/null 2>&1
$GIT -C "$SCRIPT_DIR" commit -qm v2 >/dev/null 2>&1 || { echo "git commit failed"; exit 2; }

# what the drifted box holds
cp "$CMDSRC/identical.md" "$LIVE/identical.md"                              # identical
printf 'first line\nread the handoff first\nlast line\n' > "$LIVE/subset.md" # strict subset of v2
write_v1 "$LIVE/oldrelease.md"                                              # ⛔ the bug: v1, not a subset
printf 'first line\r\nread the queue first\r\nlast line\r\n' > "$LIVE/crlf.md"  # v1 with CRLF
printf 'first line\nmy own local tweak\nlast line\n' > "$LIVE/diverged.md"   # nobody's release
cp "$LIVE/diverged.md" "$TMPROOT/diverged.expected"
ln -s "$CMDSRC/linked.md" "$LIVE/linked.md"                                 # already correct
printf 'a file of my own\n' > "$TMPROOT/outside.md"
ln -s "$TMPROOT/outside.md" "$LIVE/elsewhere.md"                            # a link somewhere else
cp -r "$SKILLSRC/oldskill" "$SKILLS/oldskill"; write_v1 "$SKILLS/oldskill/SKILL.md"
cp -r "$SKILLSRC/cleanskill" "$SKILLS/cleanskill"
cp -r "$SKILLSRC/divergedskill" "$SKILLS/divergedskill"
printf 'my own addition\n' > "$SKILLS/divergedskill/MINE.md"

run_all() {   # what ship() mode L and step_skills' LINK_SKILLS branch do
	for name in identical subset oldrelease crlf diverged linked elsewhere; do
		install_link_safe "$CMDSRC/$name.md" "$LIVE/$name.md"
	done
	for name in oldskill cleanskill divergedskill; do
		link_skill_safe "$SKILLSRC/$name" "$SKILLS/$name"
	done
}

# list_tree - every path under the fake ~/.claude, links spelled with their
# target. The proof that a second run mints nothing: compared byte for byte.
list_tree() {
	find "$CFG" 2>/dev/null | sort | while IFS= read -r f; do
		if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"
		else printf '%s\n' "$f"; fi
	done
}

echo "── the predicate, before the functions that act on it ──"
if is_old_release "$LIVE/oldrelease.md" "$CMDSRC/oldrelease.md"; then
	ok "is_old_release: v1 content IS a past version of that path"
else
	bad "is_old_release: v1 content IS a past version of that path" "true" "false"
fi
if is_stale_subset "$LIVE/oldrelease.md" "$CMDSRC/oldrelease.md"; then
	bad "is_old_release is what answers here (the subset test cannot)" "is_stale_subset false" "true"
else
	ok "is_old_release is what answers here (the subset test cannot see a reworded line)"
fi
if is_old_release "$LIVE/crlf.md" "$CMDSRC/crlf.md"; then
	ok "is_old_release: the same content with CRLF endings still matches"
else
	bad "is_old_release: the same content with CRLF endings still matches" "true" "false"
fi
# ⛔ NEGATIVE CONTROL: content this repo never held must NOT look like a release.
if is_old_release "$LIVE/diverged.md" "$CMDSRC/diverged.md"; then
	bad "is_old_release: a file nobody ever shipped is NOT an old release" "false" "true"
else
	ok "is_old_release: a file nobody ever shipped is NOT an old release"
fi
# ⛔ NEGATIVE CONTROL: no git, no verdict - and never a false "yes".
if ( PATH=/nonexistent; is_old_release "$LIVE/oldrelease.md" "$CMDSRC/oldrelease.md" ) 2>/dev/null; then
	bad "is_old_release: without git it says no, never yes" "false" "true"
else
	ok "is_old_release: without git it says no, never yes"
fi

echo "── pass 1: a box where LINK_* is set and everything is still a copy ──"
OUT1=$(run_all 2>&1)

links "identical: linked" "$LIVE/identical.md" "$CMDSRC/identical.md"
nbak  "identical: no backup (nothing was at risk)" "$BACKUP_DIR" 'identical.md.bak.*' 0
links "subset: linked" "$LIVE/subset.md" "$CMDSRC/subset.md"
nbak  "subset: no backup (provably an old copy of ours)" "$BACKUP_DIR" 'subset.md.bak.*' 0
# ⛔ THE BUG. This is the file that stayed a 126-line copy on the Mac.
links "old release: LINKED (this is the defect this battery exists for)" "$LIVE/oldrelease.md" "$CMDSRC/oldrelease.md"
nbak  "old release: no backup (git proved it is ours)" "$BACKUP_DIR" 'oldrelease.md.bak.*' 0
hasnt "old release: not reported as somebody's edit" "oldrelease.md differs from" "$OUT1"
has   "old release: the conversion is named on stdout" "linked: $LIVE/oldrelease.md" "$OUT1"
links "CRLF old release: linked" "$LIVE/crlf.md" "$CMDSRC/crlf.md"

# diverged → set aside, named, and linked. The content survives in the backup.
links "diverged: linked" "$LIVE/diverged.md" "$CMDSRC/diverged.md"
has   "diverged: named loudly" "$LIVE/diverged.md differs from $CMDSRC/diverged.md by more than being out of date" "$OUT1"
has   "diverged: the backup path is on stdout" "backed up: $LIVE/diverged.md" "$OUT1"
nbak  "diverged: exactly one backup" "$BACKUP_DIR" 'diverged.md.bak.*' 1
dbak=$(find "$BACKUP_DIR" -name 'diverged.md.bak.*' 2>/dev/null | head -n1)
if [ -n "$dbak" ]; then same "diverged: the backup holds the person's bytes" "$TMPROOT/diverged.expected" "$dbak"; else
	bad "diverged: the backup holds the person's bytes" "a backup file" "none"; fi
nbak "diverged: no .bak inside the commands directory (a .bak there IS a command)" "$LIVE" '*.bak*' 0

links "correct link: still the link it was" "$LIVE/linked.md" "$CMDSRC/linked.md"
hasnt "correct link: says nothing" "linked.md" "$OUT1"
links "other link: relinked at the repo file" "$LIVE/elsewhere.md" "$CMDSRC/elsewhere.md"
if [ -f "$TMPROOT/outside.md" ] && grep -q 'a file of my own' "$TMPROOT/outside.md"; then
	ok "other link: what it pointed at is untouched (only the link was removed)"
else
	bad "other link: what it pointed at is untouched" "$TMPROOT/outside.md intact" "gone or changed"
fi

links "skill, old release: LINKED" "$SKILLS/oldskill" "$SKILLSRC/oldskill"
hasnt "skill, old release: not reported as somebody's edit" "oldskill is not merely" "$OUT1"
# ⚠️ A TREE IS BACKED UP EVEN WHEN IT IS PROVABLY OURS - unlike a single file.
# rm -rf of a directory is the one act in setup.sh that must stay undoable, so
# "old release" buys a quiet conversion here, not a skipped backup. Only a tree
# that is byte-for-byte what the repo ships (cleanskill, above) skips it.
nbak  "skill, old release: backed up anyway (this removes a directory)" "$CFG/skill-backups" 'oldskill.bak.*' 1
links "skill, identical: linked" "$SKILLS/cleanskill" "$SKILLSRC/cleanskill"
nbak  "skill, identical: no backup at all (nothing to undo)" "$CFG/skill-backups" 'cleanskill.bak.*' 0
links "skill, diverged: linked" "$SKILLS/divergedskill" "$SKILLSRC/divergedskill"
has   "skill, diverged: named loudly" "$SKILLS/divergedskill is not merely an out-of-date copy" "$OUT1"
nbak  "skill, diverged: exactly one backup" "$CFG/skill-backups" 'divergedskill.bak.*' 1
sbak=$(find "$CFG/skill-backups" -name 'divergedskill.bak.*' 2>/dev/null | head -n1)
if [ -n "$sbak" ] && [ -f "$sbak/MINE.md" ]; then ok "skill, diverged: the person's own file is in the backup"; else
	bad "skill, diverged: the person's own file is in the backup" "$sbak/MINE.md" "missing"; fi
# ⛔ A <name>.bak.<stamp> under the skills root loads as a SECOND, STALE skill.
nbak "skill: no backup left inside the skills root" "$SKILLS" '*.bak*' 0

echo "── pass 2: the same box, setup run again (idempotence, files included) ──"
BEFORE="$TMPROOT/tree.before"; AFTER="$TMPROOT/tree.after"
list_tree > "$BEFORE"
OUT2=$(run_all 2>&1)
list_tree > "$AFTER"
if cmp -s "$BEFORE" "$AFTER"; then
	ok "re-run: not one file added, removed or relinked anywhere under $CFG"
else
	bad "re-run: not one file added, removed or relinked anywhere under $CFG" "an identical listing" \
	    "$(diff "$BEFORE" "$AFTER" | clip "$(diff "$BEFORE" "$AFTER")")"
fi
# ⚠️ ZERO new .bak, not "one more is fine": setup.ps1 was found minting a fresh
# commit-msg.bak.<stamp> on every run, five in one evening on one box, and that
# is the shape this assertion exists to keep off the bash side.
nbak  "re-run: still exactly one file backup in total" "$BACKUP_DIR" '*.bak.*' 1
nbak  "re-run: still exactly two skill backups in total (oldskill, divergedskill)" "$CFG/skill-backups" '*.bak.*' 2
if [ -z "$OUT2" ]; then ok "re-run: prints nothing at all"; else
	bad "re-run: prints nothing at all" "no output" "$(clip "$OUT2")"; fi

echo
printf 'pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
