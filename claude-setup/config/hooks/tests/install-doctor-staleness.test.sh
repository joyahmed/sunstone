#!/usr/bin/env bash
# Regression battery for install-doctor.sh check 8 - the staleness detector for
# installed commands and skills.
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
for t in awk cmp diff find; do
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
REPO="" CFG="" FHOME=""
build() {
	FHOME=$(mktemp -d "$TMPROOT/home.XXXXXX") || return 1
	REPO="$FHOME/repo"; CFG="$FHOME/.claude"
	mkdir -p "$REPO/claude-setup/scripts" "$REPO/claude-setup/commands" "$REPO/skills" \
	         "$CFG/commands" "$CFG/skills"
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
}

# Run the doctor against the fixture and print only check 8's lines, so an
# unrelated finding on the machine running this battery cannot match an assertion.
run() {
	HOME="$FHOME" CLAUDE_CONFIG_DIR="$CFG" \
		bash "$REPO/claude-setup/scripts/install-doctor.sh" "$@" 2>&1 \
		| grep -E 'STALE|DIVERGED|commands/skills|never installed|refreshed' || true
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
out=$(run)
hasnt "nothing is called stale"                               "STALE"                    "$out"
hasnt "nothing is called diverged"                            "DIVERGED"                 "$out"
hasnt "nothing is called uninstalled"                         "never installed"          "$out"
has   "it says so positively, rather than staying silent"     "match the repo"            "$out"

# ── 2+6: --fix repairs the stale and does not touch the diverged ─────────────
echo
echo "--fix, on the mixed fixture:"
build || exit 2
before_div=$(cat "$CFG/commands/diverged.md")
before_mine=$(cat "$CFG/skills/diverged-skill/mine.sh")
before_divskill=$(cat "$CFG/skills/diverged-skill/SKILL.md")
out=$(run --fix)
has "it says which stale command it refreshed"  "commands/stale.md"   "$out"
has "it says which stale skill it refreshed"    "skills/stale-skill"  "$out"

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
now_divskill=$(cat "$CFG/skills/diverged-skill/SKILL.md")
[ "$now_divskill" = "$before_divskill" ] \
	&& ok "⛔ --fix did not refresh the diverged skill's own SKILL.md either" \
	|| bad "⛔ --fix did not refresh the diverged skill's own SKILL.md either" "$(clip "$before_divskill")" "$(clip "$now_divskill")"

# A second --fix must find nothing left to do: the repair has to be idempotent,
# or every session start would report and re-copy the same files forever.
out=$(run --fix)
hasnt "a second --fix finds nothing stale"                    "STALE"                    "$out"
hasnt "and does not re-refresh what it already fixed"         "refreshed commands"       "$out"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
