#!/usr/bin/env bash
input=$(cat)

# Every field below is pulled out with jq, so on a host without it this script
# used to spit eight "jq: command not found" lines at stderr — and a status line
# is redrawn on virtually every turn, so that is not a one-off hint, it is a
# permanent error storm scrolling past the work. Detect it ONCE, here, and
# render nothing at all: an empty status line is the honest degradation, and
# exiting 0 keeps Claude Code from also reporting the command as failed. stdin
# is drained first (above) so the caller never gets a broken pipe out of this.
command -v jq >/dev/null 2>&1 || exit 0

cwd=$(echo "$input" | jq -r '.cwd // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
fast=$(echo "$input" | jq -r '.fast_mode // false')

# rate-limit usage windows
fh_pct=$(echo "$input"   | jq -r '.rate_limits.five_hour.used_percentage // empty')
fh_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
wk_pct=$(echo "$input"   | jq -r '.rate_limits.seven_day.used_percentage // empty')
wk_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

dir=$(basename "$cwd" 2>/dev/null)
branch=$(git --no-optional-locks -C "$cwd" branch --show-current 2>/dev/null)

# pick truecolor by usage threshold: green <50, yellow <80, red >=80
# The API sends these percentages fractional ("81.2"), and `[ ]` compares
# integers only — an unrounded value made the test error out and fall through
# to green, so the red warning never fired. Truncate to the integer part, and
# treat anything that is not a plain number as 0 rather than erroring.
pct_color() {
  local p="${1%%.*}"
  [ -n "$p" ] || p=0
  case "$p" in (*[!0-9]*) p=0 ;; esac
  if   [ "$p" -ge 80 ]; then printf '38;2;255;107;107'   # red
  elif [ "$p" -ge 50 ]; then printf '38;2;255;203;107'   # yellow
  else                       printf '38;2;143;227;165'   # green
  fi
}

out=""
[ -n "$dir" ]    && out="${out}\e[38;2;93;169;255m ${dir} \e[0m"
[ -n "$branch" ] && out="${out}\e[38;2;99;242;255m  ${branch} \e[0m"
[ -n "$model" ]  && out="${out}\e[38;2;179;136;255m  ${model} \e[0m"
# ↯ only while fast mode is ACTUALLY on - Claude Code drops out of it on its
# own cooldowns, so `"fastMode": true` in settings.json is intent, not live state.
[ "$fast" = "true" ] && out="${out}\e[38;2;255;203;107m↯ \e[0m"
[ -n "$used" ]   && out="${out}\e[38;2;143;188;187m  $(printf '%.0f' "$used")%\e[0m"

# GNU date spells "format this epoch" as -d @N; BSD date (macOS, where nothing
# installs coreutils by default) spells it -r N. Trying GNU first and falling
# back keeps one line of output correct on both instead of silently blank on
# one of them: every use here is inside $(... 2>/dev/null), so a wrong flag
# does not fail loudly, it just renders nothing.
epoch_fmt() {  # <epoch> <format>
  date -d "@$1" "$2" 2>/dev/null || date -r "$1" "$2" 2>/dev/null
}

if [ -n "$fh_pct" ]; then
  r=$(epoch_fmt "$fh_reset" +%H:%M)
  out="${out}\e[$(pct_color "$fh_pct")m  5h ${fh_pct}%$([ -n "$r" ] && printf ' →%s' "$r")\e[0m"
fi
if [ -n "$wk_pct" ]; then
  r=$(epoch_fmt "$wk_reset" '+%a')
  out="${out}\e[$(pct_color "$wk_pct")m  7d ${wk_pct}%$([ -n "$r" ] && printf ' →%s' "$r")\e[0m"
fi

echo -e "$out"
