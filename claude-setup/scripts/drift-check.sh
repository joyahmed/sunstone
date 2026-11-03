#!/usr/bin/env bash
# drift-check - one line per tracked item: is it a link or a copy on THIS box,
# (commands/supermode.md's line-count check went with supermode on 2026-09-29).
# Prints, does not repair - install-doctor.sh is
# the repair tool; this is the fast "did setup actually take" snapshot the
# measured-state table in a work order gets filled in from.
#
# WHY THIS EXISTS. LINK_HOOKS / LINK_COMMANDS / LINK_SKILLS in sunstone.conf
# turn setup's copies into symlinks so a `git pull` reaches the live file. They
# only take effect on the NEXT setup run per box, and nothing before this
# script said, on a box that hasn't re-run setup, that it was still on copies -
# a fleet of boxes can run a slash command several lines behind
# canonical for a stretch, silently, and nothing reports it until this does.
#
# ⛔ PORTABILITY IS THE POINT: this runs under Git Bash on Windows as well as
# bash on Linux and macOS. No GNU-only flags (no `find -printf`, no `stat
# --format`), no `readlink -f` (macOS's own readlink does not have it - same
# reason setup.sh, setup.ps1 and install-doctor.sh all use plain `readlink`
# throughout). grep -oE is the one non-POSIX-sh feature used, and it is in
# GNU grep, BSD grep (macOS) and Git Bash's grep alike.
#
#   bash claude-setup/scripts/drift-check.sh
#
# Exit 0: every LINK_*-enabled item is fully linked. Exit 1: anything above drifted - printed
#         with a leading "!". Meant to gate later; nothing here writes.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../.." && pwd)
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
case "$CFG" in "~"*) CFG="$HOME${CFG#\~}" ;; esac
SETTINGS="$CFG/settings.json"
GITHOOKS="$HOME/.git-hooks"

for a in "$@"; do
  case "$a" in
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
  esac
done

# The personal repo, resolved exactly as install-doctor.sh and the memory
# hooks resolve it: a path file, else the conventional location.
# norm_path <dir> - the shell's OWN spelling of a directory, so two paths that
# name the same place compare equal as strings.
#
# ⛔ WHY, and it is a measured false negative rather than tidiness.
# ~/.claude/ai-memory-path is written by setup.ps1 and holds the stored form -
# a WINDOWS path like "C:/path/to/repo". `readlink` under git-bash/MSYS prints
# the POSIX form instead - "/c/path/to/repo/...". in_sources()
# prefix-matches those as raw strings, so on Windows EVERY link into the
# personal repo failed the match while links into the framework root (whose
# $REPO came from `cd && pwd`, already POSIX) passed. Measured on one box with
# every tree correctly linked: commands 2/8, skills 0/45, hooks 21/30,
# ~/.git-hooks 3/8 - and the 2, 0, 21 and 3 were EXACTLY the framework root's
# share of each tree. drift-check exited 1 and told the user to re-run setup,
# which could never have changed the number. `cd && pwd` normalises both sides
# to whatever this shell calls the path, on any platform, with no cygpath.
norm_path() {
  [ -n "$1" ] || return 0
  ( CDPATH= cd -- "$1" 2>/dev/null && pwd ) || printf '%s\n' "$1"
}

MEM=""
if [ -r "$CFG/ai-memory-path" ]; then
  MEM=$(head -n1 "$CFG/ai-memory-path" | tr -d '\r' | xargs 2>/dev/null || true)
fi
[ -n "$MEM" ] && [ -d "$MEM/.git" ] || { [ -d "$HOME/.ai-memory/.git" ] && MEM="$HOME/.ai-memory"; }
[ -n "$MEM" ] && [ -d "$MEM" ] || MEM=""
[ -n "$MEM" ] && MEM=$(norm_path "$MEM")

# Byte-for-byte the value-reading half of conf_get() in setup.sh and
# ai-memory-sync.sh: the three must agree on what a key is set to, or this
# script could report "linked" as drift on a box where setup deliberately left
# it a copy. Source-free on purpose - sunstone.conf is user content, never
# executed.
conf_get() {  # <repo> <key> <default>
  local repo="$1" key="$2" default="$3" file val
  file="$repo/claude-setup/config/sunstone.conf"
  val=""
  if [ -n "$repo" ] && [ -f "$file" ]; then
    val="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null | tail -n1 \
           | sed -e "s/^[[:space:]]*${key}[[:space:]]*=//" -e 's/[[:space:]]*$//')"
    case "$(printf '%s' "$val" | sed 's/^[[:space:]]*//')" in
      \"*) val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*"//' -e 's/".*$//')" ;;
      *)   val="$(printf '%s' "$val" | sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" ;;
    esac
  fi
  if [ -n "$val" ]; then printf '%s\n' "$val"; else printf '%s\n' "$default"; fi
}
CONF_REPO="${MEM:-$REPO}"
LINK_HOOKS=$(conf_get "$CONF_REPO" LINK_HOOKS "")
LINK_COMMANDS=$(conf_get "$CONF_REPO" LINK_COMMANDS "")
LINK_SKILLS=$(conf_get "$CONF_REPO" LINK_SKILLS "")

drift=0
warns=0
note() { printf '  %s\n' "$1"; }
flag() { printf '  ! %s\n' "$1"; drift=$((drift + 1)); }
# warn - a "clean with warnings" tier, distinct from flag(): visible in the
# verdict, does NOT exit 1. For the one thing this script can see but cannot
# safely fail a box over - an untracked REAL entry sitting in a destination
# dir the repo also ships into (see dest_extras below). Failing the gate over
# a hand-written skill someone left in ~/.claude/skills would be worse than
# the drift it might be hiding, so this is the middle box, not red.
warn() { printf '  ~ %s\n' "$1"; warns=$((warns + 1)); }

# in_sources <target> - true when a symlink's target resolves under the
# framework root or the personal repo, i.e. it tracks a repo rather than
# pointing at some unrelated path.
in_sources() {
  # The target is normalised the same way $REPO and $MEM are (see norm_path):
  # a link whose target is spelled "C:/..." must still match a root this shell
  # calls "/c/...". Only its DIRECTORY can be cd'd into, so normalise that and
  # re-attach the basename.
  local t="$1" dir base
  [ -n "$t" ] || return 1
  dir=$(dirname "$t"); base=$(basename "$t")
  dir=$(norm_path "$dir")
  t="${dir%/}/$base"
  case "$t" in
    "$REPO"/*) return 0 ;;
  esac
  [ -n "$MEM" ] && case "$t" in "$MEM"/*) return 0 ;; esac
  return 1
}

# shipped_ratio <dest-dir> <src-rel> <glob> <test> - walks what the FRAMEWORK
# and PERSONAL roots actually ship at <src-rel><glob> (e.g.
# "claude-setup/config/hooks" "/*"), not what happens to sit in <dest-dir>. A
# destination-first scan over-counts: ~/.claude/hooks and ~/.claude/skills
# both accumulate names neither repo ships (a hand-written skill, a stray
# .txt, a .bak.<stamp> from install_link, an old .pre-selfheal/.broken-<date>
# copy from before a repair) and none of those are anything `git pull` could
# ever have kept current, so counting them as "should be a link" is noise
# that would flag drift on a box with nothing wrong. <test> is "-f" for files
# (commands, hooks, git-hooks) or "-d" for skill directories. Prints
# "<linked>/<total>|<seen>", deduplicated by basename across the two roots
# (the personal one's name wins for path resolution, but either counts once).
# <seen> (space-padded, e.g. " a b c") is the tracked-basename list itself -
# report_ratio passes it straight to dest_extras so THAT scan (destination-
# first, on purpose - see dest_extras) knows what NOT to call an extra.
shipped_ratio() {
  local dest="$1" src_rel="$2" glob="$3" test_flag="$4" total=0 linked=0 seen="" r f name d t
  for r in "$REPO" "$MEM"; do
    [ -n "$r" ] && [ -d "$r/$src_rel" ] || continue
    for f in "$r/$src_rel"$glob; do
      [ "$test_flag" = "-f" ] && { [ -f "$f" ] || continue; }
      [ "$test_flag" = "-d" ] && { [ -d "$f" ] || continue; }
      name=$(basename "$f")
      case " $seen " in *" $name "*) continue ;; esac
      seen="$seen $name"
      total=$((total + 1))
      d="$dest/$name"
      if [ -L "$d" ]; then
        t=$(readlink "$d" 2>/dev/null) || t=""
        # -ef as the fallback: on Windows one folder can have two names (a
        # junction, e.g. C:\Users\<name>\projects -> G:\), and a link spelled
        # with the other name is the same file, not drift.
        if in_sources "$t" || [ "$d" -ef "$f" ]; then linked=$((linked + 1)); fi
      fi
    done
  done
  printf '%s/%s|%s' "$linked" "$total" "$seen"
}

# benign_for_category <label> - untracked REAL entries known to belong to
# some OTHER tool, or to sunstone itself via a side channel, for the ONE
# category named - so an entry benign in skills doesn't blind the check to
# the same name showing up, unexplained, in hooks. Space-padded so callers
# can `case " $(benign_for_category "$1") " in *" $name "*)`. One line per
# addition, and say who WRITES it and who READS it - the two hooks entries
# below are load-bearing for sunstone's own bin/supermode and
# session-bus-notice.js, and a future cleanup must not delete them.
benign_for_category() {
  case "$1" in
    skills)
      # `synced` - Claude Code's own cloud skill-sync directory, observed at
      # ~/.claude/skills/synced holding a `.bucket-<uuid>_<uuid>` marker and a
      # uuid-named subdirectory - never a sunstone skill.
      printf ' synced ' ;;
    hooks)
      # `claude-name.txt` - per-box identity. WRITTEN by the memory repo's
      # claude-setup/scripts/set-claude-name.sh, READ by sunstone's own
      # session-bus-notice.js and bin/supermode(.ps1).
      # `chime-name.txt` - per-box voice config, referenced by
      # the memory repo's claude-setup/scripts/voice-bake.sh.
      printf ' claude-name.txt chime-name.txt ' ;;
    *)
      printf ' ' ;;
  esac
}
is_benign_extra() {  # <name> <label>
  case "$1" in
    .*) return 0 ;;
  esac
  case "$(benign_for_category "$2")" in *" $1 "*) return 0 ;; esac
  return 1
}

# is_stale_backup <name> - claude-setup/install.sh's backup() names its
# copies "<file>.bak.<digits>" or "<file>.bak.<YYYYMMDD>_<HHMMSS>" (and the
# dash form "<file>.bak.<YYYYMMDD>-<HHMMSS>") and is known to leave them
# behind - a filed, open issue, not a mystery to chase box by box. Named as
# its own class so the verdict says "stale backup", not "untracked real
# file", when that is what it is.
is_stale_backup() {
  local suffix
  case "$1" in
    *.bak.*) ;;
    *) return 1 ;;
  esac
  suffix="${1##*.bak.}"
  case "$suffix" in
    ''|*[!0-9_-]*) return 1 ;;
  esac
  return 0
}

# csv_count <csv> - number of comma-separated names, 0 for an empty string.
csv_count() {
  [ -n "$1" ] || { printf '0'; return; }
  printf '%s' "$1" | awk -F',' '{print NF}'
}

# plural <count> <word> - "word" for 1, "words" otherwise. English-only and
# that is fine - every word this is called with ("dir", "file", "symlink") is
# ours to spell.
plural() {
  if [ "$1" = "1" ]; then printf '%s' "$2"; else printf '%ss' "$2"; fi
}

# dest_extras <dest-dir> <test-flag> <glob> <seen> <label> - the
# destination-FIRST scan shipped_ratio's own comment warns against, done
# anyway, because this is precisely the check that was missing: shipped_ratio
# can only ever see what the repo ships, so a real, untracked directory
# sitting in the same destination - docker-development in ~/.claude/skills,
# never symlinked, never reported - was invisible to a "45/45 linked"
# verdict. <glob> narrows matching to the same name pattern shipped_ratio
# used ("*.md" for commands, "*" for everything else), so a stray
# "notes.txt" among *.md commands isn't called an extra either. Prints
# "<present>|<known-csv>|<real-csv>|<sym-csv>|<backup-csv>".
dest_extras() {
  local dest="$1" test_flag="$2" glob="$3" seen="$4" label="$5"
  local pat present=0 known="" real="" sym="" bak="" e name
  pat="${glob#/}"
  [ -d "$dest" ] || { printf '0||||'; return; }
  for e in "$dest"/* "$dest"/.[!.]* "$dest"/..?*; do
    if [ "$test_flag" = "-f" ]; then
      [ -f "$e" ] || [ -L "$e" ] || continue
    else
      [ -d "$e" ] || [ -L "$e" ] || continue
    fi
    name=$(basename "$e")
    case "$name" in $pat) ;; *) continue ;; esac
    present=$((present + 1))
    case " $seen " in *" $name "*) continue ;; esac
    if is_benign_extra "$name" "$label"; then
      known="${known:+$known,}$name"
    elif is_stale_backup "$name"; then
      bak="${bak:+$bak,}$name"
    elif [ -L "$e" ]; then
      sym="${sym:+$sym,}$name"
    else
      real="${real:+$real,}$name"
    fi
  done
  printf '%s|%s|%s|%s|%s' "$present" "$known" "$real" "$sym" "$bak"
}

echo "drift-check: $CFG"
[ -n "$MEM" ] && echo "  personal repo: $MEM" || echo "  personal repo: none resolved (framework-only)"
echo ""

# --- settings.json: a MERGE PRODUCT, never linkable. Determined by reading
# setup.sh/setup.ps1: step_settings/Install-Settings run merge-settings-
# template.{py,mjs} to fold claude-setup/config/settings.json (framework, then
# personal) INTO the installed file - appending a hook only when no entry
# under that event already runs the same script by basename. So "stale" here
# cannot mean "differs from the template" (a hand-approved permission or an
# extra hook would always differ); it means a hook script the template(s) ship
# is not referenced ANYWHERE in the installed file - the thing a merge that
# never re-ran would miss. Coarse (basename text search, not the merger's own
# JSON-aware matcher) and stated as such, same bias install-doctor.sh takes for
# its own coarse checks: a wrong "stale" here is loud and nothing was deleted,
# so coarse-but-honest is the right side to err on. A launcher
# (run-node.sh) is excluded - it is not the hook it starts, and counting it
# would make one node hook's launcher line look like every node hook.
if [ -f "$SETTINGS" ]; then
  missing=""
  for tpl in "$REPO/claude-setup/config/settings.json" "${MEM:+$MEM/claude-setup/config/settings.json}"; do
    [ -n "${tpl:-}" ] && [ -f "$tpl" ] || continue
    # Three things a naive scan gets wrong, each closed below:
    #  · "type": "command" is not a command LINE - matching bare `"command"`
    #    (no colon) would eat the flag meant to skip statusLine's own line.
    #  · statusLine follows a DIFFERENT merge rule (copied once, only if
    #    absent - never "append if this basename is missing"), so its script
    #    is excluded here rather than judged as a hook the merge left behind.
    #  · a JSON path like "graphify-out/graph.json" false-matches as
    #    "graph.js" (.json contains .js as a substring) without a boundary
    #    check after the extension.
    for base in $(awk '/"statusLine"/ { in_sl=1 } /"command":/ { if (in_sl) { in_sl=0; next } print }' "$tpl" 2>/dev/null \
                  | grep -oE '[A-Za-z0-9_./~:-]+\.(sh|mjs|js|py)([^A-Za-z0-9]|$)' \
                  | sed -e 's/[^A-Za-z0-9]$//' -e 's#.*/##' | sort -u); do
      [ "$base" = "run-node.sh" ] && continue
      grep -qF "$base" "$SETTINGS" 2>/dev/null || missing="${missing:+$missing, }$base"
    done
  done
  if [ -n "$missing" ]; then
    flag "settings.json: merge product, STALE - template hook(s) not found in the installed file: $missing"
  else
    note "settings.json: merge product, up to date (every template hook script is referenced)"
  fi
else
  flag "settings.json: NOT INSTALLED at $SETTINGS"
fi

# --- commands, skills, hooks, ~/.git-hooks: link-or-copy ratio, scoped to what
# the roots actually ship (shipped_ratio, above). Flagged as drift only when
# the matching LINK_* key asked for links and this box is not fully there yet
# - a box that never set the key is correctly on copies by design
# (install_copy_safe / Install-FileSafe already keep those refreshed).
report_ratio() {  # <label> <dest-dir> <src-rel> <glob> <test> <link-key>
  local label="$1" dest="$2" src_rel="$3" glob="$4" test_flag="$5" key="$6"
  local shipped linked total seen wanted extras present known real sym bak
  local noun n_real n_sym n_bak detail extra_clause msg
  shipped=$(shipped_ratio "$dest" "$src_rel" "$glob" "$test_flag")
  linked=${shipped%%/*}; shipped=${shipped#*/}
  total=${shipped%%|*}; seen=${shipped#*|}
  wanted="off"
  case "$key" in 1) wanted="on" ;; esac
  if [ "$total" = "0" ]; then
    note "$label: nothing shipped under $src_rel$glob in $REPO or the personal repo"
    return
  fi
  if [ "$key" = "1" ] && [ "$linked" != "$total" ]; then
    flag "$label: $linked/$total linked at $dest - LINK_* is set but this box is still on copies (re-run setup)"
    return
  fi

  # Everything below is the destination-first pass: what's AT $dest that the
  # repo(s) never shipped there. Reported alongside the existing verdict, not
  # in place of it - a box can be fully linked (the check above, clean) and
  # still be hiding an untracked real directory (this one).
  extras=$(dest_extras "$dest" "$test_flag" "$glob" "$seen" "$label")
  present=${extras%%|*}; extras=${extras#*|}
  known=${extras%%|*}; extras=${extras#*|}
  real=${extras%%|*}; extras=${extras#*|}
  sym=${extras%%|*}; bak=${extras#*|}
  noun="file"; [ "$test_flag" = "-d" ] && noun="dir"

  extra_clause=""
  if [ -n "$real" ] || [ -n "$bak" ] || [ -n "$sym" ]; then
    n_real=$(csv_count "$real"); n_sym=$(csv_count "$sym"); n_bak=$(csv_count "$bak")
    detail=""
    [ -n "$real" ] && detail="$n_real real $(plural "$n_real" "$noun"): $real"
    [ -n "$bak" ] && detail="${detail:+$detail, }$n_bak stale $(plural "$n_bak" backup): $bak"
    [ -n "$sym" ] && detail="${detail:+$detail, }$n_sym $(plural "$n_sym" symlink): $sym"
    extra_clause=", $present present, $((n_real + n_bak + n_sym)) untracked ($detail)"
  elif [ -n "$known" ]; then
    extra_clause=", $present present (known, not sunstone's: $known)"
  fi

  msg="$label: $linked/$total linked at $dest (LINK_*=$wanted)$extra_clause"
  if [ -n "$real" ] || [ -n "$bak" ]; then
    warn "$msg"
  else
    note "$msg"
  fi
}
report_ratio "commands"     "$CFG/commands"  "claude-setup/commands"             "/*.md" -f "$LINK_COMMANDS"
report_ratio "skills"       "$CFG/skills"     "skills"                           "/*"    -d "$LINK_SKILLS"
report_ratio "hooks"        "$CFG/hooks"      "claude-setup/config/hooks"        "/*"    -f "$LINK_HOOKS"
report_ratio "~/.git-hooks" "$GITHOOKS"       "claude-setup/config/git-hooks"    "/*"    -f "$LINK_HOOKS"

echo ""
if [ "$drift" -gt 0 ]; then
  echo "drift-check: $drift item(s) flagged"
  exit 1
fi
if [ "$warns" -gt 0 ]; then
  echo "drift-check: clean, $warns warning(s)"
  exit 0
fi
echo "drift-check: clean"
exit 0
