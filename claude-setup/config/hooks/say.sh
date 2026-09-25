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
set -u
text="${1:-}"
[ -n "$text" ] || exit 0
[ "${SAY_OFF:-0}" = "1" ] && exit 0
[ -e "$HOME/.claude/hooks/say-off" ] && exit 0

if [ "$(uname -s)" = "Darwin" ]; then
  voice=""
  voices="$(say -v '?' 2>/dev/null)"
  for v in "Zoe (Premium)" "Ava (Premium)" "Samantha (Enhanced)" "Allison (Enhanced)" \
           "Zoe (Enhanced)" "Ava (Enhanced)" "Karen (Premium)" "Karen (Enhanced)" "Karen" "Samantha"; do
    if printf '%s\n' "$voices" | grep -q "^$v "; then voice="$v"; break; fi
  done
  say ${voice:+-v "$voice"} "$text" >/dev/null 2>&1 &
  exit 0
fi

if grep -qi microsoft /proc/version 2>/dev/null && command -v powershell.exe >/dev/null 2>&1; then
  ps1="$HOME/.claude/hooks/say.ps1"
  [ -r "$ps1" ] || exit 0
  win="$(wslpath -w "$ps1" 2>/dev/null)" || exit 0
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$win" -Text "$text" >/dev/null 2>&1 &
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
  {
    wav="${TMPDIR:-/tmp}/claude-say-$$.wav"
    if printf '%s' "$text" | "$piper" -m "$voice" -f "$wav"; then
      for p in pw-play paplay aplay; do
        command -v "$p" >/dev/null 2>&1 && "$p" "$wav" && break
      done
    fi
    rm -f "$wav"
  } >/dev/null 2>&1 &
  exit 0
fi

if command -v spd-say >/dev/null 2>&1; then spd-say "$text" >/dev/null 2>&1 &
elif command -v espeak >/dev/null 2>&1; then espeak "$text" >/dev/null 2>&1 &
fi
exit 0
