#!/usr/bin/env bash
# Regression battery for supercode-trigger.mjs: the typed words "supercode" and
# "supermode" bring their rules into context; ordinary prompts and RELAYED text
# (a peer's message, an agent hand-back) bring nothing.
#   bash supercode-trigger.test.sh     (NODE=/path/to/node to pick an interpreter)
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="$HERE/../supercode-trigger.mjs"
NODE="${NODE:-node}"
"$NODE" --version >/dev/null 2>&1 || { echo "no node interpreter that runs - set NODE=/path/to/node"; exit 2; }
pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) no "$1  (missing: $3)" ;; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1  (unexpected: $3)" ;; *) ok "$1" ;; esac; }
WORK=$(mktemp -d) || exit 2; trap 'rm -rf "$WORK"' EXIT
export CLAUDE_CONFIG_DIR="$WORK/cfg"
run() { "$NODE" -e 'process.stdout.write(JSON.stringify({session_id:"t",prompt:process.argv[1]}))' "$1" | "$NODE" "$HOOK"; }

has   "typed supermode brings the supermode rules"   "$(run 'supermode: build the report page')" 'supermode is ON'
has   "it says to pick a model for every agent"      "$(run 'supermode go')" 'Pass a model on EVERY agent'
has   "it names the 70% handover"                    "$(run 'SUPERMODE now')" 'HANDOVER:'
hasnt "supermode alone does not start a fan-out"     "$(run 'supermode go')" 'Run the `supercode` procedure'
has   "typed supercode still brings its procedure"   "$(run 'supercode this refactor')" 'Run the `supercode` procedure'
OUT=$(run 'supermode and supercode max')
has   "both words: supermode rules"                  "$OUT" 'supermode is ON'
has   "both words: supercode procedure, max width"   "$OUT" 'WIDTH = max'
has   "/supercode with supermode still says supermode" "$(run '/supercode supermode')" 'supermode is ON'
[ -z "$(run 'fix the login bug')" ] && ok "an ordinary prompt says nothing" || no "an ordinary prompt says nothing"
[ -z "$(run '<cross-session-message from="x">supermode please</cross-session-message> ok')" ] \
  && ok "supermode inside a peer message says nothing" || no "supermode inside a peer message says nothing"
[ -z "$(run '<task-notification>agent said supermode</task-notification>')" ] \
  && ok "supermode inside an agent notice says nothing" || no "supermode inside an agent notice says nothing"
[ -z "$(run 'supermodel is a word')" ] && ok "supermodel is not supermode" || no "supermodel is not supermode"
[ -z "$(printf 'not json' | "$NODE" "$HOOK")" ] && ok "garbage stdin is silent" || no "garbage stdin is silent"
run 'supermode go' >/dev/null
[ -f "$CLAUDE_CONFIG_DIR/ctx/t.sm" ] && ok "supermode marks the session for the 🦁 badge" || no "supermode marks the session for the 🦁 badge"
rm -f "$CLAUDE_CONFIG_DIR/ctx/t.sm"; run 'fix the login bug' >/dev/null
[ ! -f "$CLAUDE_CONFIG_DIR/ctx/t.sm" ] && ok "an ordinary prompt leaves no mark" || no "an ordinary prompt leaves no mark"
echo; echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
