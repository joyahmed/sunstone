#!/usr/bin/env bash
# Regression battery for the context cap: context-guard.mjs (PostToolUse nudge,
# writes ctx/<sid>.tok) and context-cap.mjs (PreToolUse hard stop at the cap).
#
# WHY THIS FILE EXISTS. On 2026-09-29 sessions were measured running past 150k
# with only a nudge, which spent half a week's quota. The cap now applies to EVERY
# main session (it was supermode-only until supermode was retired that day), so a
# regression here either lets sessions run away again or blocks a session that
# should work. Inverse controls are half of the file: under the cap is silent, a
# subagent is silent, Bash and a "resume" Agent pass at the cap.
#
#   bash context-cap.test.sh          (NODE=/path/to/node to pick an interpreter)
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GUARD="$HERE/../context-guard.mjs"
CAP="$HERE/../context-cap.mjs"

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
# Windows / Git Bash: /tmp paths are not converted inside JSON on stdin, so use a native path.
command -v cygpath >/dev/null 2>&1 && WORK=$(cygpath -m "$WORK")
trap 'rm -rf "$WORK"' EXIT INT TERM
export CLAUDE_CONFIG_DIR="$WORK/cfg"
unset SUPERMODE CTX_CAP_TOKENS SUPERMODE_CTX_TOKENS CTX_CAP_PCT SUPERMODE_CTX_PCT
mkdir -p "$CLAUDE_CONFIG_DIR"

usage() { printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$1"; }
{ usage 60000; usage 100000; } > "$WORK/under.jsonl"   # 40k grown
{ usage 60000; usage 150000; } > "$WORK/over.jsonl"    # 90k grown

guard() { printf '{"session_id":"%s","transcript_path":"%s"%s}' "$1" "$2" "${3:-}" | "$NODE" "$GUARD"; }
cap()   { printf '{"session_id":"%s","tool_name":"%s","tool_input":{"prompt":"%s"}%s}' "$1" "$2" "${3:-}" "${4:-}" | "$NODE" "$CAP"; }

echo "under the cap (40k grown), ordinary session:"
eq  "the guard is silent"                 "" "$(guard s1 "$WORK/under.jsonl")"
eq  "the cap lets Read through"           "" "$(cap s1 Read)"

echo "over the cap (90k grown), ordinary session - no supermode anywhere:"
OUT=$(guard s2 "$WORK/over.jsonl")
has "the guard nudges"                    "$OUT" "90k grown since its 60k start"
has "the nudge says to start fresh"       "$OUT" "start a fresh session"
eq  "the guard records grown/total/start" "90000 150000 60000" "$(cat "$CLAUDE_CONFIG_DIR/ctx/s2.tok")"
OUT=$(cap s2 Read)
has "Read is denied"                      "$OUT" '"permissionDecision":"deny"'
has "in plain words"                      "$OUT" "This chat is full (90k grown since start, cap 80k)"
has "Grep is denied"                      "$(cap s2 Grep)" '"deny"'
has "a plain Agent is denied"             "$(cap s2 Agent "do the thing")" '"deny"'
has "a ctx_ tool is denied"               "$(cap s2 mcp__context-mode__ctx_search)" '"deny"'
eq  "Bash stays open"                     "" "$(cap s2 Bash)"
eq  "Edit stays open"                     "" "$(cap s2 Edit)"
eq  "an Agent that says resume is allowed" "" "$(cap s2 Agent "resume from the handoff")"

echo "inside a subagent (agent_id present):"
eq  "the guard is silent"                 "" "$(guard s3 "$WORK/over.jsonl" ',"agent_id":"a1"')"
eq  "the cap is silent"                   "" "$(cap s2 Read "" ',"agent_id":"a1"')"

echo "switches:"
eq  "CTX_CAP_TOKENS=0 turns the cap off"  "" "$(CTX_CAP_TOKENS=0 cap s2 Read)"
eq  "the old SUPERMODE_CTX_TOKENS still works" "" "$(SUPERMODE_CTX_TOKENS=0 cap s2 Read)"
has "a higher cap is honoured by name"    "$(CTX_CAP_TOKENS=50000 cap s2 Read)" "cap 50k"
eq  "garbage stdin fails open"            "" "$(printf 'not json' | "$NODE" "$CAP")"

echo "a subagent, measured from its OWN transcript (added 2026-10-02):"
mkdir -p "$WORK/proj/sx/subagents"
usage 150000 > "$WORK/proj/sx/subagents/agent-a1.jsonl"                      # 150k of a 200k window = 75%
usage 100000 > "$WORK/proj/sx/subagents/agent-a2.jsonl"                      # 50%
usage 144000 > "$WORK/proj/sx/subagents/agent-a4.jsonl"                      # 72%: past soft, under hard
{ printf '{"type":"attachment","attachment":{"type":"model","identity":{"modelId":"claude-opus-5-5[1m]"}}}\n'; usage 150000; } \
  > "$WORK/proj/sx/subagents/agent-a3.jsonl"                                  # 15% of a 1M window
sub() { printf '{"session_id":"sx","transcript_path":"%s","agent_id":"%s","tool_name":"%s","tool_input":{}}' \
  "$WORK/proj/sx.jsonl" "$1" "$2" | "$NODE" "$CAP"; }
OUT=$(sub a1 Read)
has "a subagent past 70% is refused a Read"     "$OUT" '"permissionDecision":"deny"'
has "and told to end with a HANDOVER"           "$OUT" 'start with \"HANDOVER:\"'
has "with its own figure"                       "$OUT" "150k of 200k (75%)"
has "it is refused Bash too (no reading via cat)" "$(sub a1 Bash)" '"permissionDecision":"deny"'
eq  "between 70% and 75% it may still Edit"     "" "$(sub a4 Edit)"
has "between 70% and 75% Read is refused"       "$(sub a4 Read)" '"permissionDecision":"deny"'
has "at 75% (the hard ceiling) Edit is refused" "$(sub a1 Edit)" '"permissionDecision":"deny"'
has "at 75% Write is refused"                   "$(sub a1 Write)" '"permissionDecision":"deny"'
has "the hard message says every tool"          "$(sub a1 Edit)" "Every tool is blocked"
eq  "SUBAGENT_CTX_HARD_PCT=90 reopens Edit at 75%" "" "$(SUBAGENT_CTX_HARD_PCT=90 sub a1 Edit)"
eq  "at 75% the HANDOVER report still goes out" "" "$(sub a1 SubagentHandback)"
eq  "at 75% a workflow agent may still return"  "" "$(sub a1 StructuredOutput)"
eq  "at 75% SendMessage stays open"             "" "$(sub a1 SendMessage)"
eq  "a subagent at 50% is silent"               "" "$(sub a2 Read)"
eq  "a subagent at 50% may run Bash"         "" "$(sub a2 Bash)"
eq  "a [1m] subagent at 15% is silent"          "" "$(sub a3 Read)"
eq  "SUBAGENT_CTX_PCT=0 turns it off"           "" "$(SUBAGENT_CTX_PCT=0 sub a1 Read)"
has "SUBAGENT_CTX_WINDOW is honoured"           "$(SUBAGENT_CTX_WINDOW=180000 SUBAGENT_CTX_PCT=80 sub a1 Read)" "150k of 180k"
eq  "an unknown agent id is silent"             "" "$(sub nope Read)"

echo "a Workflow-tool agent (subagents/workflows/<run>/, added 2026-10-05):"
mkdir -p "$WORK/proj/sx/subagents/workflows/wf_run1"
usage 150000 > "$WORK/proj/sx/subagents/workflows/wf_run1/agent-w1.jsonl"    # 75%
usage 100000 > "$WORK/proj/sx/subagents/workflows/wf_run1/agent-w2.jsonl"    # 50%
has "a workflow agent past 70% is refused a Read" "$(sub w1 Read)" '"permissionDecision":"deny"'
has "with its own figure"                       "$(sub w1 Read)" "150k of 200k (75%)"
eq  "a workflow agent at 50% is silent"         "" "$(sub w2 Read)"

echo "the main session's WINDOW - never a guessed 200k (added 2026-10-27, FAILURES 10-15/10-23/10-27):"
plain() { printf '{"type":"attachment","attachment":{"type":"model","identity":{"modelId":"claude-opus-5-5","marketingName":"Opus 5.5"}}}\n'; }
{ plain; usage 64000; usage 350000; } > "$WORK/plain350.jsonl"     # 35% of 1M, 175% of 200k
{ plain; usage 64000; usage 900000; } > "$WORK/plain900.jsonl"
eq  "plain claude-opus-5-5 at 350k, no window known: silent (was '175%')" "" "$(CTX_CAP_TOKENS=0 guard w1 "$WORK/plain350.jsonl")"
eq  "the fleet env (740k cap, 85%) at 350k total: silent" "" "$(CTX_CAP_TOKENS=740000 CTX_CAP_PCT=85 guard w2 "$WORK/plain350.jsonl")"
printf '1000000\n' > "$CLAUDE_CONFIG_DIR/ctx/w3.win"
eq  "status line says 1M (.win): 350k is silent"  "" "$(CTX_CAP_TOKENS=0 guard w3 "$WORK/plain350.jsonl")"
OUT=$(CTX_CAP_TOKENS=0 guard w3 "$WORK/plain900.jsonl")
has "status line says 1M: 900k nudges at 90%"     "$OUT" "90% of its context window"
has "and names the 1M window it measured against"  "$OUT" "1M-token window"
printf '200000\n' > "$CLAUDE_CONFIG_DIR/ctx/w4.win"
has "a real 200k window (.win) still nudges"      "$(CTX_CAP_TOKENS=0 guard w4 "$WORK/plain350.jsonl")" "175% of its context window"
has "CTX_CAP_WINDOW overrides everything"         "$(CTX_CAP_WINDOW=400000 CTX_CAP_TOKENS=0 guard w7 "$WORK/plain350.jsonl")" "88% of its context window"
{ printf '{"type":"attachment","attachment":{"type":"model","identity":{"modelId":"claude-opus-5-5[1m]"}}}\n'; usage 64000; usage 350000; } > "$WORK/m1.jsonl"
eq  "a [1m] marker still counts as 1M"            "" "$(CTX_CAP_TOKENS=0 guard w5 "$WORK/m1.jsonl")"
printf '70\n' > "$CLAUDE_CONFIG_DIR/ctx/w6.pct"
has "a fresh status-line .pct still wins"         "$(CTX_CAP_TOKENS=0 guard w6 "$WORK/plain350.jsonl")" "70% of its context window"

echo "the main session, when an agent hands over:"
ag() { printf '{"session_id":"m1","tool_name":"Agent","tool_input":{},"tool_response":{"content":[{"type":"text","text":"%s"}]}}' "$1" | "$NODE" "$GUARD"; }
has "a HANDOVER result says start a fresh agent" "$(ag 'HANDOVER: done A, left B')" "Start a FRESH agent"
eq  "an ordinary agent result says nothing"      "" "$(ag 'all done, 3 files changed')"
eq  "HANDOVER mentioned mid-answer says nothing"  "" "$(ag 'done. If you run low, end with HANDOVER: notes')"
asy() { printf '{"session_id":"m1","tool_name":"Agent","tool_input":{},"tool_response":{"isAsync":true,"status":"async_launched","prompt":"end with a final answer starting HANDOVER: when low"}}' | "$NODE" "$GUARD"; }
eq  "an async launch echoing HANDOVER says nothing" "" "$(asy)"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
