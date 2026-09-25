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
# .md. Said here rather than left to be discovered.
#
# Usage: sh claude-setup/scripts/verify.sh [--quick]
#   --quick skips tier 5 (the batteries spawn processes and are the slow tier).

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

RED=0
SKIPPED=""
note_skip() { SKIPPED="$SKIPPED  - $1 (tool missing: $2)
"; }
note_notrun() { SKIPPED="$SKIPPED  - $1 (did not run: $2)
"; }

hr() { printf '%s\n' "------------------------------------------------------------"; }

# --- tier 1: node --check ----------------------------------------------------
if command -v node >/dev/null 2>&1; then
	n=0; bad=0
	for f in $(git ls-files '*.mjs' '*.js' | grep -v node_modules); do
		n=$((n+1))
		node --check "$f" >/dev/null 2>&1 || { printf 'RED  node --check %s\n' "$f"; node --check "$f" 2>&1 | head -3; bad=$((bad+1)); }
	done
	printf 'T1 node --check    %3d file(s)  %s\n' "$n" "$([ "$bad" = 0 ] && echo GREEN || echo "RED ($bad)")"
	RED=$((RED+bad))
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
	printf 'T2 bash -n         %3d file(s)  %s\n' "$n" "$([ "$bad" = 0 ] && echo GREEN || echo "RED ($bad)")"
	RED=$((RED+bad))
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
	printf 'T3 python syntax   %3d file(s)  %s\n' "$n" "$([ "$bad" = 0 ] && echo GREEN || echo "RED ($bad)")"
	RED=$((RED+bad))
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
	printf 'T4 json.load       %3d file(s)  %s\n' "$n" "$([ "$bad" = 0 ] && echo GREEN || echo "RED ($bad)")"
	RED=$((RED+bad))
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
	fi
fi

hr
if [ -n "$SKIPPED" ]; then
	printf 'SKIPPED - these checks did NOT run, so this pass is narrower than it looks:\n%s' "$SKIPPED"
fi
if [ "$RED" = "0" ]; then
	printf 'GREEN - syntax, config, and the hook behaviour the batteries cover. This\n'
	printf '        repo has no typecheck, no linter and no build; none of that was\n'
	printf '        checked because none exists. .ps1 and .md are not checked at all.\n'
	exit 0
fi
printf '⛔ RED - %d check(s) failed. Do not push.\n' "$RED"
exit 1
