#!/usr/bin/env bash
# Regression battery for the VOICE of say.sh / say.ps1.
#
# WHY THIS FILE EXISTS. say.ps1 used to choose its voice by matching a list of ten
# voice NAMES written into the script. On a machine where none of the ten was
# installed the match missed, control fell through to "first female voice in the
# list", and every spoken line came out in a voice nobody had chosen - on a box
# whose owner had written the voice he wanted into a config file that the speaker
# never read. Two failures in one: a preference hardcoded in a shared script, and a
# configuration mechanism that existed and was ignored.
#
#   bash say-voice.test.sh          (SAY=/path/to/say.sh to point it elsewhere)
#
# ⭐ WHAT IS ASSERTED, and why it is asserted this way: a voice cannot be verified by
# listening from a test, so what is verified is WHICH VALUE REACHED THE SYNTHESISER.
# A stub `edge-tts` on a fake PATH records its own argv, so "the configured value is
# the one that was asked for" becomes a string comparison. The value used is an
# obviously fake placeholder, never a real voice name, for the same reason the
# scripts under test hold none: a real name in a fixture is a name in the repo.
#
# ⚠️ EVERY CASE RUNS UNDER A FAKE $HOME AND A FAKE PATH, by construction: the hook
# reads $HOME/.claude/hooks/claude-voice.txt and shells out to a synthesiser, so a
# real HOME would make the result depend on which voice the person running the
# battery happens to have configured, and a real PATH would try to speak out loud.
# mktemp, removed on exit via trap - on success, failure and interrupt.
#
# ⚠️ A MISSING PREREQUISITE EXITS 2, NOT 0. 0 = green, 1 = a real failure,
# 2 = did not run.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SAY="${SAY:-$HERE/../say.sh}"
SAYPS1="${SAYPS1:-$HERE/../say.ps1}"

[ -f "$SAY" ]    || { echo "hook not found beside the test: $SAY"; exit 2; }
[ -f "$SAYPS1" ] || { echo "say.ps1 not found beside the test: $SAYPS1"; exit 2; }

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/say-voice-test.XXXXXX") || {
	echo "could not create a temp dir - refusing to run against the real HOME"; exit 2; }
cleanup() { [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT INT TERM HUP

pass=0; fail=0
ok()    { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()   { fail=$((fail+1)); printf '  FAIL %s\n         want: %s\n         got:  %s\n' "$1" "$2" "$3"; }
t()     { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains '$2'" "$3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1" "does NOT contain '$2'" "$3" ;; *) ok "$1" ;; esac; }

# ⛔ Placeholders, not voices. None of these is a real voice on any platform; the
# NeuralSuffix ones are shaped like a neural id only because the shape is the gate
# the code under test applies, and the shape is not a name.
V_FILE='xx-ZZ-NotARealVoiceNeural'
V_ENV='yy-QQ-AlsoNotRealNeural'
V_EXPLICIT='zz-WW-ThirdNotRealNeural'
V_NATIVE='NotARealNativeVoiceName'

# ── The fake PATH. Not an empty one: say.sh legitimately uses cat, tr, date, grep
# and friends, so a PATH of /nonexistent would break the code under test and the
# battery would "prove" a failure that never happens in the field. What is built is
# an ordinary PATH with the real tools and STUB synthesisers.
BIN="$TMPROOT/bin"
mkdir -p "$BIN" || { echo "cannot create the fixture bin dir"; exit 2; }
# bash is on the list because it is the INTERPRETER: env -i wipes the PATH, and a
# fixture PATH without bash on it makes every case exit 127 before the hook runs.
for tool in bash sh cat tr date grep mkdir rm wc tail mv uname head awk sleep printf; do
	p=$(command -v "$tool" 2>/dev/null) || { echo "this machine is missing $tool"; exit 2; }
	case "$p" in /*) ln -sf "$p" "$BIN/$tool" || exit 2 ;; esac
done

# Stub synthesiser: records its whole argv, then writes the media file it was asked
# for so the caller's `[ -s "$out" ]` check passes. EDGE_FAIL=1 makes it fail instead
# without writing anything, which is how the fall-through case is provoked.
ARGV="$TMPROOT/edge-argv"
cat > "$BIN/edge-tts" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$ARGV"
[ "\${EDGE_FAIL:-0}" = "1" ] && exit 1
[ -n "\${EDGE_SLEEP:-}" ] && sleep "\$EDGE_SLEEP"
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "--write-media" ] && out="\$a"; prev="\$a"; done
[ -n "\$out" ] && printf 'stub-mp3-bytes' > "\$out"
exit 0
SH
# Stub converter and stub player, so the rung can reach its "spoke" outcome with no
# audio hardware and no network anywhere in the battery.
cat > "$BIN/ffmpeg" <<'SH'
#!/bin/sh
last=""; for a in "$@"; do last="$a"; done
printf 'stub-wav-bytes' > "$last"
exit 0
SH
cat > "$BIN/paplay" <<SH
#!/bin/sh
printf 'played %s\n' "\$1" >> "$TMPROOT/played"
exit 0
SH
chmod +x "$BIN/edge-tts" "$BIN/ffmpeg" "$BIN/paplay" || exit 2

# One case = one fake HOME, so nothing leaks between them.
# run_say <case dir> <voice file contents ('' = no file)> <extra env...> -- speaks "one sentence"
CASE_HOME=""; CASE_LOG=""
run_say() { # <case name> <voice file contents or ''> [VAR=VAL ...]
	CASE_HOME="$TMPROOT/$1"
	CASE_LOG="$CASE_HOME/say.log"
	mkdir -p "$CASE_HOME/.claude/hooks"
	[ -n "$2" ] && printf '%s\n' "$2" > "$CASE_HOME/.claude/hooks/claude-voice.txt"
	shift 2
	env -i PATH="$BIN" HOME="$CASE_HOME" TMPDIR="$CASE_HOME" \
		CLAUDE_SAY_LOG="$CASE_LOG" "$@" \
		bash "$SAY" "one sentence" >"$CASE_HOME/out" 2>"$CASE_HOME/err"
}

# The speech is backgrounded on purpose (the caller is never blocked), so the proof
# arrives after the exit. Poll instead of sleeping a fixed amount: a fixed sleep is
# either flaky or slow, and on a loaded machine it is both.
wait_for() { # <file> <needle> - 0 when it appears within ~10s
	i=0
	while [ "$i" -lt 100 ]; do
		[ -f "$1" ] && case "$(cat "$1" 2>/dev/null)" in *"$2"*) return 0 ;; esac
		i=$((i+1)); sleep 0.1
	done
	return 1
}
settle() { i=0; while [ "$i" -lt 20 ]; do [ -f "$1" ] && return 0; i=$((i+1)); sleep 0.1; done; return 1; }

echo "-- the configured voice is the one that reaches the synthesiser"

# CASE 1: resolved from claude-voice.txt, with nothing in the environment at all.
# This is the case the old code could not do: the file existed and was never read.
rm -f "$ARGV"
run_say case1 "$V_FILE"
t   "case1 exit 0 (a courtesy never fails its caller)" 0 "$?"
if wait_for "$ARGV" "$V_FILE"; then ok "case1 claude-voice.txt reached the synthesiser"
else bad "case1 claude-voice.txt reached the synthesiser" "--voice $V_FILE" "$(cat "$ARGV" 2>/dev/null)"; fi
has "case1 argv names the configured voice" "--voice $V_FILE" "$(cat "$ARGV" 2>/dev/null)"
if wait_for "$CASE_LOG" "backend=edge-tts"; then ok "case1 log names the edge-tts rung"
else bad "case1 log names the edge-tts rung" "backend=edge-tts" "$(cat "$CASE_LOG" 2>/dev/null)"; fi
has "case1 log records a clean play" "rc=0" "$(cat "$CASE_LOG" 2>/dev/null)"

# CASE 2: $CLAUDE_VOICE outranks the file - same precedence chime.sh and
# voice-bake.sh use, so a session can override without editing the user's file.
rm -f "$ARGV"
run_say case2 "$V_FILE" CLAUDE_VOICE="$V_ENV"
wait_for "$ARGV" "$V_ENV" || true
has   "case2 \$CLAUDE_VOICE wins over the file" "--voice $V_ENV" "$(cat "$ARGV" 2>/dev/null)"
hasnt "case2 the file's value was not used"     "$V_FILE"        "$(cat "$ARGV" 2>/dev/null)"

# CASE 3: EDGE_TTS_VOICE stays the per-engine escape hatch and outranks both.
rm -f "$ARGV"
run_say case3 "$V_FILE" CLAUDE_VOICE="$V_ENV" EDGE_TTS_VOICE="$V_EXPLICIT"
wait_for "$ARGV" "$V_EXPLICIT" || true
has   "case3 EDGE_TTS_VOICE wins over both" "--voice $V_EXPLICIT" "$(cat "$ARGV" 2>/dev/null)"
hasnt "case3 neither of the others was used" "$V_ENV"             "$(cat "$ARGV" 2>/dev/null)"

echo "-- the shape gate: one config value, several engines that cannot share it"

# CASE 4: a NATIVE voice name is not offered to edge-tts, which 400s on one. It is
# left for the rungs that can speak it. Same gate voice-bake.sh applies.
rm -f "$ARGV"
run_say case4 "$V_NATIVE"
t "case4 exit 0" 0 "$?"
sleep 1
t "case4 a native voice name never reaches edge-tts" "absent" "$([ -f "$ARGV" ] && echo present || echo absent)"

# CASE 5: nothing configured at all - no file, no variable. It must still exit 0,
# must not invent a voice, and must leave a line saying what happened.
rm -f "$ARGV"
run_say case5 ""
t "case5 exit 0 with no configuration" 0 "$?"
sleep 1
t "case5 nothing configured means no edge-tts attempt" "absent" "$([ -f "$ARGV" ] && echo present || echo absent)"
if settle "$CASE_LOG"; then has "case5 silence is explained in the log" "backend=" "$(cat "$CASE_LOG" 2>/dev/null)"
else bad "case5 silence is explained in the log" "a log line" "no log at all"; fi

# CASE 5b: a voice file holding only whitespace reads as UNSET, not as a request for a
# voice named "". Asserted here because the reader that guarantees it (say_first_line)
# now sits at the top of the script and governs EVERY rung, not just macOS `say`: a
# blank file that read as a request would hand edge-tts an empty --voice and lose the
# sentence to a 400 on a machine whose owner had configured nothing at all.
rm -f "$ARGV"
CASE_HOME="$TMPROOT/case5b"; CASE_LOG="$CASE_HOME/say.log"
mkdir -p "$CASE_HOME/.claude/hooks"
printf '   \n\t\n' > "$CASE_HOME/.claude/hooks/claude-voice.txt"
env -i PATH="$BIN" HOME="$CASE_HOME" TMPDIR="$CASE_HOME" CLAUDE_SAY_LOG="$CASE_LOG" \
	bash "$SAY" "one sentence" >"$CASE_HOME/out" 2>"$CASE_HOME/err"
t "case5b exit 0 on a whitespace-only voice file" 0 "$?"
sleep 1
t "case5b whitespace-only reads as unset, so no engine was asked" "absent" "$([ -f "$ARGV" ] && echo present || echo absent)"

# CASE 5c: a \r-terminated line (a file written from the Windows side) is still the
# voice, not the voice plus a carriage return - the same reading the box-name file gets.
rm -f "$ARGV"
CASE_HOME="$TMPROOT/case5c"; CASE_LOG="$CASE_HOME/say.log"
mkdir -p "$CASE_HOME/.claude/hooks"
printf '%s\r\n' "$V_FILE" > "$CASE_HOME/.claude/hooks/claude-voice.txt"
env -i PATH="$BIN" HOME="$CASE_HOME" TMPDIR="$CASE_HOME" CLAUDE_SAY_LOG="$CASE_LOG" \
	bash "$SAY" "one sentence" >"$CASE_HOME/out" 2>"$CASE_HOME/err"
wait_for "$ARGV" "$V_FILE" || true
has "case5c the \\r never reached the synthesiser" "--voice $V_FILE --text" "$(cat "$ARGV" 2>/dev/null)"

echo "-- the ladder still has its lower rungs"

# CASE 6: the top rung failing must not eat the sentence. say.sh re-runs itself with
# the rung switched off rather than duplicating the platform ladder, so the log
# carries two lines: the failure, then whatever the platform could do (nothing here,
# because the fake PATH has no platform speech on it - which is itself the point:
# unexplained silence is the failure this log exists to close).
rm -f "$ARGV"
run_say case6 "$V_FILE" EDGE_FAIL=1
t "case6 exit 0 even though the top rung failed" 0 "$?"
wait_for "$CASE_LOG" "backend=none" || true
log6="$(cat "$CASE_LOG" 2>/dev/null)"
has "case6 the failed rung is named"          "backend=edge-tts" "$log6"
has "case6 and it says it fell through"       "falling through"  "$log6"
has "case6 the lower ladder then reported in" "backend=none"     "$log6"

# CASE 7: never blocks. The contract is one fork and return; a synthesiser that takes
# five seconds must cost the caller none of them.
rm -f "$ARGV"
start=$(date +%s)
run_say case7 "$V_FILE" EDGE_SLEEP=5
elapsed=$(( $(date +%s) - start ))
if [ "$elapsed" -le 2 ]; then ok "case7 returned in ${elapsed}s while the synthesiser took 5"
else bad "case7 returned promptly" "<=2s" "${elapsed}s"; fi

echo "-- no voice name is written in either script (the rule, asserted)"

# CASE 8: the standing rule, as a test rather than a comment. A name reintroduced
# into either file is caught here instead of being discovered by ear months later.
# The pattern is deliberately about SHAPE and about the two engines' spellings, so it
# catches a new hardcoded name without this file having to enumerate real ones.
hard="$(grep -nE "(-match|-like|SelectVoice\\(|-v )[^$]*'[A-Z][a-z]+([ (|][A-Za-z()]+)*'" "$SAYPS1" 2>/dev/null | grep -vE 'Female|Male|Desktop|\$wanted' || true)"
t "case8 say.ps1 matches no literal voice name" "" "$hard"
list="$(grep -cE '[A-Z][a-z]+\|[A-Z][a-z]+\|[A-Z][a-z]+' "$SAYPS1" 2>/dev/null || true)"
t "case8 say.ps1 has no alternation list of names" "0" "$list"
has "case8 say.ps1 reads the variable"   'CLAUDE_VOICE'     "$(cat "$SAYPS1")"
has "case8 say.ps1 reads the voice file" 'claude-voice.txt' "$(cat "$SAYPS1")"
has "case8 say.sh reads the variable"    'CLAUDE_VOICE'     "$(cat "$SAY")"
has "case8 say.sh reads the voice file"  'claude-voice.txt' "$(cat "$SAY")"
# ⛔ The two engines' own fallback must be the PLATFORM default, not a voice this
# file chose: that substitution is exactly how an unchosen voice spoke for weeks.
has "case8 say.ps1 falls back to the platform default" 'platform default' "$(cat "$SAYPS1")"

echo
printf '%d assertions: %d passed, %d failed\n' "$((pass+fail))" "$pass" "$fail"
[ "$fail" -eq 0 ]
