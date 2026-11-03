#!/usr/bin/env bash
# sound-gate.sh - mute the voice and chime of ONE Claude session, or let only one speak.
#
#   /mute     this session stays silent          /unmute   it speaks again
#   /solo     only this session makes sound      /unsolo   every session speaks again
#   /sound    list the running sessions and which ones are muted
#
# Typed in a session, those five are caught by the UserPromptSubmit hook (`sound-gate.sh
# prompt`) and answered at once, without a model turn. say.sh and chime.sh call
# `sound-gate.sh check` before making any sound.
#
# WHICH session: the `claude` process that owns the caller, found by walking up the
# parent processes. Hooks AND the commands a session runs (say.sh lines in supermode)
# are both children of that process, so they resolve to the same session without a
# session id - commands never see one.
#
# Fails open: if the session cannot be found (no ps, a shell outside Claude), sound plays.
# State: $CLAUDE_SOUND_DIR (default ~/.claude/state/sound): muted/<pid> files, and solo
# holding one pid. A pid that is no longer running is ignored and cleaned up.

# WSL and Windows on one PC share ONE list, so /solo on either side silences the other side
# too: WSL uses the Windows user's ~/.claude/state/sound when there is exactly one such user.
is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }
win_home_from_wsl() {
  local found=() d
  for d in /mnt/c/Users/*/.claude; do [ -d "$d" ] && found+=("${d%/.claude}"); done
  [ "${#found[@]}" -eq 1 ] && printf '%s' "${found[0]}"
}
if [ -n "${CLAUDE_SOUND_DIR:-}" ]; then dir="$CLAUDE_SOUND_DIR"
elif is_wsl && wh="$(win_home_from_wsl)" && [ -n "$wh" ]; then dir="$wh/.claude/state/sound"
else dir="$HOME/.claude/state/sound"; fi

# Windows (Git Bash / MSYS): claude.exe is a Windows process that MSYS `ps` cannot see, so
# walk the WINDOWS parent chain from this shell's Windows pid with PowerShell instead.
# Ids are prefixed "w" so they never collide with a Linux pid. CLAUDE_PROC_NAME is for tests.
is_windows() { case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }
ps1() { powershell.exe -NoProfile -NonInteractive -Command "$1" 2>/dev/null | tr -d '\r'; }

claude_pid() {
  if is_windows; then
    local wp name="${CLAUDE_PROC_NAME:-claude}" mp=$$ mpp
    # MSYS forks through short-lived helper processes, so the Windows parent chain breaks at
    # every bash level. Climb the MSYS tree to its top process first (its Windows parent is
    # whatever started Git Bash - claude.exe for a hook), then walk the Windows chain from there.
    while mpp="$(cat "/proc/$mp/ppid" 2>/dev/null)" && [ -n "$mpp" ] && [ "$mpp" -gt 1 ] && [ -e "/proc/$mpp/winpid" ]; do
      mp=$mpp
    done
    wp="$(cat "/proc/$mp/winpid" 2>/dev/null)"
    [ -n "$wp" ] || return 1
    wp="$(ps1 "\$p=$wp; for(\$i=0; \$i -lt 40 -and \$p; \$i++){ \$q=Get-CimInstance Win32_Process -Filter \"ProcessId=\$p\"; if(-not \$q){break}; if(\$i -gt 0 -and (\$q.Name -like '$name.exe' -or \$q.Name -eq '$name')){ \$q.ProcessId; break }; \$p=\$q.ParentProcessId }")"
    [ -n "$wp" ] || return 1
    echo "w$wp"; return 0
  fi
  local p=$$ pp comm
  while [ "${p:-0}" -gt 1 ]; do
    read -r pp comm < <(ps -o ppid= -o comm= -p "$p" 2>/dev/null) || return 1
    [ "${comm##*/}" = "claude" ] && { echo "$p"; return 0; }
    p=$pp
  done
  return 1
}

alive() {
  [ -n "$1" ] || return 1
  case "$1" in
    w*) if is_windows; then [ -n "$(ps1 "Get-Process -Id ${1#w} -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id")" ]
        elif is_wsl; then [ -n "$(powershell.exe -NoProfile -NonInteractive -Command "Get-Process -Id ${1#w} -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id" 2>/dev/null | tr -d '\r')" ]
        else return 1; fi ;;
    *) if is_windows; then wsl.exe -e kill -0 "$1" >/dev/null 2>&1   # a WSL session's id, seen from Windows
       else kill -0 "$1" 2>/dev/null; fi ;;
  esac
}

session_label() {
  # The folder the session works in is what tells two sessions apart
  case "$1" in w*) printf 'Windows session %s' "${1#w}"; return ;; esac
  if is_windows; then printf 'WSL session %s' "$1"; return; fi
  local cwd
  cwd="$(readlink "/proc/$1/cwd" 2>/dev/null || lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
  case "$cwd" in "$HOME"*) cwd="~${cwd#"$HOME"}" ;; esac
  printf '%s' "$cwd"
}

solo_pid() {
  local sp
  sp="$(cat "$dir/solo" 2>/dev/null)"
  if [ -n "$sp" ] && ! alive "$sp"; then rm -f "$dir/solo"; sp=""; fi
  printf '%s' "$sp"
}

check() {
  local pid sp
  pid="$(claude_pid)" || return 0
  sp="$(solo_pid)"
  [ -n "$sp" ] && [ "$sp" != "$pid" ] && return 1
  [ -e "$dir/muted/$pid" ] && return 1
  return 0
}

status() {
  local sp pids p state
  sp="$(solo_pid)"
  if is_windows; then
    pids="$(ps1 "Get-Process claude -ErrorAction SilentlyContinue | ForEach-Object { 'w' + \$_.Id }") $(wsl.exe -e pgrep -x claude 2>/dev/null | tr -d '\r')"
  elif is_wsl; then
    pids="$(pgrep -x claude 2>/dev/null) $(powershell.exe -NoProfile -NonInteractive -Command "Get-Process claude -ErrorAction SilentlyContinue | ForEach-Object { 'w' + \$_.Id }" 2>/dev/null | tr -d '\r')"
  else
    pids="$(pgrep -x claude 2>/dev/null)"
  fi
  for f in "$dir"/muted/*; do [ -e "$f" ] && ! alive "${f##*/}" && rm -f "$f"; done
  [ -z "$pids" ] && { echo "No running sessions found."; return; }
  for p in $pids; do
    if [ -n "$sp" ]; then
      [ "$p" = "$sp" ] && state="SOLO (only this one speaks)" || state="silent (another session is solo)"
    elif [ -e "$dir/muted/$p" ]; then state="muted"
    else state="sound on"; fi
    [ "$p" = "$1" ] && state="$state  <- this session"
    printf '%-7s %-34s %s\n' "$p" "$(session_label "$p")" "$state"
  done
}

act() {
  local action="$1" pid
  pid="$(claude_pid)" || { echo "Could not find this Claude session, nothing changed."; return 1; }
  mkdir -p "$dir/muted"
  case "$action" in
    mute)   touch "$dir/muted/$pid"; echo "Muted this session ($(session_label "$pid")). /unmute to hear it again." ;;
    unmute) rm -f "$dir/muted/$pid"
            if [ -n "$(solo_pid)" ] && [ "$(solo_pid)" != "$pid" ]; then
              echo "Unmuted, but another session is solo, so this one stays quiet until /unsolo."
            else echo "Sound is on for this session."; fi ;;
    solo)   rm -f "$dir/muted/$pid"; printf '%s' "$pid" > "$dir/solo"
            echo "Solo: only this session ($(session_label "$pid")) makes sound now. /unsolo to hear all." ;;
    unsolo) rm -f "$dir/solo"; echo "Solo off: every session that is not muted makes sound again." ;;
    sound|status) status "$pid" ;;
  esac
}

# ─────────────────────────── ONE VOICE AT A TIME (the turn) ───────────────────────────
# 2026-11-03: several sessions on one PC (WSL and Windows, two of each) spoke at once and
# most of it was lost.
# Now every PLAY step (never synthesis, never the hook itself) runs between
#   tok="$(bash sound-gate.sh acquire <label>)"  ...play...  bash sound-gate.sh release "$tok"
# inside a job that is already in the background, so waiting never blocks a session.
#
# - Lock: `mkdir $dir/speaking.lock` - atomic on ext4, APFS, NTFS over /mnt/c (drvfs) and in
#   Git Bash; flock does not cross WSL<->Windows. $dir is the SAME folder sound-gate already
#   shares between WSL and Windows on one PC, so both sides queue together.
# - Order: each waiter drops a ticket $dir/turnq/<arrival-ns>-<owner> and only the OLDEST live
#   ticket may try the lock, so voices play in arrival order. A waiter rewrites its ticket
#   with the time on every poll; a ticket not refreshed for 5s is a dead waiter and is removed.
# - Stale: a lock older than 45s is a broken play and is taken over.
# - Give up: a message still waiting after 120s is dropped (exit 3) and logged, not played late.
# - Gap: the holder keeps the lock 0.7s after its sound ends, so voices never butt together.
# - Fail open: no writable $dir -> acquire returns at once and the sound plays as before.
# One line per acquire/drop/release goes to the say log ($CLAUDE_SAY_LOG, ~/.claude/claude-say.log).
TURN_STALE="${SOUND_TURN_STALE:-45}"; TURN_GIVEUP="${SOUND_TURN_GIVEUP:-120}"; TURN_GAP="${SOUND_TURN_GAP:-0.7}"
turn_now_ns() { local t; t="$(date +%s%N 2>/dev/null)"; case "$t" in ''|*[!0-9]*) t="$(date +%s)000000000" ;; esac; printf '%019d' "$t" 2>/dev/null || printf '%s' "$t"; }
turn_stamp() { local t; t="$(date +%Y-%m-%dT%H:%M:%S.%N%z 2>/dev/null)"; case "$t" in *N*|'') t="$(date +%Y-%m-%dT%H:%M:%S%z)" ;; *) t="$(printf '%s' "$t" | sed 's/\(\.[0-9]\{3\}\)[0-9]*/\1/')" ;; esac; printf '%s' "$t"; }
turn_log() {
  local log="${CLAUDE_SAY_LOG-$HOME/.claude/claude-say.log}"
  [ -n "$log" ] || return 0
  printf '%s %s\n' "$(turn_stamp)" "$*" >>"$log" 2>/dev/null
  return 0
}
turn_side() { if is_windows; then printf win; elif is_wsl; then printf wsl; elif [ "$(uname -s)" = Darwin ]; then printf mac; else printf linux; fi; }

turn_acquire() {   # <label>; prints the owner token; exit 0 = play now, 3 = dropped
  local label="${1:-sound}" lock="$dir/speaking.lock" q="$dir/turnq" me tk t0 now first f hb o st
  me="$(turn_side)-$PPID-$$"
  printf '%s' "$me"
  { mkdir -p "$q" && [ -w "$q" ]; } 2>/dev/null || { turn_log "turn=failopen by=$me what=$label reason=no writable $q"; return 0; }
  tk="$q/$(turn_now_ns)-$me"
  t0="$(date +%s)"
  while :; do
    now="$(date +%s)"
    printf '%s' "$now" >"$tk" 2>/dev/null || { turn_log "turn=failopen by=$me what=$label reason=cannot write ticket"; return 0; }
    first=""
    for f in "$q"/*; do
      [ -e "$f" ] || continue
      if [ "$f" != "$tk" ]; then
        hb="$(cat "$f" 2>/dev/null)"; case "$hb" in ''|*[!0-9]*) hb=0 ;; esac
        if [ $((now - hb)) -gt 5 ]; then rm -f "$f" 2>/dev/null; continue; fi
      fi
      first="$f"; break
    done
    if [ "$first" = "$tk" ]; then
      if mkdir "$lock" 2>/dev/null; then
        printf '%s %s\n' "$me" "$now" >"$lock/owner" 2>/dev/null
        rm -f "$tk" 2>/dev/null
        turn_log "turn=acquired by=$me waited=$((now - t0))s what=$label"
        return 0
      fi
      read -r o st 2>/dev/null <"$lock/owner" || { o=""; st=""; }
      case "$st" in ''|*[!0-9]*)
        # mkdir landed but owner not written yet (a few ms), or its writer died between the
        # two: use the folder's own age so a bare folder cannot block forever.
        st="$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null)"
        case "$st" in ''|*[!0-9]*) st="$now" ;; esac ;;
      esac
      if [ $((now - st)) -gt "$TURN_STALE" ]; then
        rm -rf "$lock" 2>/dev/null
        turn_log "turn=stale-removed by=$me held_by=${o:-unknown} age=$((now - st))s"
        continue
      fi
    fi
    if [ $((now - t0)) -ge "$TURN_GIVEUP" ]; then
      rm -f "$tk" 2>/dev/null
      turn_log "turn=dropped by=$me after=${TURN_GIVEUP}s what=$label"
      return 3
    fi
    sleep 0.25
  done
}

turn_release() {   # <token from acquire>; keeps the lock for the gap, then frees it
  local me="$1" lock="$dir/speaking.lock" o st
  [ -n "$me" ] || return 0
  read -r o st 2>/dev/null <"$lock/owner" || return 0
  [ "$o" = "$me" ] || return 0
  sleep "$TURN_GAP" 2>/dev/null
  # Logged BEFORE the folder goes, so the next "acquired" stamp is always later than this one.
  turn_log "turn=released by=$me held=$(( $(date +%s) - ${st:-0} ))s"
  rm -rf "$lock" 2>/dev/null
}

# ─────────────────── which session is talking, when two share a name ───────────────────
# 2026-11-03: there can be two sessions of each name. Two same-name sessions sound identical, so
# when MORE THAN ONE claude process runs on this side, `prefix [cwd]` prints "<name>, <project>"
# and say.sh / chime.sh put it in front of the sentence. With one session it prints nothing
# and the sentence is unchanged. Liveness = the process table, the same source `status`
# uses: instant and exact on Linux/WSL/macOS; on Windows `tasklist` is cached for 30s.
# Name: claude-name.txt, else the short hostname.
# Project: basename of the session's cwd (argument, else the claude process's cwd, else
# $PWD), with - _ . turned to spaces and a leading number dropped, as chime.sh does.
# Fails open: no count -> nothing printed.
# A claude process is not always a session: `claude --chrome-native-host` (the browser bridge)
# runs beside a session all day - measured 2026-11-03 on a Windows side, 1 session and
# 2 claude.exe - and `claude mcp serve` / `claude -p` are not someone the user can hear either.
TURN_NOT_SESSION='chrome-native-host|mcp serve|--print| -p( |$)'
live_count() {
  if is_windows; then
    local cache="$HOME/.claude/state/sound-live-count" c ts now
    now="$(date +%s)"
    read -r ts c 2>/dev/null <"$cache"
    case "$ts:$c" in *[!0-9:]*|:*|*:) ts=0 ;; esac
    if [ $((now - ts)) -gt 30 ]; then
      c="$(ps1 "@(Get-CimInstance Win32_Process -Filter \"Name='claude.exe'\" | Where-Object { \$_.CommandLine -notmatch '$TURN_NOT_SESSION' }).Count")" || c=""
      case "$c" in ''|*[!0-9]*) return 1 ;; esac
      mkdir -p "${cache%/*}" 2>/dev/null; printf '%s %s\n' "$now" "$c" >"$cache" 2>/dev/null
    fi
    printf '%s' "$c"
  else
    # ps -axo args= reads the same on procps and macOS (macOS pgrep has no -a for arguments).
    local all; all="$(ps -axo args= 2>/dev/null)" || return 1
    [ -n "$all" ] || return 1
    printf '%s\n' "$all" | awk -v want="${CLAUDE_PROC_NAME:-claude}" '{ n = $1; sub(/.*\//, "", n) } n == want' \
      | grep -Evc -- "$TURN_NOT_SESSION"
  fi
}
speaker_prefix() {
  local n self cwd pid proj
  n="${SOUND_LIVE_COUNT:-$(live_count)}" || return 0
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  [ "$n" -gt 1 ] || return 0
  self="$(cat "$HOME/.claude/hooks/claude-name.txt" 2>/dev/null | tr -d '\r\n')"
  if [ -z "$self" ]; then
    self="$(hostname -s 2>/dev/null || hostname 2>/dev/null)"; self="${self%%.*}"; [ -n "$self" ] || self=session
  fi
  cwd="${1:-}"
  if [ -z "$cwd" ] && ! is_windows && pid="$(claude_pid)"; then
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
  fi
  [ -n "$cwd" ] || cwd="$PWD"
  cwd="${cwd%/}"; cwd="${cwd%\\}"; proj="${cwd##*/}"; proj="${proj##*\\}"
  proj="$(printf '%s' "$proj" | tr '_.-' '   ' | sed 's/^[0-9 ]*//; s/  */ /g; s/ *$//')"
  printf '%s%s' "$self" "${proj:+, $proj}"
}

case "${1:-check}" in
  check) check; exit $? ;;
  acquire) turn_acquire "${2:-sound}"; exit $? ;;
  release) turn_release "${2:-}"; exit 0 ;;
  prefix)  speaker_prefix "${2:-}"; exit 0 ;;
  mute|unmute|solo|unsolo|sound|status) act "$1"; exit 0 ;;
  prompt)
    # UserPromptSubmit hook: answer the five commands here and stop the prompt,
    # so they cost no model turn. Anything else passes through untouched.
    payload="$(cat)"
    cmd="$(printf '%s' "$payload" | sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"[[:space:]]*\/\(mute\|unmute\|solo\|unsolo\|sound\)\([[:space:]][^"]*\)\{0,1\}".*/\1/p')"
    [ -z "$cmd" ] && exit 0
    msg="$(act "$cmd" 2>&1)"
    # JSON-escape the message for the block reason
    msg="$(printf '%s' "$msg" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk '{printf "%s\\n", $0}')"
    printf '{"decision":"block","reason":"%s"}\n' "$msg"
    exit 0 ;;
  *) echo "usage: sound-gate.sh check|mute|unmute|solo|unsolo|sound|prompt|acquire <label>|release <token>|prefix [cwd]" >&2; exit 2 ;;
esac
