#!/bin/sh
# sunstone verification gate.
#
# WHAT THIS REPO CAN AND CANNOT VERIFY. There is no package.json, no build and
# no linter. 48 tracked files: 14 .sh, 16 .mjs/.js, 3 .ps1, 2 .py, 2 .json and
# the docs. So tiers 1-4 are SYNTAX AND CONFIG VALIDITY, not correctness -
# nothing there proves a hook does the right thing, only that it parses.
#
# TIER 5 IS DIFFERENT AND IT IS THE POINT. This repo ships the hooks that run in
# EVERY session on EVERY machine, and it now has behaviour tests for them
# (claude-setup/config/hooks/tests/*.test.sh). A hook that parses and still eats
# a push, a commit or a session is exactly the failure syntax cannot see, so the
# batteries run here and a failing one turns the whole gate RED.
#
# WHY IT IS WORTH HAVING AT ALL: a syntax error or a behaviour regression in one
# .mjs here does not break this repo - it breaks sessions on three boxes, after
# setup.sh has already copied it there. That is the failure this catches.
#
# TIERS (this repo is small enough that all of it is seconds):
#   1 node --check      every tracked .mjs/.js
#   2 bash -n           every tracked .sh
#   3 ast.parse         every tracked .py
#   4 json.load         every tracked .json
#   5 hook batteries    claude-setup/config/hooks/tests/*.test.sh, 0 failures
#
# ⚠️ NOT CHECKED, and no tier pretends otherwise: the 3 .ps1 files (a parse
# check needs pwsh, which is not on the boxes this usually runs on), and every
# .md. Those are OUT OF SCOPE, not skips: no tier claims them, so no tier can
# fail to run them, and they never move the verdict. A SKIP is different - it is
# a tier that was supposed to run and could not.
#
# ⛔ THE VERDICT INVARIANT. Exit 0 requires ALL THREE:
#     EXECUTED > 0   at least one tier actually checked something
#     RED == 0       nothing that ran failed
#     SKIPPED == 0   nothing that should have run was missed
# Any skip at all means INCOMPLETE means exit 1. A gate that can exit 0 with a
# nonzero skip count is a gate that can LIE: it prints GREEN for work it never
# did. This script used to do exactly that - with node, python3 and bash all
# absent it skipped every tier, printed the skip list, then printed GREEN and
# exited 0, and the pre-push hook read that 0 as "verified".
#
# Usage: sh claude-setup/scripts/verify.sh [--quick]
#   --quick skips tier 5 (the batteries spawn processes and are the slow tier).
#   ⚠️ --quick therefore CANNOT exit 0 - a deliberately narrowed run is still a
#   narrowed run. Use it to see tiers 1-4 fast, never as a gate.

set -u

# ⛔ Precondition, not a tier. Every tier below enumerates its files with
# `git ls-files`, so without git (or outside a work tree) each one would find
# ZERO files and print GREEN - a total absence of checking, rendered as a pass.
# That is the exact failure this script exists to refuse, so say it and stop.
# Under a git hook this cannot fire: git is the process running us.
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT=""
if [ -z "$ROOT" ]; then
	printf '⛔ cannot verify: no git, or not inside a work tree. Nothing was checked.\n' >&2
	exit 1
fi
cd "$ROOT" || exit 1

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

# --- node, through nvm if that is the only place it lives --------------------
# ⛔ Git runs hooks with a minimal environment and an nvm-installed node is not
# on it, so `command -v node` fails under a hook even on a box where node works
# fine interactively. A gate that always skips is indistinguishable from no
# gate. Resolve it here. (The rc file defines node as a lazy SHELL FUNCTION and
# never puts nvm's bin on PATH, so a non-interactive shell has no node at all.)
if ! command -v node >/dev/null 2>&1; then
	# ⚠️ ${HOME:-}, not $HOME. With `set -u` an unset HOME aborts the whole
	# script, and a hook environment can be that bare (`env -i` reproduces it
	# exactly). A verification gate that DIES is worse than one that skips: the
	# caller cannot tell the difference between "died" and "found something".
	NVM_DIR="${NVM_DIR:-${HOME:-}/.nvm}"
	if [ -d "$NVM_DIR/versions/node" ]; then
		ALIAS=""
		[ -f "$NVM_DIR/alias/default" ] && ALIAS=$(head -n1 "$NVM_DIR/alias/default" 2>/dev/null)
		CAND=""
		[ -n "$ALIAS" ] && [ -x "$NVM_DIR/versions/node/$ALIAS/bin/node" ] && CAND="$NVM_DIR/versions/node/$ALIAS/bin"
		[ -z "$CAND" ] && [ -n "$ALIAS" ] && [ -x "$NVM_DIR/versions/node/v$ALIAS/bin/node" ] && CAND="$NVM_DIR/versions/node/v$ALIAS/bin"
		[ -z "$CAND" ] && CAND=$(ls -d "$NVM_DIR"/versions/node/*/bin 2>/dev/null | tail -n1)
		[ -n "$CAND" ] && [ -x "$CAND/node" ] && PATH="$CAND:$PATH" && export PATH
	fi
fi

# --- the three counters the verdict is made of -------------------------------
# EXECUTED is bumped by a tier that actually ran over at least one file or
# battery. SKIPS is bumped ONLY inside note_skipped, so a new skip path cannot
# be added without the count following it - that was the old bug: the skip LIST
# existed and was printed, and the verdict simply did not look at it.
RED=0
EXECUTED=0
SKIPS=0
SKIPPED=""
note_skipped() { SKIPS=$((SKIPS+1)); SKIPPED="$SKIPPED  - $1 ($2)
"; }
note_skip() { note_skipped "$1" "tool missing: $2"; }
note_notrun() { note_skipped "$1" "did not run: $2"; }

# ⛔ A tier that matched ZERO files verified nothing, and printing GREEN there
# is the same lie in miniature - so it prints EMPTY instead. It is not a SKIP
# (no tool was missing, nothing was prevented from running), so it does not fail
# the run by itself; it just never counts as EXECUTED. That is what makes the
# all-empty case - the one the git precondition above describes - fall out of
# the verdict as a failure rather than as a pass.
tier_status() {
	if [ "$2" != 0 ]; then printf 'RED (%s)' "$2"
	elif [ "$1" = 0 ]; then printf 'EMPTY (no tracked files)'
	else printf 'GREEN'; fi
}
tier_ran() { [ "$1" != 0 ] && EXECUTED=$((EXECUTED+1)); return 0; }

hr() { printf '%s\n' "------------------------------------------------------------"; }

# --- tier 1: node --check ----------------------------------------------------
if command -v node >/dev/null 2>&1; then
	n=0; bad=0
	for f in $(git ls-files '*.mjs' '*.js' | grep -v node_modules); do
		n=$((n+1))
		node --check "$f" >/dev/null 2>&1 || { printf 'RED  node --check %s\n' "$f"; node --check "$f" 2>&1 | head -3; bad=$((bad+1)); }
	done
	printf 'T1 node --check    %3d file(s)  %s\n' "$n" "$(tier_status "$n" "$bad")"
	RED=$((RED+bad)); tier_ran "$n"
else
	note_skip "T1 node --check" node
	printf 'T1 node --check    SKIPPED (no node)\n'
fi

# --- tier 2: bash -n ---------------------------------------------------------
if command -v bash >/dev/null 2>&1; then
	n=0; bad=0
	for f in $(git ls-files '*.sh'); do
		n=$((n+1))
		bash -n "$f" >/dev/null 2>&1 || { printf 'RED  bash -n %s\n' "$f"; bash -n "$f" 2>&1 | head -3; bad=$((bad+1)); }
	done
	printf 'T2 bash -n         %3d file(s)  %s\n' "$n" "$(tier_status "$n" "$bad")"
	RED=$((RED+bad)); tier_ran "$n"
else
	note_skip "T2 bash -n" bash
	printf 'T2 bash -n         SKIPPED (no bash)\n'
fi

# --- tier 3: python syntax ---------------------------------------------------
# ⛔ NOT py_compile. py_compile writes __pycache__ next to each source, so the
# gate would dirty the tree it is supposed to be guarding (and the obvious
# "clean up afterwards" line then deletes files in a tree it does not own).
# ast.parse is the same syntax check and writes nothing.
if command -v python3 >/dev/null 2>&1; then
	n=0; bad=0
	for f in $(git ls-files '*.py'); do
		n=$((n+1))
		python3 -c 'import ast,sys; ast.parse(open(sys.argv[1],encoding="utf-8").read(), sys.argv[1])' "$f" >/dev/null 2>&1 \
			|| { printf 'RED  python syntax %s\n' "$f"; python3 -c 'import ast,sys; ast.parse(open(sys.argv[1],encoding="utf-8").read(), sys.argv[1])' "$f" 2>&1 | tail -2; bad=$((bad+1)); }
	done
	printf 'T3 python syntax   %3d file(s)  %s\n' "$n" "$(tier_status "$n" "$bad")"
	RED=$((RED+bad)); tier_ran "$n"
else
	note_skip "T3 python syntax" python3
	printf 'T3 python syntax   SKIPPED (no python3)\n'
fi

# --- tier 4: JSON ------------------------------------------------------------
# ⚠️ Nothing is excluded here, unlike the personal repo's gate which has to skip
# a directory of JSONC. Both tracked .json files in this repo are strict JSON
# and are MERGE TEMPLATES copied into a real settings.json by setup - a comment
# added to one would be parsed by the merge scripts as JSON and break setup on
# every machine, so strict is the correct check, not an accident.
if command -v python3 >/dev/null 2>&1; then
	n=0; bad=0
	for f in $(git ls-files '*.json'); do
		n=$((n+1))
		python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" >/dev/null 2>&1 \
			|| { printf 'RED  json %s\n' "$f"; bad=$((bad+1)); }
	done
	printf 'T4 json.load       %3d file(s)  %s\n' "$n" "$(tier_status "$n" "$bad")"
	RED=$((RED+bad)); tier_ran "$n"
else
	note_skip "T4 json.load" python3
	printf 'T4 json.load       SKIPPED (no python3)\n'
fi

# --- tier 5: hook behaviour batteries ----------------------------------------
# The batteries are looped HERE rather than through their own run-all.sh, for
# one reason: a battery that exits 2 did NOT RUN (missing interpreter, missing
# hook) and has to reach the SKIPPED list at the bottom, so the final verdict
# narrows. run-all.sh reports that on its own stdout, but its exit status is
# pass/fail only - going through it would let a battery that never ran read as a
# pass, which is the one thing this script must never do.
if [ "$QUICK" = "1" ]; then
	# ⛔ Counted like any other skip, on purpose. --quick is the caller choosing a
	# narrower run, and a narrower run is still a narrower run: it cannot be
	# allowed to exit 0, or "pass the gate quickly" becomes the way past the gate.
	note_skipped "T5 hook batteries" "--quick was passed"
	printf 'T5 hook batteries  SKIPPED (--quick)\n'
elif ! command -v bash >/dev/null 2>&1; then
	note_skip "T5 hook batteries" bash
	printf 'T5 hook batteries  SKIPPED (no bash)\n'
else
	TESTS=claude-setup/config/hooks/tests
	n=0; bad=0; skip=0; asserts=0
	for t in "$TESTS"/*.test.sh; do
		[ -f "$t" ] || continue          # the glob itself when the directory is empty
		n=$((n+1))
		OUT=$(bash "$t" 2>&1 </dev/null); rc=$?
		# Each battery ends with a "pass=N fail=M" line. Count the assertions so a
		# battery that quietly stops testing shows up as a number that dropped.
		P=$(printf '%s' "$OUT" | sed -n 's/^pass=\([0-9][0-9]*\).*/\1/p' | tail -n1)
		[ -n "$P" ] && asserts=$((asserts+P))
		case "$rc" in
			0) ;;
			2) skip=$((skip+1))
			   note_notrun "T5 $(basename "$t")" "$(printf '%s' "$OUT" | tail -n1)"
			   printf 'T5   %s  DID NOT RUN - %s\n' "$(basename "$t")" "$(printf '%s' "$OUT" | tail -n1)" ;;
			*) bad=$((bad+1))
			   printf 'RED  %s (exit %s)\n' "$t" "$rc"
			   printf '%s\n' "$OUT" | grep -E '^(FAIL|  FAIL|pass=)' | head -10 ;;
		esac
	done
	if [ "$n" = 0 ]; then
		note_skip "T5 hook batteries" "no *.test.sh under $TESTS"
		printf 'T5 hook batteries  SKIPPED (no batteries found)\n'
	else
		# ⛔ GREEN only when every battery both ran AND passed. A battery that did
		# not run is PARTIAL, never GREEN - the whole point of printing skips is
		# lost the moment a skip is allowed to wear the word for a pass.
		if [ "$bad" != 0 ]; then STATUS="RED ($bad)"
		elif [ "$skip" != 0 ]; then STATUS="PARTIAL"
		else STATUS="GREEN"; fi
		printf 'T5 hook batteries  %3d batter%s  %-7s  (%d assertion(s)%s)\n' \
			"$n" "$([ "$n" = 1 ] && echo 'y  ' || echo 'ies')" \
			"$STATUS" "$asserts" \
			"$([ "$skip" = 0 ] && echo '' || echo ", $skip of $n did NOT run")"
		RED=$((RED+bad))
		# The tier counts as executed only if at least one battery actually ran.
		# Each battery that did not is already on the skip list via note_notrun,
		# so the verdict refuses the run either way - this only stops an
		# all-skipped tier from also claiming it checked something.
		tier_ran "$((n-skip))"
	fi
fi

hr
if [ -n "$SKIPPED" ]; then
	printf 'SKIPPED - these checks did NOT run, so this run is INCOMPLETE:\n%s' "$SKIPPED"
fi

# ⛔ THE VERDICT. Three gates, all three required for exit 0, in the order that
# tells the caller the most useful thing first: nothing ran, then something
# failed, then something was missed.
if [ "$EXECUTED" = "0" ]; then
	printf '⛔ NOTHING RAN - 0 tier(s) checked anything, %d skipped. This is not a\n' "$SKIPS"
	printf '        pass, it is a gate that verified nothing. Do not push.\n'
	exit 1
fi
if [ "$RED" != "0" ]; then
	printf '⛔ RED - %d check(s) failed. Do not push.\n' "$RED"
	exit 1
fi
if [ "$SKIPS" != "0" ]; then
	printf '⛔ INCOMPLETE - %d executed, 0 failed, %d did NOT run. Not a pass: a gate\n' "$EXECUTED" "$SKIPS"
	printf '        that exits 0 with a skip is a gate that can lie. Install what the\n'
	printf '        list above names, or run without --quick, then verify again.\n'
	exit 1
fi
printf 'GREEN - %d tier(s) executed, 0 failed, 0 skipped: syntax, config, and the\n' "$EXECUTED"
printf '        hook behaviour the batteries cover. This repo has no typecheck, no\n'
printf '        linter and no build; none of that was checked because none exists.\n'
printf '        .ps1 and .md are not checked at all.\n'
exit 0
