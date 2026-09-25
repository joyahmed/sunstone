#!/usr/bin/env bash
# say.sh - speak one sentence, on whatever this machine can speak with. Never blocks,
# never fails: the sentence is a courtesy to a person who is not watching, not a gate.
#
#   bash ~/.claude/hooks/say.sh "Slice 3 is done. Taking up the README."
#
# macOS  -> `say`, best installed voice (premium/enhanced ones appear after a download
#           in System Settings > Accessibility > Spoken Content > Manage Voices).
# WSL    -> powershell.exe running say.ps1 beside this file (Windows neural voice).
# Linux  -> Piper (~/.local/share/piper, PIPER_VOICE) if installed, else spd-say or
#           espeak; otherwise silent.
# SAY_OFF=1 (or a file ~/.claude/hooks/say-off) silences it everywhere.
#
# ⛔ WHY THERE IS A LOG, found on 2026-09-26: every branch below backgrounds its
# speech process and then exits 0, discarding stdout and stderr. AN EXIT CODE THAT
# DESCRIBES A FORK IS NOT EVIDENCE OF SPEECH. It says the shell managed to start a
# child; it says nothing about whether a word came out. A caller - human or script -
# could not tell "spoke" from "silently did nothing".
#
# ⭐ Measured the same evening on two machines, and the pair is the whole argument:
# on WSL the WinRT neural path was failing outright (0x80131539, "Operation is not
# supported on this platform") and only the SAPI fallback could speak; on macOS the
# speech genuinely worked, confirmed by a person hearing it. Both machines returned 0
# all evening. Opposite realities, identical report - so the report was the bug.
#
# The fix keeps the no-blocking guarantee and buys the evidence in the background:
# the subshell that owns the speech waits for it, then appends ONE line naming the
# backend it chose, the exit status it got and whatever it said on stderr. Where no
# backend exists at all, that line is written here and now and says so in words,
# because unexplained silence is exactly the failure being closed. Same spirit as
# run-node.sh, which refuses to skip a hook without saying one sentence about why.
#
# Log: $HOME/.claude/claude-say.log, override with CLAUDE_SAY_LOG (empty = no log).
# It sits beside the rest of Claude Code's per-user state rather than in a temp
# directory, because the point is to still be readable tomorrow morning. It is
# capped (SAY_LOG_MAX_LINES, default 400) and trimmed to half when it overflows, so
# it can never grow without limit. say.ps1 keeps its own %TEMP%\claude-say-errors.log
# on the Windows side; this one is the Unix-side record and covers every platform.
set -u
text="${1:-}"
[ -n "$text" ] || exit 0

# ---------------------------------------------------------------- logging helpers
# Everything here is best-effort by construction: a logging failure must never cost
# a session a word, so every write is guarded and every helper returns success.
SAY_LOG="${CLAUDE_SAY_LOG-$HOME/.claude/claude-say.log}"
SAY_LOG_MAX_LINES="${SAY_LOG_MAX_LINES:-400}"
if [ -n "$SAY_LOG" ]; then
  say_log_dir="${SAY_LOG%/*}"
  [ "$say_log_dir" = "$SAY_LOG" ] || [ -d "$say_log_dir" ] || mkdir -p "$say_log_dir" 2>/dev/null || SAY_LOG=""
fi

# ⚠️ macOS still ships bash 3.2, which has no `printf '%(...)T'` builtin, so date(1)
# comes first. But the no-backend case can be reached with a PATH so broken that even
# date is missing - which is precisely when the log matters most - so the builtin is
# the fallback, and a stamp that resolved to neither says so instead of leaking a raw
# format string into the file.
say_now() {
  local t=""
  t="$(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null)" || t=""
  if [ -z "$t" ]; then printf -v t '%(%Y-%m-%dT%H:%M:%S%z)T' -1 2>/dev/null || t=""; fi
  case "$t" in ''|*'%('*) t="time-unknown" ;; esac
  printf '%s' "$t"
}

# A backend's stderr is folded onto the single log line: newlines become " | " and
# anything past 300 characters is cut. One invocation is one line, always - a stack
# trace that wrapped over twenty of them would defeat reading the file at a glance.
say_flatten() {
  local s="$*"
  s="${s//$'\r'/}"
  s="${s//$'\n'/ | }"
  [ "${#s}" -le 300 ] || s="${s:0:300}..."
  printf '%s' "$s"
}

# Trim before appending, never after, so the line just earned is always the one kept.
# wc/tail/mv are checked rather than assumed: on a machine bare enough to lack them
# an uncapped log is the lesser problem, and it is also a machine that cannot speak.
say_log_trim() {
  [ -n "$SAY_LOG" ] && [ -f "$SAY_LOG" ] || return 0
  command -v wc >/dev/null 2>&1 && command -v tail >/dev/null 2>&1 || return 0
  local n keep
  n="$(wc -l <"$SAY_LOG" 2>/dev/null)" || return 0
  n="${n// /}"
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  [ "$n" -gt "$SAY_LOG_MAX_LINES" ] || return 0
  keep=$(( SAY_LOG_MAX_LINES / 2 ))
  [ "$keep" -ge 1 ] || keep=1
  if tail -n "$keep" "$SAY_LOG" >"$SAY_LOG.tmp" 2>/dev/null; then
    mv -f "$SAY_LOG.tmp" "$SAY_LOG" 2>/dev/null || rm -f "$SAY_LOG.tmp" 2>/dev/null
  else
    rm -f "$SAY_LOG.tmp" 2>/dev/null
  fi
  return 0
}

say_log() {
  [ -n "$SAY_LOG" ] || return 0
  say_log_trim
  printf '%s %s\n' "$(say_now)" "$*" >>"$SAY_LOG" 2>/dev/null
  return 0
}
# --------------------------------------------------------------------------------

# Muted is a legitimate reason for silence, but it is still a reason, and a person
# who heard nothing deserves to find it written down rather than guess at it.
[ "${SAY_OFF:-0}" = "1" ] && { say_log 'backend=none outcome=muted reason=SAY_OFF=1 nothing was spoken'; exit 0; }
[ -e "$HOME/.claude/hooks/say-off" ] && { say_log 'backend=none outcome=muted reason=say-off file present, nothing was spoken'; exit 0; }

if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
  voice=""
  voices="$(say -v '?' 2>/dev/null)"
  for v in "Zoe (Premium)" "Ava (Premium)" "Samantha (Enhanced)" "Allison (Enhanced)" \
           "Zoe (Enhanced)" "Ava (Enhanced)" "Karen (Premium)" "Karen (Enhanced)" "Karen" "Samantha"; do
    if printf '%s\n' "$voices" | grep -q "^$v "; then voice="$v"; break; fi
  done
  # The caller is freed here; the subshell stays behind to wait for `say` and write
  # the verdict. stdout is still discarded - only stderr is worth keeping - so the
  # latency the caller sees is unchanged: one fork, exactly as before.
  # ⛔ This branch used to discard stderr with no log anywhere on the machine, which
  # made macOS the one platform where a failure left no trace at all.
  (
    err="$(say ${voice:+-v "$voice"} "$text" 2>&1 >/dev/null)"; rc=$?
    say_log "backend=macos-say voice=${voice:-default} rc=$rc${err:+ stderr=$(say_flatten "$err")}"
  ) >/dev/null 2>&1 &
  exit 0
fi

# Native Windows (Git Bash / MSYS / Cygwin): this is NOT WSL - /proc/version exists but
# carries no "microsoft", so the WSL branch below is skipped and the Linux fallback finds
# no TTS and exits 0. That made the sentence silently vanish on a native Windows box while
# every call still reported success. Speak through say.ps1 beside this file; the path needs
# cygpath, not wslpath, which does not exist here.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    ps1="$HOME/.claude/hooks/say.ps1"
    [ -r "$ps1" ] || exit 0
    win="$(cygpath -w "$ps1" 2>/dev/null)" || exit 0
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$win" -Text "$text" >/dev/null 2>&1 &
    exit 0
    ;;
esac

if grep -qi microsoft /proc/version 2>/dev/null && command -v powershell.exe >/dev/null 2>&1; then
  ps1="$HOME/.claude/hooks/say.ps1"
  [ -r "$ps1" ] || { say_log 'backend=none outcome=unavailable reason=wsl but say.ps1 is missing or unreadable, nothing was spoken'; exit 0; }
  win="$(wslpath -w "$ps1" 2>/dev/null)" || { say_log 'backend=none outcome=unavailable reason=wslpath could not translate say.ps1, nothing was spoken'; exit 0; }
  # ⚠️ rc=0 here means powershell.exe exited cleanly, which say.ps1 does even when
  # its WinRT voice fails and the SAPI fallback carries the sentence. Which of the
  # two actually spoke is say.ps1's own record: %TEMP%\claude-say-errors.log.
  (
    err="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$win" -Text "$text" 2>&1 >/dev/null)"; rc=$?
    say_log "backend=wsl-powershell rc=$rc${err:+ stderr=$(say_flatten "$err")}"
  ) >/dev/null 2>&1 &
  exit 0
fi

# Native Linux: Piper neural TTS when it is installed under ~/.local/share/piper
# (binary at piper/piper, models in voices/). PIPER_VOICE names the model; default
# en_US-amy-medium, else the first model present. Same layout chime.sh uses, so the
# slice sentence and the chime speak in one voice.
piper="$HOME/.local/share/piper/piper/piper"
vdir="$HOME/.local/share/piper/voices"
voice="$vdir/${PIPER_VOICE:-en_US-amy-medium}.onnx"
if [ ! -r "$voice" ]; then
  for f in "$vdir"/*.onnx; do [ -r "$f" ] && { voice="$f"; break; }; done
fi
if [ -x "$piper" ] && [ -r "$voice" ]; then
  (
    wav="${TMPDIR:-/tmp}/claude-say-$$.wav"
    err="$( { printf '%s' "$text" | "$piper" -m "$voice" -f "$wav"; } 2>&1 >/dev/null )"; rc=$?
    # ⭐ Two ways to be silent here and they must not look alike: synthesis failing,
    # and synthesis succeeding into a wav that no player on this box can play.
    stage="synth"; player="none"
    if [ "$rc" -eq 0 ]; then
      stage="play"
      for p in pw-play paplay aplay; do
        command -v "$p" >/dev/null 2>&1 || continue
        perr="$("$p" "$wav" 2>&1 >/dev/null)"; rc=$?; player="$p"
        [ -n "$perr" ] && err="${err:+$err | }$perr"
        [ "$rc" -eq 0 ] && break
      done
      [ "$player" = "none" ] && err="${err:+$err | }no audio player found (pw-play, paplay, aplay), the wav was synthesised but never played"
    fi
    rm -f "$wav" 2>/dev/null
    say_log "backend=piper voice=$(say_flatten "${voice##*/}") stage=$stage player=$player rc=$rc${err:+ stderr=$(say_flatten "$err")}"
  ) >/dev/null 2>&1 &
  exit 0
fi

if command -v spd-say >/dev/null 2>&1; then
  ( err="$(spd-say "$text" 2>&1 >/dev/null)"; rc=$?
    say_log "backend=spd-say rc=$rc${err:+ stderr=$(say_flatten "$err")}" ) >/dev/null 2>&1 &
elif command -v espeak >/dev/null 2>&1; then
  ( err="$(espeak "$text" 2>&1 >/dev/null)"; rc=$?
    say_log "backend=espeak rc=$rc${err:+ stderr=$(say_flatten "$err")}" ) >/dev/null 2>&1 &
else
  # ⛔ The line this whole change exists for. Reaching here means the machine has no
  # speech at all; before, it exited 0 like every healthy machine and left nobody a
  # way to find that out.
  say_log 'backend=none outcome=no backend found (no macOS say, no WSL powershell, no piper, no spd-say, no espeak), nothing was spoken'
fi
exit 0
