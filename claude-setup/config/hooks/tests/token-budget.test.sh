#!/usr/bin/env bash
# Regression battery for token-budget.mjs (PreToolUse): the per-session spend
# ceiling, main session + all its agents, decided on 2026-10-06.
#
# WHY THIS FILE EXISTS. A delegating session spends mostly through its agents, which
# context-cap.mjs does not see as spend. This hook warns once at 2M and blocks NEW
# Agent/Workflow calls at 3M. A regression either lets a fan-out run away again or
# blocks work it should not: so the inverse controls (Edit/Bash untouched, a subagent
# untouched, cache reads not counted, duplicate ids counted once, 0 = off, garbage
# stdin fails open) are half of the file.
#
#   bash token-budget.test.sh          (NODE=/path/to/node to pick an interpreter)
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="$HERE/../token-budget.mjs"
[ -f "$HOOK" ] || { echo "missing $HOOK"; exit 2; }

NODE="${NODE:-node}"
if ! "$NODE" --version >/dev/null 2>&1; then
	for cand in "${NVM_BIN:-}/node" /usr/local/bin/node /usr/bin/node /opt/homebrew/bin/node \
	            "${NVM_DIR:-${HOME:-}/.nvm}"/versions/node/*/bin/node; do
		[ -x "$cand" ] && { NODE="$cand"; break; }
	done
fi
"$NODE" --version >/dev/null 2>&1 || { echo "no node interpreter that runs - set NODE=/path/to/node"; exit 2; }

pass=0; fail=0
ok()    { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no()    { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else no "$1  want=[$2] got=[$3]"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) no "$1  (missing: $3)" ;; esac; }

WORK=$(mktemp -d 2>/dev/null) || { echo "cannot make a temp directory"; exit 2; }
command -v cygpath >/dev/null 2>&1 && WORK=$(cygpath -m "$WORK")
trap 'rm -rf "$WORK"' EXIT INT TERM
export CLAUDE_CONFIG_DIR="$WORK/cfg"
unset TOKEN_BUDGET_TOKENS TOKEN_BUDGET_WARN_PCT
export TOKEN_BUDGET_TOKENS=3000000   # the cases below test the cap itself; the DEFAULT (off) is tested at the end
mkdir -p "$CLAUDE_CONFIG_DIR" "$WORK/proj"

# msg <id> <input> <cache_creation> <output> [cache_read]
msg() { printf '{"type":"assistant","message":{"id":"%s","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s}}}\n' "$1" "$2" "$3" "$4" "${5:-0}"; }
# run <sid> <tool> [extra json]
run() { printf '{"session_id":"%s","transcript_path":"%s","tool_name":"%s","tool_input":{}%s}' \
  "$1" "$WORK/proj/$1.jsonl" "$2" "${3:-}" | "$NODE" "$HOOK"; }

echo "under budget (1.5M across main + an agent):"
msg m1 500000 0 0 > "$WORK/proj/s1.jsonl"
mkdir -p "$WORK/proj/s1/subagents"; msg a1 1000000 0 0 > "$WORK/proj/s1/subagents/agent-x1.jsonl"
eq  "Agent is silent"                      "" "$(run s1 Agent)"
eq  "Workflow is silent"                   "" "$(run s1 Workflow)"

echo "2.1M (main 0.6M + agent 0.9M + workflow agent 0.6M) warns once:"
msg m1 300000 200000 100000 > "$WORK/proj/s2.jsonl"
mkdir -p "$WORK/proj/s2/subagents/workflows/wf_r1"
msg a1 900000 0 0 > "$WORK/proj/s2/subagents/agent-y1.jsonl"
msg w1 600000 0 0 > "$WORK/proj/s2/subagents/workflows/wf_r1/agent-w1.jsonl"
OUT=$(run s2 Agent)
has "it warns"                             "$OUT" "have used 2.10M of the 3.00M budget"
has "as a systemMessage"                   "$OUT" '"systemMessage"'
has "and as additionalContext"             "$OUT" '"additionalContext"'
case "$OUT" in *deny*) no "the warning does not deny";; *) ok "the warning does not deny";; esac
eq  "the second Agent call is silent"      "" "$(run s2 Agent)"
eq  "a Workflow call after it is silent"   "" "$(run s2 Workflow)"

echo "3M reached (main 3M):"
msg m1 1000000 1000000 1000000 > "$WORK/proj/s3.jsonl"
OUT=$(run s3 Agent)
has "Agent is denied"                      "$OUT" '"permissionDecision":"deny"'
has "with the figure"                      "$OUT" "used 3.00M tokens, budget 3.00M"
has "says the main session keeps working"  "$OUT" "main session can keep working"
has "names the switch"                     "$OUT" "TOKEN_BUDGET_TOKENS (0 turns it off)"
has "Workflow is denied"                   "$(run s3 Workflow)" '"permissionDecision":"deny"'
eq  "Edit is never touched"                "" "$(run s3 Edit)"
eq  "Bash is never touched"                "" "$(run s3 Bash)"
eq  "Read is never touched"                "" "$(run s3 Read)"
eq  "a subagent (agent_id) is never touched" "" "$(run s3 Agent ',"agent_id":"a9"')"

echo "what counts:"
msg m1 100000 0 0 5000000 > "$WORK/proj/s4.jsonl"                                   # 5M of cache reads
eq  "cache_read is not counted (5M of reads, 0.1M spent: silent)" "" "$(run s4 Agent)"
{ msg dup 1000000 0 0; msg dup 1000000 0 0; msg dup 1000000 0 0; } > "$WORK/proj/s5.jsonl"   # 3 lines, one message
eq  "a message id written 3 times counts once (1M: silent)" "" "$(run s5 Agent)"
{ msg d1 1000000 0 0; msg d2 1000000 0 0; msg d3 1000000 0 0; } > "$WORK/proj/s6.jsonl"
has "three distinct ids do add up (3M: denied)" "$(run s6 Agent)" '"deny"'

echo "switches:"
eq  "TOKEN_BUDGET_TOKENS=0 turns it off"   "" "$(TOKEN_BUDGET_TOKENS=0 run s3 Agent)"
has "control: s3 at 3M is denied"         "$(run s3 Agent)" '"permissionDecision":"deny"'
eq  "not set, the budget is OFF (default)" "" "$(TOKEN_BUDGET_TOKENS= run s3 Agent)"
eq  "a higher budget lets 3M through"      "" "$(TOKEN_BUDGET_TOKENS=10000000 run s3 Agent)"
has "TOKEN_BUDGET_WARN_PCT is honoured"    "$(TOKEN_BUDGET_WARN_PCT=10 run s1 Agent)" "have used 1.50M of the 3.00M budget"
eq  "garbage stdin fails open"             "" "$(printf 'not json' | "$NODE" "$HOOK")"
eq  "a missing transcript fails open"      "" "$(printf '{"session_id":"zz","transcript_path":"/nope/zz.jsonl","tool_name":"Agent"}' | "$NODE" "$HOOK")"

echo "cache:"
msg m2 2500000 0 0 >> "$WORK/proj/s1.jsonl"                                          # s1 grows to 4M
has "a grown transcript is re-read (cache keyed on size/mtime)" "$(run s1 Agent)" '"deny"'

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
