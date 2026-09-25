#!/usr/bin/env bash
# Regression battery for supermode-hands.mjs.
#
# WHY THIS FILE EXISTS: the guard inspects the ORCHESTRATOR's own shell commands,
# so a false positive used to cost the run - and the first version had one. It
# matched `>` and `tee` anywhere in the command TEXT, so `git commit -m "slice 2 ->
# gate passed"` was denied: a commit, which the contract promises stays the
# orchestrator's. It was found by someone reading the pushed file, not by its
# author, who had tested only synthetic cases with no prose in them.
#
# ⚠️ AND WHY ITS FIRST 26 CASES WERE NOT ENOUGH. Every one of them hunted a false
# ALLOW - a write the guard should have caught and did not. Nobody tested the guard
# being too STRICT, so it shipped 26/26 green with two defects that only a
# too-strict test could see: a subagent's call classified as the orchestrator's, and
# a write target containing a shell variable. Both are false positives, which is the
# expensive direction. The rule now: every new scanner behaviour gets a case on BOTH
# sides, and the "must stay silent" section below is as load-bearing as the other.
#
# ⚠️ THE GUARD WARNS, IT DOES NOT DENY - a deny can never be complete (any
# interpreter can write a file), and a false positive can disable the mode
# silently in the middle of an unattended run. The three outcomes this battery
# distinguishes are therefore:
#   allow - the hook printed nothing at all
#   warn  - the hook printed additionalContext and the tool call still proceeds
#   deny  - the hook printed permissionDecision:deny  (nothing should do this now;
#           it is kept as a distinct verdict so a regression back to denying shows
#           up as a FAIL rather than passing as a warning)
#
#   bash supermode-hands.test.sh          (NODE=/path/to/node to pick an interpreter)
#
# ⚠️ `node` may not be on PATH in a non-interactive shell - under nvm it is a
# lazily-defined shell function and nvm's bin is never exported. That bit this very
# file: every case "passed" while node was missing, because a hook that cannot run
# prints nothing and printing nothing means allow.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="${HOOK:-$HERE/../supermode-hands.mjs}"
# ⛔ `[ -x "$(command -v node)" ]` IS THE WRONG TEST, and it fails on a machine
# where node is perfectly available. When node is a shell FUNCTION - nvm's lazy
# stub, or the agent shell's own snapshot - `command -v` prints the bare word
# `node`, not a path, so the -x test on it is false and this battery would refuse to
# run somewhere it works fine. Reported from a machine that hit it. Ask whether the
# interpreter RUNS, which is the only thing that matters here.
NODE="${NODE:-node}"
if ! "$NODE" --version >/dev/null 2>&1; then
	# Not on PATH and not a function here: look where node actually installs.
	for cand in "${NVM_BIN:-}/node" /usr/local/bin/node /usr/bin/node /opt/homebrew/bin/node \
	            "${NVM_DIR:-$HOME/.nvm}"/versions/node/*/bin/node; do
		[ -x "$cand" ] && { NODE="$cand"; break; }
	done
fi
"$NODE" --version >/dev/null 2>&1 || { echo "no node interpreter that runs - set NODE=/path/to/node"; exit 2; }
[ -f "$HOOK" ] || { echo "hook not found beside the test: $HOOK"; exit 2; }

SID=hookselftest
CTX="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ctx"
TRANSCRIPT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/-selftest/$SID.jsonl"
pass=0; fail=0

run() { # <command> [agent_id] -> prints allow|warn|deny|other
  rm -f "$CTX/$SID.hands"
  local out
  out=$("$NODE" -e '
    const p = { session_id: process.argv[3], transcript_path: process.argv[2],
      tool_name: "Bash", tool_input: { command: process.argv[1] } };
    if (process.argv[4]) p.agent_id = process.argv[4];
    process.stdout.write(JSON.stringify(p));
  ' "$1" "$TRANSCRIPT" "$SID" "${2:-}" | SUPERMODE=1 "$NODE" "$HOOK")
  case "$out" in
    "")                                 echo allow ;;
    *'"permissionDecision":"deny"'*)    echo deny ;;
    *additionalContext*)                echo warn ;;
    *)                                  echo other ;;
  esac
}

t() { # <allow|warn> <label> <command>
  local got; got=$(run "$3")
  if [ "$got" = "$1" ]; then pass=$((pass+1)); printf '  ok   %-5s %s\n' "$got" "$2"
  else fail=$((fail+1)); printf '  FAIL want=%s got=%s  %s\n' "$1" "$got" "$2"; fi
}

# ⛔ THE MISSING CASE CLASS #1, added 2026-09-25. Agents inherit these hooks, and a
# subagent's tool call arrives carrying the PARENT session's session_id AND the
# PARENT session's transcript_path - so the "is this the parent's transcript?" test
# was true for every subagent and the guard flagged the exact actor it exists to
# produce. Verified live: a subagent was told "you are the orchestrator, so this
# edit is not yours to make - delegate". It WAS the delegate. The harness ships
# `agent_id` for precisely this and documents it as the field to use.
sub() { # <allow|warn> <label> <command>   - the same call, made by a SUBAGENT
  local got; got=$(run "$3" "agent-selftest0001")
  if [ "$got" = "$1" ]; then pass=$((pass+1)); printf '  ok   %-5s %s\n' "$got" "$2"
  else fail=$((fail+1)); printf '  FAIL want=%s got=%s  %s\n' "$1" "$got" "$2"; fi
}

SCRATCH=/tmp/scratchpad
echo "the orchestrator's own work - every one of these must stay SILENT:"
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

echo "edits that belong to an agent - every one of these must WARN:"
t warn  "heredoc into a source file"          'cat > src/app.ts <<EOF
x
EOF'
t warn  "sed -i on a source file"             "sed -i 's/a/b/' src/app.ts"
t warn  "sed -i.bak on a source file"         "sed -i.bak 's/a/b/' src/app.ts"
t warn  "perl -pi on a source file"           "perl -pi -e 's/a/b/' src/app.ts"
t warn  "tee into a source file"              'pnpm build | tee src/out.txt'
t warn  "tee into a quoted source path"       'pnpm build | tee "src/out.txt"'
t warn  "append into a source file"           'echo x >> src/app.ts'
t warn  "redirect into a nested source file"  'echo x > src/deep/nested/file.ts'

echo "shapes a second reader threw at it - prose first, all must stay SILENT:"
t allow "commit message about redirection"    'git commit -m "fix: rewrite > into >> in logger"'
t allow "grep for an arrow in source"         'grep -r "a -> b" src/'
t allow "heredoc body containing a redirect"  'git commit -F - <<MSG
echo hi > src/evil.ts
MSG'

# ⛔ THE FALSE POSITIVE THAT COST A RUN, 2026-09-25. `writerTargets` read its
# arguments off a QUOTE-STRIPPED copy of the command, then split on whitespace - so
# a sed script containing spaces became a dozen words and the SECOND word, `GATE:`,
# was reported as the file being written. The real target was a note under
# claude-setup/memory/, squarely allowlisted. Reported live from another machine.
# The pair below is the whole point: the script must never become a target, and the
# real file must still be checked.
SEDX='s/^- GATE: `bash -n` OK\./- CONFIRMED BY EAR: yes\n- GATE: `bash -n` OK./'
echo "a writer script with spaces in it - the script is not a target:"
t allow "sed -i, spacey script, memory note"  "sed -i '$SEDX' claude-setup/memory/sunstone/session-2026-09-25.md"
t warn  "sed -i, spacey script, source file"  "sed -i '$SEDX' src/app.ts"
t allow "sed -i onto a quoted allowed path"   "sed -i 's/a/b/' \"docs/ai-memory/note.md\""
t allow "perl -e expression with a colon"     "perl -pi -e 's/x: y/z/' docs/ai-memory/note.md"

echo "writes in odd shapes - must WARN:"
t warn  "command substitution hiding a write" 'echo $(echo hi > src/app.ts)'
t warn  "dd with the target on a flag"        'dd if=/dev/zero of=src/app.ts'

# ⛔ DOCUMENTED CEILING, not a gap anyone should "fix" by hardening the scanner. An
# interpreter can always write a file, and a redirect written INSIDE an awk or perl
# program lives in a quoted string - and treating a quoted string as data is
# precisely what lets `git commit -m "a -> b"` through. Closing these means parsing
# every embedded language, for a guard that only warns. They are misses: the warning
# nobody got, on a mode that is nudged from three other directions.
echo "the ceiling of a text scan - SILENT is the accepted answer here:"
t allow "redirect inside an awk program"      'awk "{print > \"src/out.ts\"}" in.txt'
t allow "an interpreter writing a file"       'python3 -c "open(\"src/x.ts\",\"w\").write(1)"'
# A `#` that starts a word starts a comment, and a comment is prose. Found by a
# probe script whose own comment line, `# <hook> <cmd> <agent_id>`, was read as a
# redirect into a file called `<cmd>` - and refused, by the live guard, while that
# very defect was being fixed.
t allow "an arrow inside a shell comment"     'ls   # a <b> c <cmd> d'
t allow "a redirect inside a shell comment"   'pnpm test   # writes > src/out.ts one day'
t warn  "a real write after a comment line"   'ls   # nothing here
echo x > src/app.ts'

# ⛔ MISSING CASE CLASS #1 - the subagent. Under the old DENY these were refusals
# handed to the delegate; under a warning they would be the mode nagging the exact
# behaviour it exists to produce, quietly, in a log nobody reads. Both must be
# silent: a subagent editing source is the mode WORKING.
echo "a subagent's call is never the orchestrator's - must stay SILENT:"
sub allow "subagent sed -i on a source file"  "sed -i 's/a/b/' src/app.ts"
sub allow "subagent heredoc into source"      'cat > src/app.ts <<EOF
x
EOF'
sub allow "subagent tee into a source file"   'pnpm build | tee src/out.txt'

# ⛔ MISSING CASE CLASS #2 - a variable in the write path. Two live failures:
#   `echo x > $D/out.sh`   was reported against the literal string `$D/out.sh`
#   `sed ... > "$D/f.sh"`  was reported against the EMPTY STRING, because the
#                          redirect was scanned on a quote-stripped copy of the line
# The rule: resolve what can honestly be resolved (this process's environment, and
# assignments on the same command line) and judge the result; what cannot be
# resolved is not guessed at - silence, and a reason token in the log. Command
# substitution is never resolved, because resolving it means running it.
echo "variables in a write target - resolvable is judged, unresolvable is SILENT:"
t warn  "same-line assignment onto source"    'D=src; echo x > $D/app.ts'
t warn  "same-line assignment, quoted target" 'D=src; sed -i "s/a/b/" "$D/app.ts"'
t warn  "braced variable onto source"         'D=src; echo x > ${D}/app.ts'
t allow "same-line assignment, scratchpad"    "D=$SCRATCH; echo x > \$D/o.txt"
t allow "an unset variable in the target"     'echo x > $SMH_UNSET_TARGET_DIR/out.log'
t allow "an unset variable, quoted target"    'sed -i "s/a/b/" "$SMH_UNSET_TARGET_DIR/chime.sh"'
t allow "command substitution as the target"  'echo x > $(mktemp)'
t allow "an empty redirect target"            'echo x > ""'
# HOME is always in the environment, so this one really does resolve - and lands
# outside every allowlisted path, which is the point: resolvable means judged.
t warn  "a resolvable env var onto source"    'echo x > $HOME/src/app.ts'

# The quoted-redirect bug in its own right: the target is a path the ORCHESTRATOR
# owns, and quoting it must not turn it into the empty string.
echo "a quoted redirect target keeps its value:"
t allow "quoted redirect into the handoff"    'echo x > "docs/ai-memory/note.md"'
t warn  "quoted redirect into a source file"  'echo x > "src/app.ts"'

# The invocation log is how any machine answers "is this guard even running?" - a
# hook that never ran and a hook that stayed silent look identical from the outside,
# and with nothing being blocked any more that is true of EVERY call. So the log is
# the only witness, and the `decision=warn` lines are the guard's whole visible
# product: a record of where the orchestrator drifted.
echo "the invocation log - one line per call, silence and warning alike:"
LOG="$CTX/$SID.handslog"
lt() { # <label> <grep -E pattern>
  if [ -f "$LOG" ] && grep -Eq "$2" "$LOG"; then pass=$((pass+1)); printf '  ok   log   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL log   %s\n' "$1"; fi
}
nt() { # <label> <pattern that must NOT appear>
  if [ -f "$LOG" ] && grep -q "$2" "$LOG"; then fail=$((fail+1)); printf '  FAIL log   %s\n' "$1"
  else pass=$((pass+1)); printf '  ok   log   %s\n' "$1"; fi
}
lt "a fall-through is logged with a reason"  'decision=allow reason=(no-write-target|allowlisted) '
lt "a warning is logged with its target"     'decision=warn reason=warned target=src/app\.ts'
lt "a subagent call is logged as such"       'decision=allow reason=subagent '
lt "an unresolvable target is logged"        'decision=allow reason=unresolvable-target '
lt "an empty target is logged"               'decision=allow reason=empty-target '
# A guard that switched itself off after N complaints is exactly the silent
# self-disablement this change removed. Nothing may ever log that again.
nt "no breaker token survives"               'breaker'
# A command line can hold a secret in an argument. Tool, decision, reason and the
# one offending path are enough, and the path is already in the warning.
nt "the command text never reaches the log"  's/a/b/'

rm -f "$CTX/$SID.hands" "$LOG"
echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
