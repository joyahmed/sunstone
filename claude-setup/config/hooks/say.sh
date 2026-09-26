#!/usr/bin/env bash
# say.sh - speak one sentence, on whatever this machine can speak with. Never blocks,
# never fails: the sentence is a courtesy to a person who is not watching, not a gate.
#
#   bash ~/.claude/hooks/say.sh "Slice 3 is done. Taking up the README."
#
# THE LADDER, in order, first rung that speaks wins:
#   1. edge-tts, when a neural voice is CONFIGURED (see below) and the toolchain is
#      present. This rung exists because some good voices cannot be reached by any
#      other engine on the machine - a Narrator-locked voice is one of those - so
#      without it a configured voice can be silently ignored.
#   2. the platform's own speech:
#      macOS  -> `say`, the configured voice if installed, else the best quality
#                tier present (premium/enhanced voices appear after a download in
#                System Settings > Accessibility > Spoken Content > Manage Voices).
#      Windows (Git Bash) and WSL -> powershell.exe running say.ps1 beside this file.
#      Linux  -> Piper (~/.local/share/piper, PIPER_VOICE) if installed, else
#                spd-say or espeak.
#   3. nothing speaks -> one line in the log saying exactly that.
# SAY_OFF=1 (or a file ~/.claude/hooks/say-off) silences it everywhere.
# SAY_NO_EDGE=1 skips rung 1; the background fallback below sets it on itself.
#
# ⛔ WHICH VOICE IS CONFIGURATION, NEVER CODE. No voice name is written in this file
# or in say.ps1, and that is a rule. A voice is a per-machine, per-person setting:
# a name hardcoded in a shared script is wrong on every machine that does not have
# it installed, and worse, it fails quietly - the match misses, some fallback picks
# a voice nobody chose, and the file still looks like it is expressing a preference.
#   $CLAUDE_VOICE, else one line in $HOME/.claude/hooks/claude-voice.txt
# read exactly the way chime.sh and voice-bake.sh already read it - one mechanism,
# not a third invention. Empty means "whatever this platform gives", which is the
# setting the person already made in their OS, and that is a correct answer.
# ⚠️ $HOME differs per side (a WSL /home/<user> vs a Windows C:\Users\<user>), so
# each side's say.sh resolves its OWN side's file. EDGE_TTS_VOICE and PIPER_VOICE
# stay separate and still win for their own engine: a neural model id is a different
# kind of string from a native voice name, so one variable cannot serve both.
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

# ─────────────────────────────── the configured voice ───────────────────────────
# Two lines, deliberately identical to chime.sh's and voice-bake.sh's: $CLAUDE_VOICE
# wins, else the one line in claude-voice.txt beside the other name files. Exported,
# so every branch below and say.ps1 inherit it with no further plumbing.
# ⛔ Never written from here - the file is the user's.
say_voice="${CLAUDE_VOICE:-}"
[ -n "$say_voice" ] || say_voice="$(cat "$HOME/.claude/hooks/claude-voice.txt" 2>/dev/null | tr -d '\r\n')"
if [ -n "$say_voice" ]; then CLAUDE_VOICE="$say_voice"; export CLAUDE_VOICE; fi

# ── helpers shared by the edge-tts rung ────────────────────────────────────────
# `timeout` is not on a stock macOS, and a missing timeout must not cost the word.
say_t() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi; }

# A Windows path for a Unix one, when a translator exists (WSL: wslpath, Git Bash:
# cygpath). Same two-command shape voice-bake.sh uses.
say_win_path() {
  if command -v wslpath >/dev/null 2>&1; then wslpath -w "$1" 2>/dev/null
  elif command -v cygpath >/dev/null 2>&1; then cygpath -w "$1" 2>/dev/null
  else printf '%s' "$1"; fi
}

# edge-tts writes mp3 only, and every player below wants PCM wav.
say_to_wav() {
  if command -v ffmpeg >/dev/null 2>&1; then
    say_t 25 ffmpeg -nostdin -loglevel error -y -i "$1" -ar 22050 -ac 1 -c:a pcm_s16le "$2" >/dev/null 2>&1
  elif command -v ffmpeg.exe >/dev/null 2>&1; then
    say_t 40 ffmpeg.exe -nostdin -loglevel error -y -i "$(say_win_path "$1")" -ar 22050 -ac 1 -c:a pcm_s16le "$(say_win_path "$2")" >/dev/null 2>&1
  elif command -v sox >/dev/null 2>&1; then
    say_t 25 sox "$1" -r 22050 -c 1 -b 16 "$2" >/dev/null 2>&1
  else
    return 1
  fi
}

# Three ways in, in the order voice-bake.sh established them.
# ⚠️ On the Windows side the interpreter is python.exe and NEVER python3: that name
# there is a Microsoft Store alias stub which exits without running anything.
say_edge_synth() {   # <voice> <text> <mp3 out>
  if command -v edge-tts >/dev/null 2>&1; then
    say_t 30 edge-tts --voice "$1" --text "$2" --write-media "$3" >/dev/null 2>&1 && [ -s "$3" ] && return 0
  fi
  if command -v python3 >/dev/null 2>&1 && say_t 20 python3 -c 'import edge_tts' >/dev/null 2>&1; then
    say_t 30 python3 -m edge_tts --voice "$1" --text "$2" --write-media "$3" >/dev/null 2>&1 && [ -s "$3" ] && return 0
  fi
  if command -v python.exe >/dev/null 2>&1 && say_t 25 python.exe -c 'import edge_tts' >/dev/null 2>&1; then
    say_t 40 python.exe -m edge_tts --voice "$1" --text "$2" \
      --write-media "$(say_win_path "$3")" >/dev/null 2>&1 && [ -s "$3" ] && return 0
  fi
  return 1
}

# ⭐ PlaySync() given a PATH can return 0 without a sound having come out; an opened
# stream is the form measured audible here, so the Windows player uses .Stream.
say_player=none
say_play_wav() {   # <wav>
  say_player=none
  if command -v afplay >/dev/null 2>&1; then say_player=afplay; afplay "$1" >/dev/null 2>&1; return $?; fi
  for _p in pw-play paplay aplay; do
    command -v "$_p" >/dev/null 2>&1 || continue
    say_player="$_p"
    "$_p" "$1" >/dev/null 2>&1 && return 0
  done
  if command -v powershell.exe >/dev/null 2>&1; then
    say_player=soundplayer
    _w="$(say_win_path "$1")"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
      "\$p = New-Object Media.SoundPlayer; \$p.Stream = [IO.File]::OpenRead('$_w'); \$p.PlaySync(); \$p.Stream.Close()" >/dev/null 2>&1
    return $?
  fi
  return 1
}

# ── Rung 1: edge-tts ───────────────────────────────────────────────────────────
# Only for a value SHAPED like a neural id (<locale>-<Name>Neural), which is the
# same gate voice-bake.sh applies: a native voice name means nothing to edge-tts,
# which 400s on it, so a value of the other kind is left for the rungs that speak it.
# ⚠️ EDGE_TTS_VOICE is the explicit escape hatch and wins, exactly as it does there.
# The whole attempt is inside a background subshell - the caller is freed by one fork
# as before - and on failure that subshell re-runs this script with the rung off, so
# the platform ladder still gets its turn without a line of it being duplicated here.
say_edge_want="${EDGE_TTS_VOICE:-$say_voice}"
case "${SAY_NO_EDGE:-0}:$say_edge_want" in
  1:*) ;;
  *:*-*Neural)
    (
      mp3="${TMPDIR:-/tmp}/claude-say-$$.mp3"; wav="${TMPDIR:-/tmp}/claude-say-$$.wav"
      stage=synth; rc=1
      if say_edge_synth "$say_edge_want" "$text" "$mp3"; then
        stage=convert
        if say_to_wav "$mp3" "$wav" && [ -s "$wav" ]; then
          stage=play
          say_play_wav "$wav"; rc=$?
        fi
      fi
      rm -f "$mp3" "$wav" 2>/dev/null
      if [ "$rc" -eq 0 ]; then
        say_log "backend=edge-tts voice=$(say_flatten "$say_edge_want") stage=$stage player=$say_player rc=0"
      else
        say_log "backend=edge-tts voice=$(say_flatten "$say_edge_want") stage=$stage player=$say_player rc=$rc, falling through to the platform ladder"
        # ⛔ Not a duplicated ladder: the same script, one rung lower.
        # ⚠️ bash, not sh: the helpers above use ${var//} and `local`, so a re-exec
        # under dash would break the script it is trying to give a second chance.
        if [ -r "$0" ]; then
          if command -v bash >/dev/null 2>&1; then SAY_NO_EDGE=1 exec bash "$0" "$text"
          else SAY_NO_EDGE=1 exec sh "$0" "$text"; fi
        fi
      fi
    ) >/dev/null 2>&1 &
    exit 0
    ;;
esac

if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
  # ⛔ This used to be a list of ten voice NAMES written here, which is the defect
  # this file now refuses: on a Mac without those downloads it matched nothing and
  # the choice silently became `say`'s default while looking deliberate. What is
  # left is (a) the configured voice and (b) a QUALITY TIER, which is a property of
  # the install rather than a name - premium and enhanced voices only exist on a box
  # where someone downloaded one, so their presence IS the preference.
  voice=""
  voices="$(say -v '?' 2>/dev/null)"
  if [ -n "$say_voice" ] && printf '%s\n' "$voices" | grep -q "^$say_voice "; then voice="$say_voice"; fi
  if [ -z "$voice" ]; then
    for tier in '(Premium)' '(Enhanced)'; do
      voice="$(printf '%s\n' "$voices" | grep -F "$tier" | head -1 | awk -F'  +' '{print $1}')"
      [ -n "$voice" ] && break
    done
  fi
  # Still empty -> no -v flag at all, i.e. the voice chosen in System Settings.
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
  # An exported variable does NOT cross into a Windows process on its own; WSLENV is
  # the only route, and it is appended to rather than replaced so anything already
  # being forwarded keeps going. Same mechanism chime.sh uses for the same reason.
  if [ -n "$say_voice" ]; then WSLENV="${WSLENV:+$WSLENV:}CLAUDE_VOICE"; export WSLENV; fi
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
# (binary at piper/piper, models in voices/). Same layout chime.sh uses, so the
# slice sentence and the chime speak in one voice.
# Which model: PIPER_VOICE, else $CLAUDE_VOICE when a model of that name is actually
# installed, else the first model present. ⛔ No model id is named here - a default
# written into this file is a voice nobody chose on every box that has a different
# model installed, which is the defect this file exists without.
piper="$HOME/.local/share/piper/piper/piper"
vdir="$HOME/.local/share/piper/voices"
voice=""
if [ -n "${PIPER_VOICE:-}" ]; then voice="$vdir/$PIPER_VOICE.onnx"
elif [ -n "$say_voice" ] && [ -r "$vdir/$say_voice.onnx" ]; then voice="$vdir/$say_voice.onnx"; fi
if [ -z "$voice" ] || [ ! -r "$voice" ]; then
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
  say_log 'backend=none outcome=no backend found (no edge-tts for a configured neural voice, no macOS say, no WSL powershell, no piper, no spd-say, no espeak), nothing was spoken'
fi
exit 0
