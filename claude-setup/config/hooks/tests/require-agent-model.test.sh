#!/usr/bin/env bash
# Regression battery for require-agent-model.mjs.
#
#   bash require-agent-model.test.sh          (NODE=/path/to/node to pick an interpreter)
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="${HOOK:-$HERE/../require-agent-model.mjs}"

NODE="${NODE:-node}"
if ! "$NODE" --version >/dev/null 2>&1; then
	for cand in "${NVM_BIN:-}/node" /usr/local/bin/node /usr/bin/node /opt/homebrew/bin/node \
	            "${NVM_DIR:-${HOME:-}/.nvm}"/versions/node/*/bin/node; do
		[ -x "$cand" ] && { NODE="$cand"; break; }
	done
fi
"$NODE" --version >/dev/null 2>&1 || { echo "no node interpreter that runs - set NODE=/path/to/node"; exit 2; }
[ -f "$HOOK" ] || { echo "hook not found beside the test: $HOOK"; exit 2; }

_tmp="${TMPDIR:-/tmp}"; _tmp="${_tmp%/}"; [ -n "$_tmp" ] || _tmp=/tmp
TMPROOT=$(mktemp -d "$_tmp/require-agent-model-test.XXXXXX") || { echo "could not create a temp dir"; exit 2; }
cleanup() { [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT INT TERM HUP
mkdir -p "$TMPROOT/home/.claude"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n         want: %s\n         got:  %s\n' "$1" "$2" "$3"; }

# payload <toolInputJSON> -> classification of the hook's stdout
run() {
  out=$(printf '{"tool_name":"Agent","tool_input":%s}' "$1" \
    | env -i HOME="$TMPROOT/home" CLAUDE_CONFIG_DIR="$TMPROOT/home/.claude" REQUIRE_AGENT_MODEL="${REQUIRE_AGENT_MODEL:-}" PATH="$PATH" "$NODE" "$HOOK" 2>&1)
  case "$out" in
    "")                             echo allow ;;
    *'"permissionDecision":"deny"'*) echo deny ;;
    *systemMessage*)               echo warn ;;
    *)                              echo other ;;
  esac
}

t() { # <want> <label> <tool_input-json>
  got=$(run "$3")
  if [ "$got" = "$1" ]; then ok "$2 ($got)"
  else bad "$2" "$1" "$got"; fi
}

echo "no model, no conf, no env - default warn:"
REQUIRE_AGENT_MODEL= t warn "Agent call with no model param" '{"description":"scout"}'

echo "model given - silent whatever the mode:"
REQUIRE_AGENT_MODEL=block t allow "model present" '{"model":"sonnet","description":"scout"}'

echo "fork ignores model override - never nagged even with none given:"
REQUIRE_AGENT_MODEL=block t allow "subagent_type fork, no model" '{"subagent_type":"fork","description":"scout"}'

echo "REQUIRE_AGENT_MODEL=off - silent:"
REQUIRE_AGENT_MODEL=off t allow "env off" '{"description":"scout"}'

echo "REQUIRE_AGENT_MODEL=block - denies:"
REQUIRE_AGENT_MODEL=block t deny "env block" '{"description":"scout"}'

echo "haiku tier - scout not on haiku warns, never blocks:"
REQUIRE_AGENT_MODEL= t warn "scout on sonnet" '{"subagent_type":"scout","model":"sonnet","description":"count routes","prompt":"Count the routes."}'
REQUIRE_AGENT_MODEL=block t warn "scout on opus, block mode still only warns" '{"subagent_type":"scout","model":"opus","prompt":"List files."}'
REQUIRE_AGENT_MODEL= t allow "scout on haiku" '{"subagent_type":"scout","model":"haiku","prompt":"List files."}'
REQUIRE_AGENT_MODEL=off t allow "scout on sonnet, mode off" '{"subagent_type":"scout","model":"sonnet","prompt":"List files."}'

echo "haiku tier - lookup-shaped brief on a top model warns:"
REQUIRE_AGENT_MODEL= t warn "find on sonnet" '{"model":"sonnet","description":"find native selects","prompt":"Find every <select> in apps/web. Return file:line."}'
REQUIRE_AGENT_MODEL= t warn "count on opus" '{"model":"opus","prompt":"Count how many controllers use @Roles. Return the number."}'
REQUIRE_AGENT_MODEL= t warn "where-is on fable" '{"model":"fable","prompt":"Where is the payroll guard defined?"}'
REQUIRE_AGENT_MODEL= t warn "inventory on general-purpose sonnet" '{"subagent_type":"general-purpose","model":"sonnet","prompt":"Inventory the hooks in ~/.claude/hooks."}'
REQUIRE_AGENT_MODEL=block t warn "lookup on sonnet, block mode still only warns" '{"model":"sonnet","prompt":"List the migrations."}'

echo "haiku tier - mixed or non-lookup briefs stay silent:"
REQUIRE_AGENT_MODEL= t allow "find + fix on sonnet" '{"model":"sonnet","prompt":"Find every <select> and fix it to use AppSelect."}'
REQUIRE_AGENT_MODEL= t allow "list + review on opus" '{"model":"opus","prompt":"List the risky changes and review each one."}'
REQUIRE_AGENT_MODEL= t allow "find + commit on sonnet" '{"model":"sonnet","prompt":"Find the stale doc, then commit the removal."}'
REQUIRE_AGENT_MODEL= t warn "scout-style which-routes-have-no-test on sonnet" '{"model":"sonnet","prompt":"List which routes have no test."}'
REQUIRE_AGENT_MODEL= t allow "list + run the tests on sonnet" '{"model":"sonnet","prompt":"List the specs, then run the tests."}'
REQUIRE_AGENT_MODEL= t allow "plan on opus, no lookup verb" '{"model":"opus","prompt":"Draw up the payroll phase plan."}'
REQUIRE_AGENT_MODEL= t allow "lookup on haiku" '{"model":"haiku","prompt":"Count the files."}'
REQUIRE_AGENT_MODEL= t allow "lookup on a full haiku id" '{"model":"claude-haiku-4-5","prompt":"Count the files."}'
REQUIRE_AGENT_MODEL= t allow "word inside another word (listener, founder)" '{"model":"sonnet","prompt":"The listener and the founder talk."}'

echo "scout with no model - missing-model warning names haiku:"
out=$(printf '{"tool_name":"Agent","tool_input":{"subagent_type":"scout","prompt":"List files."}}' \
  | env -i HOME="$TMPROOT/home" CLAUDE_CONFIG_DIR="$TMPROOT/home/.claude" PATH="$PATH" "$NODE" "$HOOK" 2>&1)
case "$out" in *'no model parameter'*'model \"haiku\"'*) ok "scout hint appended" ;; *) bad "scout hint appended" 'no model parameter ... model "haiku"' "$out" ;; esac

echo "tier warning text names scout + haiku:"
out=$(printf '{"tool_name":"Agent","tool_input":{"model":"opus","description":"count","prompt":"Count the tests."}}' \
  | env -i HOME="$TMPROOT/home" CLAUDE_CONFIG_DIR="$TMPROOT/home/.claude" PATH="$PATH" "$NODE" "$HOOK" 2>&1)
case "$out" in *'scout'*'haiku'*'additionalContext'*) ok "warning names scout + haiku, as additionalContext" ;; *) bad "warning text" "scout ... haiku ... additionalContext" "$out" ;; esac

echo "not an Agent call - silent:"
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | env -i HOME="$TMPROOT/home" CLAUDE_CONFIG_DIR="$TMPROOT/home/.claude" PATH="$PATH" "$NODE" "$HOOK" 2>&1)
[ -z "$out" ] && ok "non-Agent tool ignored" || bad "non-Agent tool ignored" "" "$out"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
