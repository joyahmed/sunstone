#!/usr/bin/env bash
# Regression battery for agent-watch.mjs --report.
#
# WHY THIS FILE EXISTS: supermode is orchestration - the session delegates and the
# AGENTS spend the context - and this CLI is the only thing that tells the
# orchestrator how full each agent's window is. A report that is merely WRONG here
# is worse than no report, because it is believable: the reader gets a tidy list of
# agents and percentages and has no way to tell it belongs to a different session
# than the one on their screen. That is the specific defect these three cases pin.
#
#   bash agent-watch.test.sh          (NODE=/path/to/node to pick an interpreter,
#                                      HOOK=/path/to/hook to point it elsewhere)
#
# ⛔ EVERY CASE RUNS UNDER A FAKE $HOME, BY CONSTRUCTION. The hook discovers
# sessions by walking ~/.claude/projects, so run it with a real HOME and it reports
# the machine's real sessions - which would make case 1 (two candidates) and case 2
# (exactly one) depend on how many sessions the person running the battery happens
# to have open. Not merely leaky: non-deterministic, and green or red for reasons
# that have nothing to do with the code. HOME and CLAUDE_CONFIG_DIR are both set to
# a mktemp directory removed on exit, on success, failure and interrupt alike; one
# assertion below checks the reported directory really is under it.
#
# ⚠️ A PREREQUISITE THAT IS MISSING EXITS 2, NOT 0 - "could not run the hook" must
# never be reported as "the hook is fine". 0 = green, 1 = a real failure, 2 = did
# not run.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="${HOOK:-$HERE/../agent-watch.mjs}"

# ⛔ `[ -x "$(command -v node)" ]` IS THE WRONG TEST, and it fails on a machine
# where node is perfectly available. Under a lazy version manager `node` is a shell
# FUNCTION, so `command -v` prints the bare word `node` rather than a path and the
# -x test on it is false - this battery would refuse to run somewhere it works
# fine. Ask whether the interpreter RUNS, which is the only thing that matters.
# (run-node.sh exists for exactly this, and has its own battery beside this one.)
NODE="${NODE:-node}"
if ! "$NODE" --version >/dev/null 2>&1; then
	for cand in "${NVM_BIN:-}/node" /usr/local/bin/node /usr/bin/node /opt/homebrew/bin/node \
	            "${NVM_DIR:-$HOME/.nvm}"/versions/node/*/bin/node; do
		[ -x "$cand" ] && { NODE="$cand"; break; }
	done
fi
"$NODE" --version >/dev/null 2>&1 || { echo "no node interpreter that runs - set NODE=/path/to/node"; exit 2; }
[ -f "$HOOK" ] || { echo "hook not found beside the test: $HOOK"; exit 2; }

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-watch-test.XXXXXX") || {
	echo "could not create a temp dir - refusing to run against the real ~/.claude"; exit 2; }
cleanup() { [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT INT TERM HUP

pass=0; fail=0
ok()    { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()   { fail=$((fail+1)); printf '  FAIL %s\n         want: %s\n         got:  %s\n' "$1" "$2" "$3"; }
clip()  { printf '%s' "$1" | tr '\n' '|' | cut -c1-240; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "output contains '$2'" "$(clip "$3")" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1" "output does NOT contain '$2'" "$(clip "$3")" ;; *) ok "$1" ;; esac; }

# ⚠️ mktemp, not a counter: this is called as `h=$(new_home)` and a command
# substitution is a subshell, so a counter incremented inside it is discarded and
# every case would share one directory - which for THIS battery means case 2's
# "exactly one candidate" quietly inherits case 1's two sessions and can never pass.
new_home() {
	_h=$(mktemp -d "$TMPROOT/home.XXXXXX") || return 1
	mkdir -p "$_h/.claude"
	printf '%s' "$_h"
}

# One agent transcript in the shape agent-watch actually reads: a .meta.json with
# the agentType and the one-line description the orchestrator gave it, and a .jsonl
# whose last assistant turn carries `usage`. The model id keeps its [Nm] suffix on
# purpose - that suffix is the only honest source of the window size, so it is what
# turns the token counts into the percentage the orchestrator steers by. 200k of a
# 1M window is 20%, and a case below asserts exactly that, because a gauge that
# prints a number it computed wrongly is the failure mode with no symptom.
mk_session() { # <fake home> <project slug> <session id> <agent description>
	_d="$1/.claude/projects/$2/$3/subagents"
	mkdir -p "$_d"
	printf '{"agentType":"general-purpose","description":"%s"}\n' "$4" > "$_d/agent-$3a.meta.json"
	printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5[1m]","usage":{"input_tokens":120000,"cache_read_input_tokens":80000,"cache_creation_input_tokens":0}}}' \
		> "$_d/agent-$3a.jsonl"
}

report() { # <fake home> [session id] -> the CLI's output, stderr folded in
	_h="$1"; shift
	HOME="$_h" CLAUDE_CONFIG_DIR="$_h/.claude" "$NODE" "$HOOK" --report "$@" 2>&1
}

# ⛔ THE DEFECT THIS CASE PINS. With no session id the hook used to pick the most
# recently WRITTEN subagents dir by mtime. On a box running several sessions at
# once - which is the normal state of the machines this framework runs on, and the
# only state in which the report matters - that silently prints session A's agents
# to session B's orchestrator. Refusing is the fix, so what is asserted is not only
# the message but the SILENCE: neither session's agents may appear anywhere in it.
echo "no session id, more than one candidate - it must refuse rather than guess:"
h=$(new_home)
mk_session "$h" "-scratch-alpha" "sidalpha" "alpha-slice-one"
mk_session "$h" "-scratch-beta"  "sidbeta"  "beta-slice-two"
out=$(report "$h")
has   "it says it is refusing to guess"           "refusing to guess" "$out"
hasnt "no agent from the alpha session is printed" "alpha-slice-one"  "$out"
hasnt "no agent from the beta session is printed"  "beta-slice-two"   "$out"
has   "it names the candidates to choose between"  "sidalpha"         "$out"
has   "it names the other candidate too"           "sidbeta"          "$out"

# One candidate is not a guess, so it proceeds - and SAYS the subject was inferred,
# because a report whose subject is implicit is a report that gets misattributed.
echo "no session id, exactly one candidate - proceed, and say whose agents these are:"
h=$(new_home)
mk_session "$h" "-scratch-solo" "sidsolo" "solo-slice"
out=$(report "$h")
has "it reports the one session's agent"       "solo-slice" "$out"
has "it states the session was inferred"       "inferred"   "$out"
has "it names the session it inferred"         "sidsolo"    "$out"
has "it reads the window as a percentage"      "20%"        "$out"
has "⛔ the dir it read is under the fake HOME, never the real one" "$TMPROOT" "$out"

# An explicit id is an answer, not a hint: how many other sessions exist on the box
# must not change what is reported, and must not make it hedge.
echo "an explicit --report <id>, with other sessions present:"
h=$(new_home)
mk_session "$h" "-scratch-alpha" "sidalpha" "alpha-slice-one"
mk_session "$h" "-scratch-beta"  "sidbeta"  "beta-slice-two"
out=$(report "$h" sidalpha)
has   "it reports the session that was named"      "alpha-slice-one"   "$out"
hasnt "nothing from the other session leaks in"    "beta-slice-two"    "$out"
hasnt "it does not refuse, however many exist"     "refusing to guess" "$out"
hasnt "it does not claim to have inferred anything" "inferred"         "$out"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
