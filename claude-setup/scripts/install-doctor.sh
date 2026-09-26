#!/usr/bin/env bash
# install-doctor - prove this machine is actually set up, rather than assuming it.
#
# WHY THIS EXISTS. Every install failure worth the name looks like success:
#   · a push that ADDS a hook reaches no machine that is already installed,
#     because setup links hooks and nothing re-links them;
#   · a settings key added to an overlay never reaches a live settings.json;
#   · a hook entry pointing at a deleted script fails silently, every call;
#   · a guard whose machine-local list is missing protects nothing, while
#     everyone believes it is on;
#   · a status line that cannot find an interpreter prints nothing at all;
#   · a shell that resolves `node` only from an INTERACTIVE rc has no node in
#     any hook, cron job, git hook or task runner - on a machine where node
#     plainly exists.
# Each of those was found by a person noticing, days later, never by tooling.
# `setup.sh` exiting 0 means the script ran; it has never meant the machine is
# correct. This says which.
#
#   bash install-doctor.sh            report; exit 1 if anything is broken
#   bash install-doctor.sh --fix      also repair what is safe to repair
#   bash install-doctor.sh --quiet    print only problems (for session hooks)
#
# ⚠️ PUBLIC FILE: it must name no person, no repository, no host and no path
# outside $HOME. Every check derives what it needs at run time.
set -u

FIX=0; QUIET=0
for a in "$@"; do
  case "$a" in
    --fix) FIX=1 ;;
    --quiet|-q) QUIET=1 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
  esac
done

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../.." && pwd)
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
case "$CFG" in "~"*) CFG="$HOME${CFG#\~}";; esac

# The personal repo, resolved exactly as the memory hooks resolve it - a path
# file, else a conventional location. No environment variable to remember, so a
# session hook and a person at a prompt get the same answer.
MEM=""
if [ -r "$CFG/ai-memory-path" ]; then
  MEM=$(head -n1 "$CFG/ai-memory-path" | tr -d '\r' | xargs 2>/dev/null)
fi
[ -n "$MEM" ] && [ -d "$MEM/.git" ] || { [ -d "$HOME/.ai-memory/.git" ] && MEM="$HOME/.ai-memory"; }
MEMORY_REPO_HOOKS="${MEMORY_REPO_HOOKS:-${MEM:+$MEM/claude-setup/config/hooks}}"
MEMORY_REPO_MIGRATIONS="${MEMORY_REPO_MIGRATIONS:-${MEM:+$MEM/claude-setup/migrations}}"

settings_path="$CFG/settings.json"
problems=0; warnings=0
ok()   { [ "$QUIET" = "1" ] || printf '  ✔ %s\n' "$1"; }
warn() { printf '  ⚠ %s\n' "$1"; warnings=$((warnings+1)); }
bad()  { printf '  ⛔ %s\n' "$1"; problems=$((problems+1)); }

[ "$QUIET" = "1" ] || echo "install-doctor: $CFG"

# --- 1. every hook the framework ships is installed ---------------------------
# The failure this catches: a release ADDS a hook, every machine pulls it, and
# no installed machine ever links it. Silent by construction.
missing_hooks=""
for dir in "$REPO/claude-setup/config/hooks" "$MEMORY_REPO_HOOKS"; do
  [ -n "${dir:-}" ] && [ -d "$dir" ] || continue
  for src in "$dir"/*; do
    [ -f "$src" ] || continue
    name=$(basename "$src")
    case "$name" in *.bak|*.bak.*|*.md|*.ps1) continue;; esac
    [ -e "$CFG/hooks/$name" ] || missing_hooks="$missing_hooks $name"
  done
done
if [ -n "$missing_hooks" ]; then
  if [ "$FIX" = "1" ]; then
    for name in $missing_hooks; do
      for dir in "$REPO/claude-setup/config/hooks" "${MEMORY_REPO_HOOKS:-}"; do
        [ -n "$dir" ] && [ -f "$dir/$name" ] && ln -sfn "$dir/$name" "$CFG/hooks/$name" && echo "  → linked $name"
      done
    done
    ok "hooks: linked what was missing (restart to load them)"
    [ "$QUIET" = "1" ] || echo "    note: linking a file does not register it - the next check says whether it will actually run"
  else
    bad "hooks not installed:$missing_hooks   (re-run setup, or this script with --fix)"
  fi
else
  ok "hooks: every shipped hook is installed"
fi

# --- 1b. a hook that SHIPPED but was never REGISTERED -------------------------
# ⛔ The trap that makes check 1 dangerous on its own: linking a hook file does
# not run it. A hook runs because the live settings.json NAMES it, and the
# settings merge happens only in setup - so a release can ship a hook, a machine
# can link it, the ⛔ above turns green, and the hook never fires once. `--fix`
# would have manufactured exactly that false green. Found by a peer running this
# on a machine where both new hooks were shipped, unlinked AND unregistered.
#
# So compare the SHIPPED settings' hook commands against the LIVE ones, rather
# than files against a directory.
if command -v python3 >/dev/null 2>&1 && [ -f "$settings_path" ]; then
  unregistered=$(python3 - "$settings_path" "$REPO/claude-setup/config/settings.json" "${MEM:+$MEM/claude-setup/config/settings.json}" <<'DOCTOR_PY' 2>/dev/null
import json,sys,re
def refs(path):
    out=set()
    if not path: return out
    try: d=json.load(open(path,encoding="utf-8"))
    except Exception: return out
    def walk(o):
        if isinstance(o,dict):
            c=o.get("command")
            if isinstance(c,str):
                for m in re.findall(r'hooks[/\\]([A-Za-z0-9._-]+)', c):
                    out.add(m)
            for v in o.values(): walk(v)
        elif isinstance(o,list):
            for v in o: walk(v)
    walk(d.get("hooks",{}))
    return out
live = refs(sys.argv[1])
shipped = set()
for p in sys.argv[2:]:
    shipped |= refs(p)
for n in sorted(shipped - live):
    print(n)
DOCTOR_PY
)
  if [ -n "$unregistered" ]; then
    for n in $unregistered; do
      bad "$n ships in the framework settings but is NOT registered in this machine's settings.json - linking the file does not make it run; only setup's settings merge does"
    done
  else
    ok "settings: every shipped hook is registered here"
  fi
fi

# --- 2. no settings entry points at a script that is not there ----------------
# A hook command naming a missing file fails on EVERY tool call, and the only
# symptom is that the thing it did stops happening.
if [ -f "$settings_path" ]; then
  if command -v python3 >/dev/null 2>&1; then
    dangling=$(python3 - "$settings_path" "$CFG" <<'PY' 2>/dev/null
import json,sys,os,re
p,cfg=sys.argv[1],sys.argv[2]
try: d=json.load(open(p,encoding="utf-8"))
except Exception as e: print("PARSE:%s"%e); raise SystemExit
out=[]
def walk(o):
    if isinstance(o,dict):
        c=o.get("command")
        if isinstance(c,str):
            for m in re.findall(r'(?:~|\$HOME)/[\w./-]+', c):
                f=m.replace("~",os.path.expanduser("~")).replace("$HOME",os.path.expanduser("~"))
                if not os.path.exists(f): out.append(f)
        for v in o.values(): walk(v)
    elif isinstance(o,list):
        for v in o: walk(v)
walk(d.get("hooks",{}))
sl=d.get("statusLine",{})
if isinstance(sl,dict): walk({"command":sl.get("command","")})
for f in dict.fromkeys(out): print(f)
PY
)
    case "$dangling" in
      PARSE:*) bad "settings.json does not parse: ${dangling#PARSE:}" ;;
      "")      ok "settings: every hook and status-line command exists on disk" ;;
      *)       for f in $dangling; do bad "settings names a file that is not there: ${f#$HOME/}"; done ;;
    esac
  else
    warn "settings: no python3, cannot check for dangling hook commands"
  fi
else
  warn "settings: $settings_path does not exist"
fi

# --- 3. an interpreter that a NON-INTERACTIVE shell can find ------------------
# Under a lazy version manager, `node` is a shell FUNCTION defined in an
# interactive rc and its bin is never exported - so hooks, git hooks, cron,
# systemd, ssh and status lines have no node on a machine that plainly has one.
# ⚠️ "not on PATH" and "not installed" are different answers and only one is
# actionable. Look where interpreters actually live before saying it is absent -
# the first version reported "not found at all" on a machine with three versions
# installed, the same overconfident shape this exists to catch.
#
# ⛔ AND IT MUST NAME THE SHELL IT ASKED. On a Windows box this runs under Git
# Bash, where node is on PATH and always was - while the shell that actually
# breaks is the Linux userland's, with the lazy version-manager stubs. The first
# version answered about Git Bash and printed a green "resolvable from a
# non-interactive shell": true, about the wrong shell, which is worse than a red
# because nobody re-checks a green. A peer caught it on the one machine where
# the distinction exists. A check that names its scope cannot be misread later.
host_desc=$(uname -s 2>/dev/null | cut -c1-12 || echo shell)
node_anywhere=""
command -v node >/dev/null 2>&1 && node_anywhere=$(command -v node)
if [ -z "$node_anywhere" ]; then
  for cand in "${NVM_BIN:-}/node" /usr/local/bin/node /usr/bin/node /opt/homebrew/bin/node \
              "${NVM_DIR:-$HOME/.nvm}"/versions/node/*/bin/node; do
    [ -x "$cand" ] && { node_anywhere="$cand"; break; }
  done
fi
if [ -z "$node_anywhere" ]; then
  warn "node [$host_desc]: not installed anywhere this can see - hooks written in node cannot run"
elif sh -c 'command -v node >/dev/null 2>&1'; then
  ok "node [$host_desc]: resolvable from a non-interactive shell"
else
  warn "node [$host_desc]: installed (${node_anywhere#$HOME/}) but INVISIBLE to a non-interactive shell - hooks, git hooks, cron and status lines will not find it. Put its bin on PATH from a non-interactive rc; a lazy version manager's shell function is not enough."
fi
# The other side of a two-shell machine. A Windows box runs the hooks under Git
# Bash AND holds a Linux userland whose non-interactive shell is where the trap
# actually lives; answering only for the host is how the green above came to be
# written about the wrong shell.
if command -v wsl.exe >/dev/null 2>&1; then
  if wsl.exe -e bash -lc 'command -v node >/dev/null 2>&1' >/dev/null 2>&1; then
    ok "node [wsl]: resolvable from a non-interactive shell there too"
  else
    warn "node [wsl]: NOT resolvable from a non-interactive \`wsl -e bash -lc\` - anything run inside the Linux userland (builds, hooks, cron, a terminal seam) has no node, whatever the host side reports"
  fi
fi

# --- 4. the git guards are actually wired ------------------------------------
hp=$(git config --global core.hooksPath 2>/dev/null || true)
if [ -z "$hp" ]; then
  warn "git: no global core.hooksPath - the commit guards cover no repo"
else
  hp_exp=$(printf '%s' "$hp" | sed "s#^~#$HOME#")
  miss=""
  for h in commit-msg pre-commit; do
    [ -e "$hp_exp/$h" ] || miss="$miss $h"
  done
  [ -z "$miss" ] && ok "git: guards wired at ${hp_exp#$HOME/}" || bad "git: core.hooksPath set but missing:$miss"
fi

# --- 5. machine-local files a shared config cannot provide --------------------
# These are per-machine BY DESIGN, which is exactly why they are forgotten: a
# git pull can never deliver them and nothing fails when they are absent.
conf=""
for c in "${MEM:+$MEM/claude-setup/config/sunstone.conf}" "$REPO/claude-setup/config/sunstone.conf"; do
  [ -n "$c" ] && [ -f "$c" ] && { conf="$c"; break; }
done
busdir=""
[ -n "$conf" ] && busdir=$(grep -E '^[[:space:]]*BUS_DIR=' "$conf" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' | xargs 2>/dev/null)
if [ -n "${busdir:-}" ]; then
  if [ -f "$CFG/bus-side" ]; then
    ok "bus: this machine has its own side name"
  else
    warn "bus: no $CFG/bus-side - the side is guessed from the OS, so two machines sharing an OS write into one file and each skips it as its own"
  fi
fi
if [ -e "$CFG/hooks/public-privacy-guard.sh" ] || [ -e "$(git config --global core.hooksPath 2>/dev/null | sed "s#^~#$HOME#")/public-privacy-guard.sh" ] 2>/dev/null; then
  [ -f "$CFG/public-repos" ] && ok "privacy guard: this machine's public-repo list exists" \
    || warn "privacy guard: no $CFG/public-repos - it guards only the framework repo here, silently"
fi

# --- 6. an installed hook that cannot be executed -----------------------------
# A script committed 100644 - written on a filesystem with no execute bit, or
# copied with `cp`, which preserves mode - dies with "Permission denied", exit
# 126, at the FIRST hop of any chain that calls it by path. A whole shell
# install was unreachable that way, and the failure names permissions rather
# than the missing bit, so it reads like a sudo problem.
noexec=""
for f in "$CFG"/hooks/*; do
  [ -f "$f" ] || continue
  # ⚠️ Skip what is never executed BY PATH, or the check becomes noise - and a
  # doctor that cries wolf is one people learn to scroll past, which costs more
  # than the check is worth. A .ps1 is run by a PowerShell host, never by its
  # mode bit; a dated backup is not a hook; .md/.txt are not scripts. The first
  # version flagged three of these on a Linux box, where a PowerShell script's
  # execute bit means precisely nothing.
  case "$(basename "$f")" in *.bak*|*.md|*.txt|*.ps1|*.psm1) continue;; esac
  [ -x "$f" ] || noexec="$noexec $(basename "$f")"
done
if [ -n "$noexec" ]; then
  warn "hooks present but NOT executable:$noexec - fine while something calls them as \`bash <file>\`, exit 126 the moment anything calls them by path"
else
  ok "hooks: all executable"
fi

# --- 7. migrations that have not run -----------------------------------------
migs="${MEMORY_REPO_MIGRATIONS:-}"
if [ -n "$migs" ] && [ -d "$migs" ]; then
  pending=""
  for m in "$migs"/*.sh; do
    [ -f "$m" ] || continue
    n=$(basename "$m" .sh)
    [ -f "$CFG/ej-migrations/$n" ] || pending="$pending $n"
  done
  [ -z "$pending" ] && ok "migrations: all applied" || warn "migrations pending:$pending"
fi

# --- 8. an installed command or skill that the repo has since MOVED PAST ------
# ⛔ THE FAILURE THIS EXISTS FOR, and it is the same class as check 1 wearing a
# different hat. Hooks can be symlinked (LINK_HOOKS), so a fix pushed to the repo
# reaches every machine on `git pull`. Commands and skills are COPIED by setup -
# and nothing ever re-copies them, and until this check, nothing said they were
# behind. Counted on one machine: three of six installed commands were strict
# subsets of their repo copy with ZERO lines of their own, i.e. never refreshed
# since the missing sections landed; one of the missing sections was the rule that
# keeps an unattended run from failing its own commit on every slice. A skill hit
# the same wall the same week. Every symptom was a person noticing, days later.
#
# ⚠️ STALE AND DIVERGED ARE DIFFERENT ANSWERS AND ONLY ONE IS SAFE TO FIX.
#   stale    - every line of the installed file also appears in the repo copy,
#              and the repo copy has lines the installed one lacks. That is a
#              copy nobody touched, only failed to refresh. --fix refreshes it.
#   diverged - the installed file has at least one line of its own. That may be
#              somebody's deliberate local edit, so it is REPORTED AND LEFT. No
#              --fix, no backup-and-replace: named, and the person decides.
# Reported as ⚠ rather than ⛔ on purpose: nothing is broken right now, the file
# is merely behind, and that is exactly the definition of the silent class this
# script prints warnings for.
#
# subset_of <installed> <repo> - the predicate above. It is the same one as
# is_stale_subset() in setup.sh and the two must agree: that one CONVERTS what
# this one REPORTS. awk, not python3, so a machine without python3 still gets the
# answer instead of a skipped check.
subset_of() {
  [ -f "$1" ] && [ -f "$2" ] || return 1
  # A zero-length repo file would make awk's FNR==NR true for the second file's
  # first record too, comparing the installed file against itself.
  [ -s "$2" ] || return 1
  awk '
    FNR==NR { repo[$0]=1; next }
    { inst[$0]=1; if (!($0 in repo)) extra++ }
    END {
      for (l in repo) if (!(l in inst)) missing++
      exit (extra+0 == 0 && missing+0 > 0) ? 0 : 1
    }
  ' "$2" "$1"
}

# file_state <installed> <repo> -> link | same | stale | diverged | absent
file_state() {
  if [ -L "$1" ]; then
    # A symlink INTO the repo tracks it by construction; one pointing anywhere
    # else is judged on its content like any other file.
    t=$(readlink "$1" 2>/dev/null)
    [ "$t" = "$2" ] && { echo link; return; }
  fi
  [ -e "$1" ] || { echo absent; return; }
  cmp -s "$1" "$2" && { echo same; return; }
  subset_of "$1" "$2" && { echo stale; return; }
  echo diverged
}

# tree_state <installed-dir> <repo-dir> -> link | same | stale | diverged | absent
# A tree is only "stale" when it holds no file of its own AND every file that
# differs is a stale subset. One installed-only file makes the whole tree
# diverged: a skill is replaced whole, so that file is what would be destroyed.
tree_state() {
  if [ -L "$1" ]; then
    t=$(readlink "$1" 2>/dev/null)
    [ "$t" = "$2" ] && { echo link; return; }
  fi
  [ -d "$1" ] || { echo absent; return; }
  _any_diff=0
  for f in $(find "$1" -type f 2>/dev/null); do
    _rel=${f#"$1"/}
    [ -f "$2/$_rel" ] || { echo diverged; return; }
    cmp -s "$f" "$2/$_rel" && continue
    _any_diff=1
    subset_of "$f" "$2/$_rel" || { echo diverged; return; }
  done
  # A file the repo added and this tree never received is staleness too, and the
  # loop above cannot see it - it only walks what is installed.
  for f in $(find "$2" -type f 2>/dev/null); do
    _rel=${f#"$2"/}
    [ -f "$1/$_rel" ] || _any_diff=1
  done
  [ "$_any_diff" = "1" ] && echo stale || echo same
}

# Which root a given name comes from: setup applies the framework root first and
# the personal overlay LAST, and the last root wins - so resolve against the
# personal root when it ships the same name.
src_for() {  # <rel-path> -> absolute source path, or empty
  for _r in "${MEM:-}" "$REPO"; do
    [ -n "$_r" ] && [ -e "$_r/$1" ] && { printf '%s\n' "$_r/$1"; return; }
  done
}

stale_list=""; diverged_list=""; absent_list=""; tracked=0
# commands: one .md per slash command
for root in "$REPO" "${MEM:-}"; do
  [ -n "$root" ] && [ -d "$root/claude-setup/commands" ] || continue
  for src in "$root"/claude-setup/commands/*.md; do
    [ -f "$src" ] || continue
    name=$(basename "$src")
    real=$(src_for "claude-setup/commands/$name"); [ -n "$real" ] || continue
    [ "$real" = "$src" ] || continue     # a later root ships it; judged there
    tracked=$((tracked+1))
    case "$(file_state "$CFG/commands/$name" "$real")" in
      stale)    stale_list="$stale_list commands/$name" ;;
      diverged) diverged_list="$diverged_list commands/$name" ;;
      absent)   absent_list="$absent_list commands/$name" ;;
    esac
  done
done
# skills: one directory per skill
for root in "$REPO" "${MEM:-}"; do
  [ -n "$root" ] && [ -d "$root/skills" ] || continue
  for src in "$root"/skills/*/; do
    [ -d "$src" ] || continue
    name=$(basename "$src")
    real=$(src_for "skills/$name"); [ -n "$real" ] || continue
    [ "$real" = "${src%/}" ] || continue
    tracked=$((tracked+1))
    case "$(tree_state "$CFG/skills/$name" "$real")" in
      stale)    stale_list="$stale_list skills/$name" ;;
      diverged) diverged_list="$diverged_list skills/$name" ;;
      absent)   absent_list="$absent_list skills/$name" ;;
    esac
  done
done

if [ "$tracked" = "0" ]; then
  warn "commands/skills: nothing shipped to compare - this check did NOT run"
else
  if [ -n "$stale_list" ]; then
    if [ "$FIX" = "1" ]; then
      for item in $stale_list; do
        kind=${item%%/*}; name=${item#*/}
        if [ "$kind" = "commands" ]; then
          real=$(src_for "claude-setup/commands/$name")
          mkdir -p "$CFG/commands" && cp "$real" "$CFG/commands/$name" && echo "  → refreshed commands/$name"
        else
          real=$(src_for "skills/$name")
          # Safe to replace whole: "stale" proved this tree holds no file the
          # repo does not also ship, so nothing here is anybody's but ours.
          rm -rf "${CFG:?}/skills/$name" && cp -r "$real" "$CFG/skills/$name" && echo "  → refreshed skills/$name"
        fi
      done
      ok "commands/skills: refreshed what was only out of date"
    else
      warn "STALE - installed but never refreshed since the repo moved on:$stale_list   (this script with --fix refreshes them; LINK_COMMANDS=1 / LINK_SKILLS=1 in sunstone.conf stops it happening again)"
    fi
  fi
  [ -n "$diverged_list" ] && warn "DIVERGED - edited here, so NOT touched and not refreshable:$diverged_list   (diff each against the repo; keep the local change or delete the file and re-run setup)"
  [ -n "$absent_list" ] && warn "commands/skills shipped but never installed:$absent_list   (re-run setup)"
  [ -z "$stale_list$diverged_list$absent_list" ] && ok "commands/skills: all $tracked match the repo (or are symlinks to it)"
fi

# The two sibling skill stores setup also writes. They belong to tools that are
# not in this workflow, so their staleness is stated ONCE and never itemised:
# a doctor that itemises what nobody uses is a doctor people learn to scroll past.
for other in "$HOME/.codex/skills" "$HOME/.config/opencode/skills"; do
  [ -d "$other" ] || continue
  odiff=0
  # ⚠️ Two roots, iterated separately. "${MEM:+$MEM/skills/}"*/ collapses to a
  # bare */ when there is no personal repo - which globs the CURRENT DIRECTORY
  # and compares whatever happens to be there.
  for sroot in "$REPO/skills" "${MEM:+$MEM/skills}"; do
    [ -n "$sroot" ] && [ -d "$sroot" ] || continue
    for src in "$sroot"/*/; do
      [ -d "$src" ] || continue
      name=$(basename "$src")
      [ -e "$other/$name" ] || continue
      diff -rq "${src%/}" "$other/$name" >/dev/null 2>&1 || odiff=$((odiff+1))
    done
  done
  [ "$odiff" -gt 0 ] && warn "${other#$HOME/}: $odiff skill(s) there differ from the repo - setup still copies skills into this store; if the tool that reads it is not in use, the copies are stale code nobody is watching"
done

[ "$QUIET" = "1" ] && [ "$problems" = "0" ] && [ "$warnings" = "0" ] && exit 0
echo
if [ "$problems" = "0" ] && [ "$warnings" = "0" ]; then
  echo "install-doctor: this machine is set up correctly."
else
  echo "install-doctor: $problems broken, $warnings worth a look."
  echo "  Anything marked ⚠ is a thing that fails SILENTLY - that is why it is listed."
fi
[ "$problems" = "0" ]
