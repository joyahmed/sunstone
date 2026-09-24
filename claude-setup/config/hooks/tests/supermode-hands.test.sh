#!/usr/bin/env bash
# Regression battery for supermode-hands.mjs.
#
# WHY THIS FILE EXISTS: the guard denies the ORCHESTRATOR's own shell commands,
# so a false deny costs the run - and the first version had one. It matched `>`
# and `tee` anywhere in the command TEXT, so `git commit -m "slice 2 -> gate
# passed"` was denied: a commit, which the contract promises stays the
# orchestrator's. It was found by someone reading the pushed file, not by its
# author, who had tested only synthetic cases with no prose in them.
#
# So the cases below are what an orchestrator actually types. Add to them before
# changing the scanner, never after.
#
#   bash supermode-hands.test.sh          (NODE=/path/to/node to pick an interpreter)
#
# ⚠️ `node` may not be on PATH in a non-interactive shell - under nvm it is a
# lazily-defined shell function and nvm's bin is never exported. That bit this
# very file: every case "passed" while node was missing, because a hook that
# cannot run prints nothing and printing nothing means allow.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="$HERE/../supermode-hands.mjs"
NODE="${NODE:-$(command -v node || true)}"
[ -x "$NODE" ] || { echo "no node interpreter - set NODE=/path/to/node"; exit 2; }
[ -f "$HOOK" ] || { echo "hook not found beside the test: $HOOK"; exit 2; }

SID=hookselftest
CTX="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ctx"
TRANSCRIPT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/-selftest/$SID.jsonl"
pass=0; fail=0

t() { # <allow|deny> <label> <command>
  # The guard is STATEFUL: it disengages after six denials. Reset per case, or
  # the seventh test silently "passes" as an allow.
  rm -f "$CTX/$SID.handsdeny" "$CTX/$SID.hands"
  local out got
  out=$("$NODE" -e '
    process.stdout.write(JSON.stringify({
      session_id: process.argv[3], transcript_path: process.argv[2],
      tool_name: "Bash", tool_input: { command: process.argv[1] } }));
  ' "$3" "$TRANSCRIPT" "$SID" | SUPERMODE=1 "$NODE" "$HOOK")
  got=$([ -z "$out" ] && echo allow || echo deny)
  if [ "$got" = "$1" ]; then pass=$((pass+1)); printf '  ok   %-5s %s\n' "$got" "$2"
  else fail=$((fail+1)); printf '  FAIL want=%s got=%s  %s\n' "$1" "$got" "$2"; fi
}

SCRATCH=/tmp/scratchpad
echo "the orchestrator's own work - every one of these must ALLOW:"
t allow "commit message containing an arrow"  'git commit -m "slice 2 -> gate passed"'
t allow "log format string with an arrow"     'git log --format="%h => %s"'
t allow "pipe into the scratchpad"            "pnpm build 2>&1 | tee $SCRATCH/build.log"
t allow "commit body through a heredoc"       'git commit -q -F - <<MSG
subject -> with arrows
MSG'
t allow "the gate"                            'pnpm --filter=api build && pnpm test'
t allow "stderr to /dev/null"                 'grep -r foo . 2>/dev/null | head'
t allow "append to the handoff note"          'echo done >> docs/ai-memory/session-2026-01-01.md'
t allow "edit the handoff note in place"      "sed -i 's/pending/done/' docs/ai-memory/session-2026-01-01.md"
t allow "push"                                'git push -q origin main'
t allow "read-only sed"                       "sed -n '1,5p' src/app.ts"
t allow "redirect into the scratchpad"        "awk '{print}' src/a.ts > $SCRATCH/o.txt"

echo "edits that belong to an agent - every one of these must DENY:"
t deny  "heredoc into a source file"          'cat > src/app.ts <<EOF
x
EOF'
t deny  "sed -i on a source file"             "sed -i 's/a/b/' src/app.ts"
t deny  "sed -i.bak on a source file"         "sed -i.bak 's/a/b/' src/app.ts"
t deny  "perl -pi on a source file"           "perl -pi -e 's/a/b/' src/app.ts"
t deny  "tee into a source file"              'pnpm build | tee src/out.txt'
t deny  "tee into a quoted source path"       'pnpm build | tee "src/out.txt"'
t deny  "append into a source file"           'echo x >> src/app.ts'
t deny  "redirect into a nested source file"  'echo x > src/deep/nested/file.ts'

echo "shapes a second reader threw at it - prose first, all must ALLOW:"
t allow "commit message about redirection"    'git commit -m "fix: rewrite > into >> in logger"'
t allow "grep for an arrow in source"         'grep -r "a -> b" src/'
t allow "heredoc body containing a redirect"  'git commit -F - <<MSG
echo hi > src/evil.ts
MSG'

echo "writes in odd shapes - must DENY:"
t deny  "command substitution hiding a write" 'echo $(echo hi > src/app.ts)'
t deny  "dd with the target on a flag"        'dd if=/dev/zero of=src/app.ts'

# ⛔ DOCUMENTED CEILING, not a gap anyone should "fix" by hardening the scanner.
# An interpreter can always write a file, and a redirect written INSIDE an awk
# or perl program lives in a quoted string - and stripping quoted strings is
# precisely what lets `git commit -m "a -> b"` through. Closing these means
# parsing every embedded language, for a guard that fails open on purpose. They
# are false ALLOWS: the mode leaks, nothing breaks. The expensive direction is a
# false DENY, which blocks real work and burns the breaker.
echo "the ceiling of a text scan - ALLOW is the accepted answer here:"
t allow "redirect inside an awk program"      'awk "{print > \"src/out.ts\"}" in.txt'
t allow "an interpreter writing a file"       'python3 -c "open(\"src/x.ts\",\"w\").write(1)"'

rm -f "$CTX/$SID.handsdeny" "$CTX/$SID.hands"
echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
