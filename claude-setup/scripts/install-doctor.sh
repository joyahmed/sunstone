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
  case "$(basename "$f")" in *.bak|*.bak.*|*.md|*.txt) continue;; esac
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

[ "$QUIET" = "1" ] && [ "$problems" = "0" ] && [ "$warnings" = "0" ] && exit 0
echo
if [ "$problems" = "0" ] && [ "$warnings" = "0" ]; then
  echo "install-doctor: this machine is set up correctly."
else
  echo "install-doctor: $problems broken, $warnings worth a look."
  echo "  Anything marked ⚠ is a thing that fails SILENTLY - that is why it is listed."
fi
[ "$problems" = "0" ]
