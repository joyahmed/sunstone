#!/usr/bin/env bash
# Regression battery for install-doctor.sh check 8 - the staleness detector for
# installed commands, skills AND the top-level files setup installs straight
# into ~/.claude (the status line twins, the CLAUDE.md overlay, the supermode
# settings).
#
# WHY THIS FILE EXISTS. The drift it detects is invisible by construction: setup
# COPIES commands and skills, nothing re-copies them, and until check 8 nothing
# said they were behind. Three of six installed commands on one machine were
# strict subsets of their repo copy - never refreshed since the missing sections
# landed - and one missing section was the rule that keeps an unattended run from
# failing its own commit every slice.
#
# ⚠️ AND A DETECTOR FOR AN INVISIBLE FAULT IS THE EASIEST KIND TO FAKE. Two
# failure modes would both look like success and neither would ever be noticed:
#
#   · it flags nothing, on a machine that is fully stale  → green, wrong, and
#     nobody re-checks a green. So case 1 and case 5 are NEGATIVE CONTROLS: a
#     deliberately stale file and a deliberately stale skill tree that the
#     detector MUST name. If they stop being named, this battery goes red.
#   · it flags everything, so the report is noise people scroll past → cases 3
#     and 4 pin an identical copy and a symlink as NOT flagged.
#
# The third thing it must never do is destroy a local edit, so case 2 and case 6
# byte-compare a diverged file and a diverged skill tree before and after --fix.
#
# ⛔ AND THE SHAPE THAT WAS ACTUALLY MISSED gets its own fixture, because the
# first version of the check walked commands/ and skills/ ONLY: a top-level
# config file installed as a PLAIN COPY where the sibling machine has a symlink,
# 5 KB behind the repo, painting every session for weeks. `statusline-command.js`
# below is that file, reproduced exactly - a stale strict-subset copy, not a link.
# Its twin `.sh` is the inverse control in the same scenario: a symlink, and the
# detector must stay silent about it. The two twins are SEPARATE files under a
# parity contract, so nothing here compares one against the other; what IS
# pinned is that the twin an OS's installer does not ship is not called
# "never installed" while the other twin is present.
#
# ⛔ AND THE SHAPE THAT THE SUBSET TEST STRUCTURALLY CANNOT SEE gets its own
# fixtures, with REAL git history, because the answer now comes from the repo
# rather than from a line comparison. When an upstream commit REMOVES lines,
# every un-refreshed copy holds lines the repo no longer has - line-set-wise
# identical to somebody's local edit, so the conservative branch fired and --fix
# would never touch that file again. APPEND-ONLY GROWTH WAS THE ONLY STALENESS
# THE DETECTOR COULD SEE. Measured on a live machine: an installed command and a
# whole skill tree reported DIVERGED when they were merely OLD.
#
# Four history fixtures, and each has its inverse control in the same scenario,
# because a history test that answers "old release" too readily is a SILENT
# CLOBBER and would look exactly like success:
#   · installed == an ancestor version, newest version REMOVED lines  ⇒ stale,
#     and --fix refreshes it. Beside it: content that never existed in that
#     path's history ⇒ diverged, and byte-identical after --fix.
#   · installed == an ancestor version of the OTHER source root (a name that
#     moved between the framework repo and the personal overlay) ⇒ stale.
#     Beside it: content in NEITHER root's history ⇒ diverged, untouched.
#   · history deeper than the revision cap, match older than the cap ⇒ reported
#     as "no match in the last N revisions", NEVER as a bare diverged. Beside
#     it: the same file with the cap raised ⇒ stale, which is what proves the
#     cap was the only reason.
#   · no .git at all ⇒ the subset test, and the report SAYS that is what decided
#     it. A verdict whose basis is unstated is worse than a coarse verdict.
#
#   bash install-doctor-staleness.test.sh      (DOCTOR=/path/to/install-doctor.sh)
#
# ⛔ EVERY CASE RUNS UNDER A FAKE $HOME AND A FAKE REPO, BY CONSTRUCTION. The
# doctor derives the repo from its OWN location ($HERE/../..) and the live config
# from $CLAUDE_CONFIG_DIR, so the doctor is COPIED into a scratch repo whose
# commands and skills this battery writes. Run against the real tree it would
# report the machine's real drift, and every assertion below would depend on how
# behind the person running it happens to be - not merely leaky: green or red for
# reasons that have nothing to do with the code.
#
# ⚠️ A MISSING PREREQUISITE EXITS 2, NOT 0 - "could not run the detector" must
# never be reported as "the detector is fine". 0 = green, 1 = a real failure,
# 2 = did not run.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DOCTOR="${DOCTOR:-$HERE/../../../scripts/install-doctor.sh}"

[ -f "$DOCTOR" ] || { echo "install-doctor.sh not found at $DOCTOR - set DOCTOR=/path/to/it"; exit 2; }
# ⛔ git included: the history fixtures need real commits, and a battery that
# silently stops exercising the history test would be the invisible fault again.
for t in awk cmp diff find git; do
	command -v "$t" >/dev/null 2>&1 || { echo "no $t - the detector cannot be exercised"; exit 2; }
done

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/doctor-stale-test.XXXXXX") || {
	echo "could not create a temp dir - refusing to run against the real ~/.claude"; exit 2; }
cleanup() { [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT INT TERM HUP

pass=0; fail=0
ok()    { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()   { fail=$((fail+1)); printf '  FAIL %s\n         want: %s\n         got:  %s\n' "$1" "$2" "$3"; }
clip()  { printf '%s' "$1" | tr '\n' '|' | cut -c1-400; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "output contains '$2'" "$(clip "$3")" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1" "output does NOT contain '$2'" "$(clip "$3")" ;; *) ok "$1" ;; esac; }

# The whole fixture: a scratch repo with the doctor inside it, and a scratch
# ~/.claude beside it. Rebuilt from scratch per scenario, because --fix mutates
# it and a second scenario must not inherit the first one's repairs.
REPO="" CFG="" FHOME="" HCAP=""
build() {
	FHOME=$(mktemp -d "$TMPROOT/home.XXXXXX") || return 1
	HCAP=""                       # per-scenario revision cap; empty = the script's own default
	REPO="$FHOME/repo"; CFG="$FHOME/.claude"
	mkdir -p "$REPO/claude-setup/scripts" "$REPO/claude-setup/commands" "$REPO/skills" \
	         "$REPO/claude-setup/config" "$REPO/agents" "$CFG/commands" "$CFG/skills"
	cp "$DOCTOR" "$REPO/claude-setup/scripts/install-doctor.sh"

	# ── the four command fixtures, one per state the detector must distinguish ──
	# repo copies. Each has a section a stale install would be missing.
	printf 'line one\nline two\nline three\nthe rule that landed later\n' > "$REPO/claude-setup/commands/stale.md"
	printf 'line one\nline two\nline three\nthe rule that landed later\n' > "$REPO/claude-setup/commands/diverged.md"
	printf 'line one\nline two\nline three\nthe rule that landed later\n' > "$REPO/claude-setup/commands/current.md"
	printf 'line one\nline two\nline three\nthe rule that landed later\n' > "$REPO/claude-setup/commands/linked.md"
	printf 'line one\nline two\n' > "$REPO/claude-setup/commands/absent.md"

	# ⛔ NEGATIVE CONTROL. A STRICT SUBSET: every line is in the repo copy, and
	# the repo copy has a line this lacks. Exactly the shape measured on the real
	# machine (0 lines of its own). The detector MUST call this stale.
	printf 'line one\nline two\nline three\n' > "$CFG/commands/stale.md"
	# DIVERGED: a line of its own, so it may be somebody's deliberate edit.
	printf 'line one\nline two\nmy own local tweak\n' > "$CFG/commands/diverged.md"
	# CURRENT: byte-identical. Must not be named.
	cp "$REPO/claude-setup/commands/current.md" "$CFG/commands/current.md"
	# LINKED: tracks the repo by construction. Must not be named.
	ln -s "$REPO/claude-setup/commands/linked.md" "$CFG/commands/linked.md"
	# absent.md is deliberately not installed.

	# ── the skill fixtures: a tree is judged per file ──────────────────────────
	mkdir -p "$REPO/skills/stale-skill" "$REPO/skills/diverged-skill" \
	         "$CFG/skills/stale-skill" "$CFG/skills/diverged-skill"
	printf 'name: x\nbody one\nbody two\nthe guard that landed later\n' > "$REPO/skills/stale-skill/SKILL.md"
	printf 'name: y\nbody one\nbody two\nthe guard that landed later\n' > "$REPO/skills/diverged-skill/SKILL.md"
	# ⛔ NEGATIVE CONTROL, tree edition: a subset SKILL.md and nothing of its own.
	printf 'name: x\nbody one\nbody two\n' > "$CFG/skills/stale-skill/SKILL.md"
	# DIVERGED: SKILL.md is a mere subset, but the tree holds a file the repo
	# does not ship at all. A skill is replaced WHOLE, so that file is precisely
	# what a refresh would destroy - the tree must be left alone entirely.
	printf 'name: y\nbody one\nbody two\n' > "$CFG/skills/diverged-skill/SKILL.md"
	printf 'a script I wrote myself\n' > "$CFG/skills/diverged-skill/mine.sh"

	# ── the top-level config fixtures, one per state, at $CFG's own level ──────
	# The four names are setup.sh's: the two statusline twins, supermode.settings.json
	# and CLAUDE.md (from CLAUDE.global.md, or agents/CLAUDE.md when no root ships one).
	printf '#!/bin/sh\nread -r line\necho one\necho the segment that landed later\n' > "$REPO/claude-setup/config/statusline-command.sh"
	printf 'const a = 1\nconst b = 2\nconsole.log(a)\n// the segment that landed later\n'  > "$REPO/claude-setup/config/statusline-command.js"
	printf '{\n  "permissions": {},\n  "env": {}\n}\n'                                    > "$REPO/claude-setup/config/supermode.settings.json"
	printf '# rules\none\ntwo\nthe rule that landed later\n'                              > "$REPO/claude-setup/config/CLAUDE.global.md"
	chmod +x "$REPO/claude-setup/config/statusline-command.sh" "$REPO/claude-setup/config/statusline-command.js"

	# ⛔ THE LIVE SHAPE THAT WAS MISSED: a stale strict-subset PLAIN COPY, sitting
	# where the sibling userland has a symlink. Executable, as the installer left it.
	printf 'const a = 1\nconst b = 2\nconsole.log(a)\n' > "$CFG/statusline-command.js"
	chmod +x "$CFG/statusline-command.js"
	# INVERSE CONTROL: its twin, installed as a symlink into the repo. Must not be named.
	ln -s "$REPO/claude-setup/config/statusline-command.sh" "$CFG/statusline-command.sh"
	# INVERSE CONTROL: byte-identical copy of the overlay. Must not be named.
	cp "$REPO/claude-setup/config/CLAUDE.global.md" "$CFG/CLAUDE.md"
	# DIVERGED: a line of its own, so --fix must not touch it.
	printf '{\n  "permissions": {},\n  "myOwnKey": true\n}\n' > "$CFG/supermode.settings.json"
}

# gitify <dir> - turn a scratch directory into a REAL git repo. The history test
# can only be exercised against real history, and a fake would test nothing.
# ⛔ core.hooksPath is neutralised and identity/signing pinned locally: this
# machine may have a global hooks path and a signing key, and a fixture commit
# must neither run the person's hooks nor need their key.
gitify() {
	git -C "$1" init -q >/dev/null 2>&1 || return 1
	git -C "$1" config user.email fixture@example.invalid || return 1
	git -C "$1" config user.name "staleness battery" || return 1
	git -C "$1" config commit.gpgsign false || return 1
	git -C "$1" config core.autocrlf false || return 1
	git -C "$1" config core.hooksPath "$1/.git/hooks-disabled" || return 1
}
commit_all() {  # <dir> <message>
	git -C "$1" add -A >/dev/null 2>&1 || return 1
	git -C "$1" commit -q -m "$2" >/dev/null 2>&1
}

# not_subset <installed> <repo copy> - 0 when <installed> holds at least one line
# the repo copy does not. That is EXACTLY the condition under which the old
# subset-only predicate answered "diverged", so asserting it proves a history
# fixture really reproduces the gap instead of passing for some other reason.
not_subset() {
	awk 'FNR==NR { r[$0]=1; next } !($0 in r) { f=1 } END { exit f ? 0 : 1 }' "$2" "$1"
}

# Run the doctor against the fixture and print only check 8's lines, so an
# unrelated finding on the machine running this battery cannot match an assertion.
# ⛔ GIT_CEILING_DIRECTORIES pins the fixtures' history to the fixtures. Without
# it, a non-git fixture under a TMPDIR that happens to sit inside somebody's
# checkout would find THAT repo's history and the no-history case would pass or
# fail for a reason nothing here controls.
only8() {
	grep -E 'STALE|DIVERGED|commands/skills|never installed|refreshed|CANNOT VERIFY|match the repo|no match in the last' || true
}
run() {
	if [ -n "$HCAP" ]; then
		env HOME="$FHOME" CLAUDE_CONFIG_DIR="$CFG" GIT_CEILING_DIRECTORIES="$TMPROOT" \
			DOCTOR_HISTORY_CAP="$HCAP" \
			bash "$REPO/claude-setup/scripts/install-doctor.sh" "$@" 2>&1 | only8
	else
		env HOME="$FHOME" CLAUDE_CONFIG_DIR="$CFG" GIT_CEILING_DIRECTORIES="$TMPROOT" \
			bash "$REPO/claude-setup/scripts/install-doctor.sh" "$@" 2>&1 | only8
	fi
}

# ── 1+3+4+5: what a report names, and what it must not ───────────────────────
echo "the report, on a fixture that is stale, diverged, current, linked and missing:"
build || { echo "could not build the fixture"; exit 2; }
out=$(run)
has   "⛔ negative control: the stale command IS named"        "commands/stale.md"        "$out"
has   "it says STALE of it, not merely 'differs'"             "STALE"                    "$out"
has   "⛔ negative control: the stale skill tree IS named"     "skills/stale-skill"       "$out"
has   "the diverged command is named"                         "commands/diverged.md"     "$out"
has   "the diverged skill tree is named"                      "skills/diverged-skill"    "$out"
has   "it says DIVERGED, a different answer from stale"       "DIVERGED"                 "$out"
has   "the shipped-but-uninstalled command is named"          "commands/absent.md"       "$out"
has   "it says so in its own words, not as staleness"         "never installed"          "$out"
hasnt "a byte-identical copy is NOT flagged"                  "commands/current.md"      "$out"
hasnt "a symlink into the repo is NOT flagged"                "commands/linked.md"       "$out"
# The stale ones must be offered a fix, and the diverged ones must not be.
has   "it names the switch that repairs the stale ones"       "--fix"                    "$out"
has   "it says the diverged ones are not refreshable"         "not refreshable"          "$out"
# ── the top-level files, i.e. the gap: a status line 5 KB behind the repo ─────
has   "⛔ the STALE top-level config COPY is named"            "config/statusline-command.js"   "$out"
has   "the DIVERGED top-level config file is named"           "config/supermode.settings.json" "$out"
hasnt "⛔ inverse control: a SYMLINKED top-level file is NOT flagged"  "config/statusline-command.sh" "$out"
hasnt "⛔ inverse control: an IDENTICAL top-level file is NOT flagged" "config/CLAUDE.md"             "$out"
# ── the basis, on a source root with no .git at all ───────────────────────────
# ⛔ This fixture is a plain directory: no history to ask, so the verdicts above
# came from the line subset test alone - which can only see staleness that ADDED
# lines. That is a legitimate install shape (a tarball, a copied tree, a root in
# a spelling this filesystem cannot open) and the report must SAY which test
# answered. A verdict whose basis is unstated is worse than a coarse verdict.
has   "⛔ it names the test that decided, when there is no history to ask" "LINE-SUBSET" "$out"
has   "...and says why that is what it fell back to"          "no readable git history"   "$out"
hasnt "...and does not claim to have searched any history"    "REPO HISTORY"             "$out"

# ── a fixture with nothing wrong must read clean, or the check is noise ──────
echo
echo "the report, on a fixture where everything matches:"
build || exit 2
cp "$REPO/claude-setup/commands/stale.md"       "$CFG/commands/stale.md"
cp "$REPO/claude-setup/commands/diverged.md"    "$CFG/commands/diverged.md"
cp "$REPO/claude-setup/commands/absent.md"      "$CFG/commands/absent.md"
cp "$REPO/skills/stale-skill/SKILL.md"          "$CFG/skills/stale-skill/SKILL.md"
cp "$REPO/skills/diverged-skill/SKILL.md"       "$CFG/skills/diverged-skill/SKILL.md"
rm -f "$CFG/skills/diverged-skill/mine.sh"
# and the top-level files: the stale copy refreshed, the diverged one reverted.
# (statusline-command.sh stays a symlink and CLAUDE.md is already identical, so
# this fixture covers link / same / current-copy at once.)
cp "$REPO/claude-setup/config/statusline-command.js"   "$CFG/statusline-command.js"
cp "$REPO/claude-setup/config/supermode.settings.json" "$CFG/supermode.settings.json"
out=$(run)
hasnt "nothing is called stale"                               "STALE"                    "$out"
hasnt "nothing is called diverged"                            "DIVERGED"                 "$out"
hasnt "nothing is called uninstalled"                         "never installed"          "$out"
has   "it says so positively, rather than staying silent"     "match the repo"            "$out"
hasnt "nothing is called unverifiable either"                 "CANNOT VERIFY"             "$out"

# ── shipped-but-never-installed, and the twin that is NOT a fault ────────────
# ⛔ The false positive to avoid: setup.sh installs the .sh on POSIX and setup.ps1
# the .js on Windows, so a machine that has one legitimately lacks the other.
echo
echo "a top-level config file nothing ever installed, and the twin that is not a fault:"
build || exit 2
rm -f "$CFG/supermode.settings.json"
rm -f "$CFG/statusline-command.sh"
out=$(run)
has   "the uninstalled top-level config file is named"        "config/supermode.settings.json" "$out"
has   "...in its own words, not as staleness"                 "never installed"                "$out"
hasnt "⛔ the statusline twin this OS does not install is NOT called uninstalled" "config/statusline-command.sh" "$out"
# ...but with NEITHER twin installed there is no status line at all, and that IS
# a finding: the suppression must be conditional, not a permanent blind spot.
rm -f "$CFG/statusline-command.js"
out=$(run)
has   "with NEITHER twin installed the status line IS named"  "config/statusline-command.sh"   "$out"

# ── the fallback source: setup.sh's own precedence for one destination ───────
# $CFG/CLAUDE.md comes from claude-setup/config/CLAUDE.global.md, and from
# agents/CLAUDE.md only when NO root ships one. Judging it against the wrong
# source is how a correct file gets called diverged.
echo
echo "with no CLAUDE.global.md shipped, the overlay is judged against agents/CLAUDE.md:"
build || exit 2
rm -f "$REPO/claude-setup/config/CLAUDE.global.md"
printf '# rules\none\ntwo\nthe rule that landed later\n' > "$REPO/agents/CLAUDE.md"
printf '# rules\none\ntwo\n' > "$CFG/CLAUDE.md"
out=$(run)
has   "the overlay is named against the fallback source"      "config/CLAUDE.md"          "$out"
has   "...as STALE, so --fix may refresh it"                  "STALE"                     "$out"

# ── not line-oriented text: unknown, said out loud, never guessed at ────────
# ⛔ subset_of compares LINES. Against a binary or generated blob that comparison
# means nothing, so "stale" about one would be a confident wrong answer - and a
# confident wrong answer is worse than a red, because nobody re-checks it.
echo
echo "a top-level config file that is not line-oriented text:"
build || exit 2
printf '{\000"binary": true}\n' > "$REPO/claude-setup/config/supermode.settings.json"
printf '{\000"binary": false}\n' > "$CFG/supermode.settings.json"
out=$(run)
has   "it says CANNOT VERIFY of it"                           "CANNOT VERIFY"                  "$out"
# ⚠️ Asserted against the STALE LINE ALONE, not the whole report: the fixture has
# genuinely stale commands and skills, so "STALE" appears either way and a check
# for its absence would pass for the wrong reason.
sline=$(printf '%s\n' "$out" | grep 'STALE - installed' || true)
hasnt "and the STALE list does NOT name it"                   "supermode.settings.json"        "$sline"
has   "while the line-oriented staleness is still reported"   "config/statusline-command.js"   "$sline"

# ── a personal root this filesystem cannot open ──────────────────────────────
# ⛔ The third cross-filesystem false positive, refused before it exists. Pointed
# at the OTHER userland's HOME, the path file there names that side's spelling of
# the repo. Unopenable is NOT missing, and the report must say which.
echo
echo "an ai-memory-path this filesystem cannot open:"
build || exit 2
printf 'Z:/nowhere/this/cannot/open\n' > "$CFG/ai-memory-path"
out=$(run)
has   "it says CANNOT VERIFY of the personal root"            "CANNOT VERIFY"                  "$out"
has   "...and says unopenable is not missing, in those words" "NOT missing"                    "$out"
# ⚠️ The other half of the same requirement: refusing to guess must not turn into
# refusing to run. Everything the FRAMEWORK root ships is still judged.
has   "and every other check still ran on the framework root" "commands/stale.md"              "$out"

# ── HISTORY, case 1: the shape the subset test structurally cannot see ───────
# ⛔ THE BUG THIS EXISTS FOR, reproduced exactly. An upstream commit REMOVES
# lines; the un-refreshed copy therefore holds lines the repo no longer has, and
# the line-subset test calls that a local edit - so --fix would never touch the
# file again, forever, silently. The fixture asserts the gap first (not_subset),
# so a green here cannot come from the fixture accidentally being a plain subset.
echo
echo "history: an installed copy that a later commit REMOVED lines from:"
build || exit 2
printf 'head\nSAMPLE LINE A\nSAMPLE LINE B\nSAMPLE LINE C\ntail\n' > "$REPO/claude-setup/commands/oldrelease.md"
printf 'head\nshipped line\n'                                      > "$REPO/claude-setup/commands/handedit.md"
# ⛔ AND THE TREE EDITION, because the live report was a SKILL directory, not a
# single file: tree_state judges a tree file by file, so the history test has to
# reach it there too or a whole skill stays un-refreshable.
mkdir -p "$REPO/skills/hist-skill" "$REPO/skills/hist-diverged" \
         "$CFG/skills/hist-skill" "$CFG/skills/hist-diverged"
printf 'name: h\nA SAMPLE THE NEXT COMMIT DROPS\nbody\n'          > "$REPO/skills/hist-skill/SKILL.md"
printf 'name: d\nbody\n'                                          > "$REPO/skills/hist-diverged/SKILL.md"
gitify "$REPO"                              || { echo "git init failed in the fixture"; exit 2; }
commit_all "$REPO" "the release that got installed" || { echo "fixture commit failed"; exit 2; }
# the copy that was installed from THAT release, byte for byte
cp "$REPO/claude-setup/commands/oldrelease.md" "$CFG/commands/oldrelease.md"
# ...and now the repo moves on by DELETING those lines.
printf 'head\ntail\nthe rule that landed later\n'                  > "$REPO/claude-setup/commands/oldrelease.md"
printf 'head\nshipped line\nand a line that landed later\n'        > "$REPO/claude-setup/commands/handedit.md"
cp "$REPO/skills/hist-skill/SKILL.md" "$CFG/skills/hist-skill/SKILL.md"
printf 'name: h\nbody\nthe guard that landed later\n'             > "$REPO/skills/hist-skill/SKILL.md"
printf 'name: d\nbody\nand more\n'                               > "$REPO/skills/hist-diverged/SKILL.md"
commit_all "$REPO" "an upstream commit that removes lines"         || { echo "fixture commit failed"; exit 2; }
# ⛔ INVERSE CONTROL, tree edition: a SKILL.md matching no version in history.
printf 'name: d\nbody I wrote myself\n'                           > "$CFG/skills/hist-diverged/SKILL.md"
# ⛔ INVERSE CONTROL, in the same scenario: content that matches NO version this
# path ever had. This is what stops the history test from becoming a silent
# clobber - without it, a test that answered "old release" to everything passes.
printf 'head\nsomething no version ever shipped\n'                 > "$CFG/commands/handedit.md"

if not_subset "$CFG/commands/oldrelease.md" "$REPO/claude-setup/commands/oldrelease.md"; then
	ok "⛔ the fixture really reproduces the gap: the installed copy holds lines the repo no longer has"
else
	bad "⛔ the fixture really reproduces the gap" "installed lines the repo copy lacks" "a plain subset - this would pass for the wrong reason"
fi
out=$(run)
sline=$(printf '%s\n' "$out" | grep 'STALE - installed' || true)
dline=$(printf '%s\n' "$out" | grep 'DIVERGED' || true)
has   "⛔ an exact past version is STALE, not diverged"        "commands/oldrelease.md"  "$sline"
hasnt "...and is NOT in the diverged list"                     "commands/oldrelease.md"  "$dline"
has   "the append-only subset case is unchanged by all this"   "commands/stale.md"       "$sline"
has   "⛔ inverse control: content no version ever had is DIVERGED" "commands/handedit.md" "$dline"
hasnt "...and is NOT offered as refreshable"                   "commands/handedit.md"    "$sline"
has   "⛔ the SKILL TREE edition of the same shape is STALE too"  "skills/hist-skill"      "$sline"
hasnt "...and the tree is NOT in the diverged list"            "skills/hist-skill"       "$dline"
has   "⛔ inverse control, tree edition: no version ever had it ⇒ DIVERGED" "skills/hist-diverged" "$dline"
has   "the report names the basis it used"                     "REPO HISTORY"            "$out"
has   "...and the diverged verdict says what it searched"      "matches no version in history" "$out"
has   "...with the depth it searched to"                       "newest 50 revisions"     "$out"

# --fix on the same fixture: refresh the old release, leave the other alone.
before_hand=$(cat "$CFG/commands/handedit.md")
before_hdiv=$(cat "$CFG/skills/hist-diverged/SKILL.md")
out=$(run --fix)
has "--fix refreshed the old release"                          "commands/oldrelease.md"  "$out"
if cmp -s "$CFG/commands/oldrelease.md" "$REPO/claude-setup/commands/oldrelease.md"; then
	ok "⛔ and it now matches the repo byte for byte - the shape no --fix could ever reach before"
else
	bad "⛔ the refreshed old release matches the repo byte for byte" "identical" "$(clip "$(cat "$CFG/commands/oldrelease.md")")"
fi
now_hand=$(cat "$CFG/commands/handedit.md")
[ "$now_hand" = "$before_hand" ] \
	&& ok "⛔ INVERSE CONTROL: --fix left the file matching no version byte-identical" \
	|| bad "⛔ INVERSE CONTROL: --fix left the file matching no version byte-identical" "$(clip "$before_hand")" "$(clip "$now_hand")"
if cmp -s "$CFG/skills/hist-skill/SKILL.md" "$REPO/skills/hist-skill/SKILL.md"; then
	ok "the skill tree that was an old release now matches the repo byte for byte"
else
	bad "the skill tree that was an old release now matches the repo" "identical" "$(clip "$(cat "$CFG/skills/hist-skill/SKILL.md")")"
fi
now_hdiv=$(cat "$CFG/skills/hist-diverged/SKILL.md")
[ "$now_hdiv" = "$before_hdiv" ] \
	&& ok "⛔ INVERSE CONTROL: --fix left the no-version-match SKILL.md byte-identical" \
	|| bad "⛔ INVERSE CONTROL: --fix left the no-version-match SKILL.md byte-identical" "$(clip "$before_hdiv")" "$(clip "$now_hdiv")"

# ── HISTORY, case 2: the OTHER source root's history counts too ──────────────
# ⛔ setup installs from the framework root AND the personal overlay, and the
# overlay WINS. Which root ships a given name has changed over time, so a copy
# can be an old release of the root that does NOT ship it any more. Searching
# only today's winner reintroduces the same false verdict one level up.
echo
echo "history: an old release that shipped from the OTHER source root:"
build || exit 2
PERS="$FHOME/personal"
mkdir -p "$PERS/claude-setup/commands"
printf 'head\nFRAMEWORK ONLY LINE A\nFRAMEWORK ONLY LINE B\ntail\n' > "$REPO/claude-setup/commands/crossroot.md"
printf 'head\nshipped line\n'                                       > "$REPO/claude-setup/commands/nomatch.md"
gitify "$REPO"                                     || { echo "git init failed"; exit 2; }
commit_all "$REPO" "the framework root shipped it" || { echo "fixture commit failed"; exit 2; }
# the copy installed from the FRAMEWORK root's release
cp "$REPO/claude-setup/commands/crossroot.md" "$CFG/commands/crossroot.md"
# the name now lives in the personal overlay, which wins src_for and whose own
# history never held that version...
printf 'head\ntail\nthe personal overlay version\n'                 > "$PERS/claude-setup/commands/crossroot.md"
printf 'head\nshipped line\nand more from the overlay\n'            > "$PERS/claude-setup/commands/nomatch.md"
gitify "$PERS"                                     || { echo "git init failed"; exit 2; }
commit_all "$PERS" "the personal overlay ships it now" || { echo "fixture commit failed"; exit 2; }
# ...and the framework root drops those lines too, so NOTHING current has them.
printf 'head\ntail\nthe framework root moved on\n'                  > "$REPO/claude-setup/commands/crossroot.md"
commit_all "$REPO" "the framework root drops them too" || { echo "fixture commit failed"; exit 2; }
printf '%s\n' "$PERS" > "$CFG/ai-memory-path"
# ⛔ INVERSE CONTROL: content in NEITHER root's history.
printf 'head\nnothing in either root ever shipped this\n'           > "$CFG/commands/nomatch.md"

out=$(run)
sline=$(printf '%s\n' "$out" | grep 'STALE - installed' || true)
dline=$(printf '%s\n' "$out" | grep 'DIVERGED' || true)
has   "⛔ an old release of the root that no longer ships it is STALE" "commands/crossroot.md" "$sline"
hasnt "...and is NOT reported as diverged"                      "commands/crossroot.md"  "$dline"
has   "⛔ inverse control: no match in EITHER root is DIVERGED" "commands/nomatch.md"    "$dline"
hasnt "...and is NOT offered as refreshable"                   "commands/nomatch.md"    "$sline"
has   "the report NAMES both roots it searched, so the claim is checkable" "personal + repo" "$out"
before_nm=$(cat "$CFG/commands/nomatch.md")
out=$(run --fix)
if cmp -s "$CFG/commands/crossroot.md" "$PERS/claude-setup/commands/crossroot.md"; then
	ok "--fix refreshed it from the root that ships it TODAY, not the one it matched"
else
	bad "--fix refreshed it from the root that ships it TODAY" "identical to the overlay copy" "$(clip "$(cat "$CFG/commands/crossroot.md")")"
fi
now_nm=$(cat "$CFG/commands/nomatch.md")
[ "$now_nm" = "$before_nm" ] \
	&& ok "⛔ INVERSE CONTROL: --fix left the no-match-anywhere file byte-identical" \
	|| bad "⛔ INVERSE CONTROL: --fix left the no-match-anywhere file byte-identical" "$(clip "$before_nm")" "$(clip "$now_nm")"

# ── HISTORY, case 3: deeper than the cap weakens the CLAIM, and it says so ───
# ⛔ The cost bound has to be honest about itself. Past the cap the path-scoped
# walk stops, so the strong claim ("an old release of THIS path") is no longer
# available - but the content can still be found in the repo's object store,
# which answers the weaker "this came from here, under some path". Refreshable
# either way; the two are NOT the same statement and the report separates them.
echo
echo "history deeper than the revision cap: the claim gets weaker, and says which:"
build || exit 2
printf 'head\nOLDEST ONLY A\nOLDEST ONLY B\ntail\n' > "$REPO/claude-setup/commands/deep.md"
gitify "$REPO"                                   || { echo "git init failed"; exit 2; }
commit_all "$REPO" "v1 - the version that got installed" || { echo "fixture commit failed"; exit 2; }
cp "$REPO/claude-setup/commands/deep.md" "$CFG/commands/deep.md"
i=2
while [ "$i" -le 5 ]; do
	printf 'head\ntail\nrevision %s\n' "$i" > "$REPO/claude-setup/commands/deep.md"
	commit_all "$REPO" "v$i - the oldest lines are long gone" || { echo "fixture commit failed"; exit 2; }
	i=$((i + 1))
done
HCAP=2                                   # 5 revisions exist; the match is the oldest
out=$(run)
wline=$(printf '%s\n' "$out" | grep 'no match in the last' || true)
dline=$(printf '%s\n' "$out" | grep 'DIVERGED' || true)
has   "it says how far back the path walk looked, in those words" "no match in the last 2 revisions" "$out"
has   "...and names the file on that line"                     "commands/deep.md"        "$wline"
has   "...and says which claim it is making instead"           "CONTENT match, not a path match" "$wline"
hasnt "⛔ and does NOT report it as a bare DIVERGED"            "commands/deep.md"        "$dline"
# ⭐ THE CONTROL THAT PROVES THE CAP WAS THE ONLY THING IN THE WAY. Raise it and
# the SAME file earns the strong claim, with no weaker-claim line at all.
HCAP=50
out=$(run)
sline=$(printf '%s\n' "$out" | grep 'STALE - installed' || true)
has   "⭐ with the cap raised the SAME file is a path match"    "commands/deep.md"        "$sline"
hasnt "...and the weaker-claim line is gone entirely"          "no match in the last"    "$out"
# and either way --fix may refresh it: an old release is an old release.
HCAP=2
out=$(run --fix)
if cmp -s "$CFG/commands/deep.md" "$REPO/claude-setup/commands/deep.md"; then
	ok "--fix refreshed it on the weaker claim too"
else
	bad "--fix refreshed it on the weaker claim too" "identical" "$(clip "$(cat "$CFG/commands/deep.md")")"
fi

# ── HISTORY, case 4: a RENAMED path, at the default cap ──────────────────────
# ⛔ A `git log -- <path>` walk cannot see a blob the path did not carry, and a
# rename is the everyday way that happens. This is the miss that produced a false
# "nobody ever shipped this" in the field, so it gets its own fixture at the
# DEFAULT cap - nothing here is cap-limited, the path walk simply cannot reach it.
echo
echo "a path that was RENAMED, so the path walk cannot reach the old blob:"
build || exit 2
printf 'head\nTHE LINE THE OLD PATH CARRIED\ntail\n' > "$REPO/claude-setup/commands/oldname.md"
gitify "$REPO"                                   || { echo "git init failed"; exit 2; }
commit_all "$REPO" "shipped under its first name" || { echo "fixture commit failed"; exit 2; }
cp "$REPO/claude-setup/commands/oldname.md" "$CFG/commands/newname.md"
git -C "$REPO" mv claude-setup/commands/oldname.md claude-setup/commands/newname.md >/dev/null 2>&1 \
	|| { echo "git mv failed"; exit 2; }
printf 'head\ntail\nrewritten under the new name\n' > "$REPO/claude-setup/commands/newname.md"
commit_all "$REPO" "renamed, and rewritten"      || { echo "fixture commit failed"; exit 2; }
out=$(run)
sline=$(printf '%s\n' "$out" | grep 'STALE - installed' || true)
dline=$(printf '%s\n' "$out" | grep 'DIVERGED' || true)
wline=$(printf '%s\n' "$out" | grep 'no match in the last' || true)
has   "⛔ the pre-rename blob is found, so the file is STALE"   "commands/newname.md"     "$sline"
hasnt "⛔ and NOT reported as content nobody ever shipped"      "commands/newname.md"     "$dline"
has   "...on the weaker claim, and the report says so"         "commands/newname.md"     "$wline"

# ── HISTORY, case 5: the cap reached AND no content match anywhere ───────────
# ⛔ "No match in the last N revisions" and "matches no version in history" are
# different statements. The object store is not a complete historical record (gc
# prunes, a shallow clone never had the old objects), so with path history left
# unread the answer is "did not find it that far back" - NOT refreshed, and NOT
# called diverged either. Printing the second when you mean the first is exactly
# the class of confident wrong answer this script exists to remove.
echo
echo "the cap reached with no content match anywhere: neither refreshed nor called diverged:"
build || exit 2
printf 'head\nv1\ntail\n' > "$REPO/claude-setup/commands/deep2.md"
gitify "$REPO"                                   || { echo "git init failed"; exit 2; }
commit_all "$REPO" "v1"                          || { echo "fixture commit failed"; exit 2; }
i=2
while [ "$i" -le 5 ]; do
	printf 'head\ntail\nrevision %s\n' "$i" > "$REPO/claude-setup/commands/deep2.md"
	commit_all "$REPO" "v$i"                     || { echo "fixture commit failed"; exit 2; }
	i=$((i + 1))
done
# content that was NEVER committed anywhere, under a path with 5 revisions
printf 'head\nnot in any commit and not in the object store\n' > "$CFG/commands/deep2.md"
HCAP=2
before_d2=$(cat "$CFG/commands/deep2.md")
out=$(run)
cline=$(printf '%s\n' "$out" | grep 'no match in the last' || true)
dline=$(printf '%s\n' "$out" | grep 'DIVERGED' || true)
sline=$(printf '%s\n' "$out" | grep 'STALE - installed' || true)
has   "it says how far it looked, in those words"              "no match in the last 2 revisions" "$cline"
has   "...and names the file there"                            "commands/deep2.md"       "$cline"
has   "...and says older path history went unread"             "older path history exists" "$cline"
hasnt "⛔ it is NOT reported as a bare DIVERGED"                "commands/deep2.md"       "$dline"
hasnt "nor as something --fix may refresh"                     "commands/deep2.md"       "$sline"
out=$(run --fix)
now_d2=$(cat "$CFG/commands/deep2.md")
[ "$now_d2" = "$before_d2" ] \
	&& ok "⛔ --fix left the unsearched-history file byte-identical" \
	|| bad "⛔ --fix left the unsearched-history file byte-identical" "$(clip "$before_d2")" "$(clip "$now_d2")"
# ⭐ CONTROL: with the cap raised past the whole history, the softening is gone
# and the same file is the definite DIVERGED it always was.
HCAP=50
out=$(run)
dline=$(printf '%s\n' "$out" | grep 'DIVERGED' || true)
has   "⭐ with the cap raised it becomes a definite DIVERGED"   "commands/deep2.md"       "$dline"
hasnt "...and the softened wording is gone"                    "no match in the last"    "$out"

# ── 2+6: --fix repairs the stale and does not touch the diverged ─────────────
echo
echo "--fix, on the mixed fixture:"
build || exit 2
before_div=$(cat "$CFG/commands/diverged.md")
before_mine=$(cat "$CFG/skills/diverged-skill/mine.sh")
before_divskill=$(cat "$CFG/skills/diverged-skill/SKILL.md")
before_sm=$(cat "$CFG/supermode.settings.json")
out=$(run --fix)
has "it says which stale command it refreshed"  "commands/stale.md"   "$out"
has "it says which stale skill it refreshed"    "skills/stale-skill"  "$out"
has "it says which stale config file it refreshed" "config/statusline-command.js" "$out"

if cmp -s "$CFG/commands/stale.md" "$REPO/claude-setup/commands/stale.md"; then
	ok "the stale command now matches the repo byte for byte"
else
	bad "the stale command now matches the repo byte for byte" "identical" "$(clip "$(cat "$CFG/commands/stale.md")")"
fi
if cmp -s "$CFG/skills/stale-skill/SKILL.md" "$REPO/skills/stale-skill/SKILL.md"; then
	ok "the stale skill now matches the repo byte for byte"
else
	bad "the stale skill now matches the repo byte for byte" "identical" "$(clip "$(cat "$CFG/skills/stale-skill/SKILL.md")")"
fi

# ⛔ The assertions this whole design exists for: --fix must not be able to eat
# somebody's local edit, in a file or anywhere inside a skill tree.
now_div=$(cat "$CFG/commands/diverged.md")
[ "$now_div" = "$before_div" ] \
	&& ok "⛔ --fix left the DIVERGED command exactly as it was" \
	|| bad "⛔ --fix left the DIVERGED command exactly as it was" "$(clip "$before_div")" "$(clip "$now_div")"
if [ -f "$CFG/skills/diverged-skill/mine.sh" ] && [ "$(cat "$CFG/skills/diverged-skill/mine.sh")" = "$before_mine" ]; then
	ok "⛔ --fix left the file the user wrote inside the diverged skill"
else
	bad "⛔ --fix left the file the user wrote inside the diverged skill" "$(clip "$before_mine")" "gone or changed"
fi
if cmp -s "$CFG/statusline-command.js" "$REPO/claude-setup/config/statusline-command.js"; then
	ok "the stale config file now matches the repo byte for byte"
else
	bad "the stale config file now matches the repo byte for byte" "identical" "$(clip "$(cat "$CFG/statusline-command.js")")"
fi
# ⚠️ A refresh copies CONTENT. Whether the live file is a copy or a symlink is
# setup's decision (LINK_HOOKS / LINK_CLAUDE_MD), so --fix must not quietly
# change that - nor drop the execute bit the status line is run by.
[ ! -L "$CFG/statusline-command.js" ] \
	&& ok "the refreshed file is still a copy, not silently converted to a symlink" \
	|| bad "the refreshed file is still a copy, not silently converted to a symlink" "a regular file" "a symlink"
[ -x "$CFG/statusline-command.js" ] \
	&& ok "and is still executable after the refresh" \
	|| bad "and is still executable after the refresh" "mode +x" "not executable"
[ -L "$CFG/statusline-command.sh" ] \
	&& ok "--fix left the symlinked twin a symlink" \
	|| bad "--fix left the symlinked twin a symlink" "a symlink" "replaced by a copy"
now_sm=$(cat "$CFG/supermode.settings.json")
[ "$now_sm" = "$before_sm" ] \
	&& ok "⛔ --fix left the DIVERGED config file exactly as it was" \
	|| bad "⛔ --fix left the DIVERGED config file exactly as it was" "$(clip "$before_sm")" "$(clip "$now_sm")"
now_divskill=$(cat "$CFG/skills/diverged-skill/SKILL.md")
[ "$now_divskill" = "$before_divskill" ] \
	&& ok "⛔ --fix did not refresh the diverged skill's own SKILL.md either" \
	|| bad "⛔ --fix did not refresh the diverged skill's own SKILL.md either" "$(clip "$before_divskill")" "$(clip "$now_divskill")"

# A second --fix must find nothing left to do: the repair has to be idempotent,
# or every session start would report and re-copy the same files forever.
out=$(run --fix)
hasnt "a second --fix finds nothing stale"                    "STALE"                    "$out"
hasnt "and does not re-refresh what it already fixed"         "refreshed commands"       "$out"
hasnt "nor re-refreshes the config file it already fixed"     "refreshed config"         "$out"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
