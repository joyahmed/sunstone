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
#   · a top-level config file COPIED into ~/.claude once and never re-copied -
#     a status line 5 KB behind its repo copy painted every session for weeks,
#     while the SAME file on the sibling userland was a symlink and correct;
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
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
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
# MEMORY_REPO overrides that resolution, for the one case it cannot serve: this
# run is pointed at the OTHER userland's HOME on a two-userland machine, so the
# path file there holds that side's spelling of the repo and this filesystem
# cannot open it. Same shape as MEMORY_REPO_HOOKS / MEMORY_REPO_MIGRATIONS above.
[ -n "${MEMORY_REPO:-}" ] && [ -d "$MEMORY_REPO" ] && MEM="$MEMORY_REPO"
# ⛔ UNRESOLVABLE IS NOT ABSENT. Reporting it as absent would be the THIRD
# cross-filesystem false positive in this file - the interpreter check (PATH
# belongs to the shell running this, not to the HOME being inspected) and the
# core.hooksPath check (a drive-letter path is unopenable from the other side)
# are the two that already exist and are deliberately left alone. A personal
# root this process cannot open makes everything only that root ships
# UNVERIFIABLE: say so once, and judge nothing on it.
MEM_UNRESOLVED=""
if [ -n "$MEM" ] && [ ! -d "$MEM" ]; then MEM_UNRESOLVED="$MEM"; MEM=""; fi
MEMORY_REPO_HOOKS="${MEMORY_REPO_HOOKS:-${MEM:+$MEM/claude-setup/config/hooks}}"
MEMORY_REPO_MIGRATIONS="${MEMORY_REPO_MIGRATIONS:-${MEM:+$MEM/claude-setup/migrations}}"

settings_path="$CFG/settings.json"
problems=0; warnings=0
ok()   { [ "$QUIET" = "1" ] || printf '  ✔ %s\n' "$1"; }
warn() { printf '  ⚠ %s\n' "$1"; warnings=$((warnings+1)); }
bad()  { printf '  ⛔ %s\n' "$1"; problems=$((problems+1)); }

[ "$QUIET" = "1" ] || echo "install-doctor: $CFG"

# --- 0. can this run see the personal root at all? ----------------------------
if [ -n "$MEM_UNRESOLVED" ]; then
  warn "personal root: CANNOT VERIFY - $CFG/ai-memory-path names \"$MEM_UNRESOLVED\", which this process cannot open. That is unopenable, NOT missing: a path written by the other userland of a two-userland machine reads exactly like this from here. Nothing only that root ships is checked below, and a file it OVERRIDES is judged against the framework's own copy instead - which can read as DIVERGED. Re-run with MEMORY_REPO=<that repo as THIS filesystem spells it> to check them."
fi

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

# --- 8. an installed command, skill or config file the repo has MOVED PAST ----
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
# The same hat a THIRD time: the files setup installs DIRECTLY into ~/.claude - a
# status line, the CLAUDE.md overlay, the supermode settings - are copies too,
# and this check walked only commands/ and skills/ until one of them was found
# 5 KB behind by hand. Where that list comes from, and what it deliberately
# leaves out, is documented at tl_pairs() below beside the loop that walks it.
#
# ⚠️ STALE AND DIVERGED ARE DIFFERENT ANSWERS AND ONLY ONE IS SAFE TO FIX.
#   stale    - the installed file is only an OLD COPY of ours, by either of two
#              tests: every line of it also appears in the repo copy and the
#              repo copy has lines it lacks, OR its content is EXACTLY a past
#              version of that repo path. --fix refreshes it.
#   diverged - neither: content matching no version any source root's history
#              has for that path. It is REPORTED AND LEFT - no --fix, no
#              backup-and-replace: named, and the person decides.
# A THIRD REPORT, not a third state: when the search through past versions hits
# its revision cap without a match, the file is named as "no match in the last N
# revisions" rather than as diverged. Those are different statements, and
# printing the second when you mean the first is a confident wrong answer.
#
# ⚠️ AND THE REPORT NEVER CLAIMS INTENT, only content. A hand-refresh that
# MERGED versions - somebody pasting part of a repo copy in, or content from two
# roots - matches no blob while being nobody's deliberate authoring, and no
# content test can tell that apart from an edit. So the words are "matches no
# version in history", never "edited here": the first is what was measured, the
# second is a guess about a person.
# Reported as ⚠ rather than ⛔ on purpose: nothing is broken right now, the file
# is merely behind, and that is exactly the definition of the silent class this
# script prints warnings for.
#
# subset_of <installed> <repo> - the predicate above, and BYTE-IDENTICAL to
# is_stale_subset() in setup.sh on purpose: that one CONVERTS what this one
# REPORTS. awk, not python3, so a machine without python3 still gets the answer
# instead of a skipped check.
#
# ⚠️ WHAT NOW DIFFERS BETWEEN THE TWO FILES, SO NEITHER COMMENT IS A LIE. This
# function is unchanged in both. What changed is that the DOCTOR no longer uses
# it alone: stale_copy() below tries it first and then asks the repo's HISTORY
# (the block just under it). setup.sh has deliberately NOT been given that
# second test, for three reasons:
#   · the two act on opposite answers. A wrong "diverged" HERE is silent and
#     permanent - --fix skips that file forever and nobody is ever told. A wrong
#     "diverged" in setup.sh PRINTS "kept <dst> as it is" with the diff to run,
#     in front of the person running setup, and the copy keeps working;
#   · setup.sh's answer REPLACES the file with a symlink, so a wrong "stale"
#     there is destructive in a way this read-only report is not, and its coarse
#     conservative predicate is the right bias for it;
#   · keeping this one byte-identical is what preserves the audited invariant -
#     what the doctor calls a subset is still exactly what setup would convert.
# If setup.sh is ever given the history test, it belongs beside this function in
# BOTH files and this comment has to stop saying they differ.
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

# ⛔ WHAT subset_of CANNOT SEE, AND WHY A SECOND TEST HAD TO EXIST. The subset
# test only recognises staleness that ADDED lines. The moment an upstream commit
# REMOVES lines, every un-refreshed copy holds lines the repo no longer has -
# and line-set-wise that is indistinguishable from somebody's deliberate edit,
# so the conservative branch fires and --fix never touches that file again.
# APPEND-ONLY GROWTH WAS THE ONLY STALENESS THIS CHECK COULD SEE.
# Measured, not theorised: on one machine an installed command and a whole skill
# tree were reported DIVERGED when they were merely OLD - their "local-only"
# lines were lines that two upstream commits had dropped on purpose. Files
# reported as somebody's edit, which nobody had edited, and which would
# therefore have stayed behind forever.
#
# So ask the repo instead of guessing: does the installed content equal ANY PAST
# VERSION of that repo path? If it does, it is an OLD RELEASE of ours - stale,
# refreshable - whichever lines came or went in between.
#
# ⛔ EVERY CANDIDATE ROOT, NOT ONLY THE ONE THAT WINS TODAY. setup installs from
# the framework root AND the personal overlay, and src_for() below resolves a
# name to the LAST root that ships it. Which root ships a given command or skill
# has changed over time: a file can have come from one root at install time and
# from the other now. Searching only today's winner would report an old release
# of the OTHER root as content nobody ever shipped - the same false verdict this
# test exists to remove, reintroduced one level up. So the same repo-relative
# path is looked up in the history of EVERY root, and a match in any of them is
# a match.
#
# ⭐ BLOB IDS, NOT TEXT. `git hash-object` on the installed file against each
# <commit>:<path> object id. Exact, immune to line order, and the whole history
# resolves in ONE `cat-file --batch-check` - where a text diff would need a rule
# per kind of whitespace and a process per revision.
#
# ⭐ TWO TIERS, AND THE REPORT SAYS WHICH ONE ANSWERED. Walking `git log -- <path>`
# finds a blob only where that PATH carried it, and a path-limited walk misses a
# rename, a blob that lived on a branch or a merge parent history simplification
# drops, and anything older than the cap. That miss has already produced a false
# "nobody ever shipped this" in the field. So when the path-scoped walk finds
# nothing, the installed blob id is looked up in the repo's OBJECT STORE directly
# (`cat-file -e`, O(1), no enumeration) - which answers the weaker question "did
# this content ever exist in this repo" instead of "is this an old release of
# THIS path". Both make the file refreshable; they are NOT the same claim, and
# the report prints them on separate lines because a reader deserves to know
# which one they are being handed.
#
# ⚠️ LINE ENDINGS, DECIDED RATHER THAN DISCOVERED. Hashing uses
# --path=<repo-relative path>, so git applies THE SAME clean filter that made
# those blobs: on a core.autocrlf checkout a CRLF working copy hashes to the LF
# blob for free, by git's rule and not one invented here. A checkout with no
# such filter (the normal Linux case) would still not match a CRLF copy - and a
# CRLF copy on a mounted Windows drive judged against a LF checkout is exactly
# the shape this script must survive. So there is ONE retry, with \r bytes
# removed. That retry cannot manufacture a false match: deleting \r bytes can
# only collapse two contents that differ in NOTHING BUT \r bytes, which is a
# line-ending difference and not an edit.
#
# ⛔ BOUNDED. A path with a long history must not make the doctor slow, so only
# the newest $HIST_CAP revisions of it are examined. 50 because the deepest
# per-file history in the trees this walks is 26 commits (24 in the personal
# overlay), so 50 is about twice the real worst case and still bounds a
# pathological path. When the cap is reached WITHOUT a match the answer is "no
# match in the last N revisions", NOT "diverged": the file may well be an older
# release than the search went back to, and saying the second thing is the
# confident wrong answer this whole script exists to remove.
HIST_CAP="${DOCTOR_HISTORY_CAP:-50}"

# root_rel <absolute source path> -> that path relative to the source root it
# came from, or empty when it is under no known root. This is the key the history
# search uses to look the SAME name up in every root.
root_rel() {
  for _rr in "${MEM:-}" "$REPO"; do
    [ -n "$_rr" ] || continue
    case "$1" in "$_rr"/*) printf '%s\n' "${1#"$_rr"/}"; return ;; esac
  done
}

# hist_state_one <installed> <root> <path relative to root>
#   -> oldrelease | unknown | capped | nohistory
# One root's answer. <path relative to root> need NOT exist on disk: we are
# asking the root's HISTORY about that path, and the root that shipped the file
# originally may not ship it any more.
# hist_state_one -> oldrelease | oldblob | unknown | capped | nohistory
hist_state_one() {
  [ -d "$2" ] || { echo nohistory; return; }
  # ⚠️ Ask git for the path rather than assembling one by string surgery: the
  # toplevel git reports can be spelled differently from the path we were handed
  # (a symlinked temp dir, /tmp vs /private/tmp), and a prefix test against the
  # wrong spelling would silently disable all of this. --show-prefix also covers
  # a root that is a SUBDIRECTORY of a larger checkout.
  _h1_top=$(git -C "$2" rev-parse --show-toplevel 2>/dev/null) || _h1_top=""
  [ -n "$_h1_top" ] || { echo nohistory; return; }
  _h1_pfx=$(git -C "$2" rev-parse --show-prefix 2>/dev/null) || _h1_pfx=""
  _h1_rel="$_h1_pfx$3"
  # CAP + 1 revisions asked for, CAP of them searched: the extra one is how we
  # know whether unsearched history exists at all.
  _h1_shas=$(git -C "$_h1_top" log --format='%H' --max-count=$((HIST_CAP + 1)) -- "$_h1_rel" 2>/dev/null)
  [ -n "$_h1_shas" ] || { echo nohistory; return; }
  _h1_seen=$(printf '%s\n' "$_h1_shas" | wc -l | tr -d ' ')
  _h1_blobs=$(printf '%s\n' "$_h1_shas" | head -n "$HIST_CAP" \
    | awk -v r=":$_h1_rel" '{ print $0 r }' \
    | git -C "$_h1_top" cat-file --batch-check 2>/dev/null \
    | awk '$2 == "blob" { print $1 }')
  # The installed file's blob id, plus - only when it actually holds a \r - the
  # one line-ending retry. Both ids are then tried against both tiers.
  _h1_ids=$(git -C "$_h1_top" hash-object --path="$_h1_rel" -- "$1" 2>/dev/null) || _h1_ids=""
  if ! LC_ALL=C tr -d '\r' < "$1" | cmp -s - "$1"; then
    _h1_lf=$(LC_ALL=C tr -d '\r' < "$1" | git -C "$_h1_top" hash-object --path="$_h1_rel" --stdin 2>/dev/null) || _h1_lf=""
    [ -n "$_h1_lf" ] && _h1_ids="$_h1_ids $_h1_lf"
  fi
  # TIER 1, the strong claim: this content is a past version of THIS path.
  for _h1_w in $_h1_ids; do
    printf '%s\n' "$_h1_blobs" | grep -qxF "$_h1_w" && { echo oldrelease; return; }
  done
  # TIER 2, the weaker claim: this content exists as a blob in this repo at all -
  # so it came from here, under some path, at some point. cat-file -e is an O(1)
  # object lookup, not an enumeration of the object graph.
  for _h1_w in $_h1_ids; do
    git -C "$_h1_top" cat-file -e "$_h1_w" 2>/dev/null && { echo oldblob; return; }
  done
  # ⚠️ Neither tier matched. The object store is NOT a complete record of every
  # version this repo ever had (gc prunes unreachable objects; a shallow clone
  # never had the old ones), so when there is ALSO path history the cap stopped
  # us reading, the honest answer is "did not find it that far back" rather than
  # "no version ever had it".
  [ "$_h1_seen" -gt "$HIST_CAP" ] && { echo capped; return; }
  echo unknown
}

# hist_state <installed> <repo-file> -> oldrelease | unknown | capped | nohistory
#   oldrelease - the installed content IS a past version of that path in SOME
#                source root (the strong claim)
#   oldblob    - no path-scoped match, but the content exists as a blob in some
#                root's object store: it came from here under some path. Stale
#                and refreshable, on weaker evidence, and reported as such.
#   unknown    - no version that path ever had in any root, and every root's
#                history for it was searched to the end
#   capped     - no match, and at least one root has more history than the cap
#                searched. NOT the same statement as "no version ever had it".
#   nohistory  - no git, no readable checkout, or no commit in any root touches
#                that path. The caller falls back to subset_of AND SAYS SO: a
#                verdict whose basis is unstated is worse than a coarse verdict.
hist_state() {
  command -v git >/dev/null 2>&1 || { echo nohistory; return; }
  [ -f "$1" ] || { echo nohistory; return; }
  _hs_rel=$(root_rel "$2")
  _hs_any=0; _hs_cap=0; _hs_blob=0
  for _hs_r in "${MEM:-}" "$REPO"; do
    if [ -n "$_hs_rel" ]; then
      [ -n "$_hs_r" ] || continue
      _hs_root="$_hs_r"; _hs_p="$_hs_rel"
    else
      # A source under no known root (nothing does this today; it keeps the
      # helper honest if something ever passes an outside path).
      _hs_root=$(dirname -- "$2"); _hs_p=$(basename -- "$2")
    fi
    case "$(hist_state_one "$1" "$_hs_root" "$_hs_p")" in
      oldrelease) echo oldrelease; return ;;
      oldblob)    _hs_blob=1; _hs_any=1 ;;
      capped)     _hs_cap=1; _hs_any=1 ;;
      unknown)    _hs_any=1 ;;
    esac
    [ -n "$_hs_rel" ] || break
  done
  # ⚠️ Precedence: a path-scoped match in ANY root beats everything (handled by
  # the early return), then a content match in any root, then "we did not look
  # far enough", then "not ours".
  [ "$_hs_blob" = 1 ] && { echo oldblob; return; }
  [ "$_hs_cap" = 1 ] && { echo capped; return; }
  [ "$_hs_any" = 1 ] && { echo unknown; return; }
  echo nohistory
}
# stale_copy <installed> <repo-file> -> 0 when <installed> is ONLY AN OLD COPY of
# ours: a strict line subset of the current version (the append-only shape), or
# an exact past version of that repo path (any shape, including one a newer
# commit removed lines from). subset_of runs FIRST - it is awk over two files
# and costs nothing in the repo, and both routes give the same verdict.
stale_copy() {
  subset_of "$1" "$2" && return 0
  case "$(hist_state "$1" "$2")" in oldrelease|oldblob) return 0 ;; esac
  return 1
}

# hist_any <state> <installed> <repo> - true when <state> is the history answer
# for this file, or for at least one DIFFERING file inside this tree. Used to
# qualify a verdict the five states cannot carry on their own: which tier
# answered ("oldblob"), and whether the search was cut short ("capped").
# ⚠️ A file the subset test already settled is skipped - its staleness does not
# rest on history at all, and labelling it by a history tier would misreport it.
# ⚠️ A tree holding a file the repo does not ship AT ALL is diverged for a reason
# no history can soften, so no qualifier applies to it.
hist_any() {
  if [ -d "$2" ]; then
    for _hc_f in $(find "$2" -type f 2>/dev/null); do
      _hc_r=${_hc_f#"$2"/}
      [ -f "$3/$_hc_r" ] || return 1
    done
    for _hc_f in $(find "$2" -type f 2>/dev/null); do
      _hc_r=${_hc_f#"$2"/}
      cmp -s "$_hc_f" "$3/$_hc_r" && continue
      subset_of "$_hc_f" "$3/$_hc_r" && continue
      [ "$(hist_state "$_hc_f" "$3/$_hc_r")" = "$1" ] && return 0
    done
    return 1
  fi
  subset_of "$2" "$3" && return 1
  [ "$(hist_state "$2" "$3")" = "$1" ]
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
  stale_copy "$1" "$2" && { echo stale; return; }
  echo diverged
}

# tree_state <installed-dir> <repo-dir> -> link | same | stale | diverged | absent
# A tree is only "stale" when it holds no file of its own AND every file that
# differs is an old copy by stale_copy's test. One installed-only file makes the
# whole tree
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
    stale_copy "$f" "$2/$_rel" || { echo diverged; return; }
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

# ⛔ WHICH TEST THIS RUN IS ABLE TO USE, settled once and STATED in the report.
# The history test needs a readable git checkout of the source, and there are
# ordinary installs that have none: a tarball, a copied directory with no .git,
# or - the case check 0 above already apologises for - a root named in a spelling
# this filesystem cannot open. In any of those the check degrades to the subset
# test, which can only see staleness that ADDED lines. A coarse verdict is fine;
# a coarse verdict presented as a fine one is not, so the basis is printed.
# ⚠️ The roots are NAMED in the report, by the basename this run resolved them
# to - so "no ancestor match" is a claim a reader can go and check, rather than
# one they have to trust. Derived at run time, never written into this file: it
# must name no repository (see the header).
hist_roots=0; nohist_roots=0; hist_root_names=""
for _r in "${MEM:-}" "$REPO"; do
  [ -n "$_r" ] || continue
  if git -C "$_r" rev-parse --show-toplevel >/dev/null 2>&1; then
    hist_roots=$((hist_roots+1))
    hist_root_names="${hist_root_names:+$hist_root_names + }${_r##*/}"
  else
    nohist_roots=$((nohist_roots+1))
  fi
done

stale_list=""; diverged_list=""; absent_list=""; capped_list=""; weak_list=""; tracked=0
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
      stale)    stale_list="$stale_list commands/$name"
                hist_any oldblob "$CFG/commands/$name" "$real" \
                  && weak_list="$weak_list commands/$name" ;;
      diverged) if hist_any capped "$CFG/commands/$name" "$real"
                then capped_list="$capped_list commands/$name"
                else diverged_list="$diverged_list commands/$name"; fi ;;
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
      stale)    stale_list="$stale_list skills/$name"
                hist_any oldblob "$CFG/skills/$name" "$real" \
                  && weak_list="$weak_list skills/$name" ;;
      diverged) if hist_any capped "$CFG/skills/$name" "$real"
                then capped_list="$capped_list skills/$name"
                else diverged_list="$diverged_list skills/$name"; fi ;;
      absent)   absent_list="$absent_list skills/$name" ;;
    esac
  done
done

# top-level config files: the ones setup installs DIRECTLY into $CFG rather than
# into commands/ or skills/ - the gap this check had until a stale one was found
# by hand. A status line 5 KB behind the repo copy had painted every session for
# weeks; the same file on the sibling userland was a symlink and correct, so
# nothing on either side could see it. This list is setup.sh's, step by step:
#   step_statusline     claude-setup/config/statusline-command.sh → $CFG/
#   setup.ps1 (Windows) claude-setup/config/statusline-command.js → $CFG/
#   step_supermode      claude-setup/config/supermode.settings.json → $CFG/
#   step_claude_global  claude-setup/config/CLAUDE.global.md → $CFG/CLAUDE.md,
#                       falling back to agents/CLAUDE.md when NO root ships one
#                       (step_agents, guarded there by CLAUDE_GLOBAL_ANY).
#
# ⛔ EXCLUDED, each for its own reason, so an absence here is a decision rather
# than an oversight:
#   settings.json - MERGED into the live file by the template merger, never
#                   copied over it. A live settings.json is a SUPERSET of the
#                   shipped one BY DESIGN, so "strict subset of the repo copy"
#                   would describe a correct install as a broken one and the
#                   inverse as fine. Checks 1b and 2 cover it properly, by
#                   comparing what it NAMES rather than its lines.
#   hooks/        - a subdirectory, and already covered three ways: check 1 for
#                   presence, check 1b for registration, check 6 for the mode.
#   ~/CLAUDE.md,
#   ~/AGENTS.md   - installed at the HOME root, not into $CFG. Same failure
#                   class, still unchecked; named here so it stays a known gap
#                   instead of an assumed pass.
#
# tl_pairs - <repo-relative source>|<name under $CFG>, one per line.
tl_pairs() {
  printf '%s\n' 'claude-setup/config/statusline-command.sh|statusline-command.sh' \
                'claude-setup/config/statusline-command.js|statusline-command.js' \
                'claude-setup/config/supermode.settings.json|supermode.settings.json'
  # One destination, two possible sources, and setup.sh's own precedence: a
  # CLAUDE.global.md shipped by ANY root takes $CFG/CLAUDE.md, else agents/CLAUDE.md.
  if [ -n "$(src_for claude-setup/config/CLAUDE.global.md)" ]; then
    printf '%s\n' 'claude-setup/config/CLAUDE.global.md|CLAUDE.md'
  else
    printf '%s\n' 'agents/CLAUDE.md|CLAUDE.md'
  fi
}
tl_src() {  # <name under $CFG> -> absolute source path, or empty
  for _q in $(tl_pairs); do
    [ "${_q#*|}" = "$1" ] && { src_for "${_q%%|*}"; return; }
  done
}
# line_text <file> - false for anything holding a NUL byte, i.e. not
# line-oriented text. ⚠️ subset_of COMPARES LINES, and a line comparison says
# nothing whatsoever about a binary or generated blob: calling one "stale" on
# that evidence would be a confident wrong answer, which is the shape this
# script exists to remove. None of the four names above is binary today; this is
# what keeps a future one from being guessed at instead of reported as unknown.
line_text() {
  [ -f "$1" ] || return 1
  LC_ALL=C tr -d '\000' < "$1" | cmp -s - "$1"
}
for pairv in $(tl_pairs); do
  rel=${pairv%%|*}; name=${pairv#*|}
  real=$(src_for "$rel"); [ -n "$real" ] || continue
  tracked=$((tracked+1))
  st=$(file_state "$CFG/$name" "$real")
  case "$st" in
    stale|diverged)
      # ⚠️ ...unless the HISTORY test is what answered. A blob-id match is an
      # exact content identity, and it means precisely the same thing for a
      # generated blob as for text: this is a past version of that repo path.
      # Only the LINE comparison is meaningless here, so only it is refused.
      if { ! line_text "$CFG/$name" || ! line_text "$real"; } \
         && ! case "$(hist_state "$CFG/$name" "$real")" in oldrelease|oldblob) true ;; *) false ;; esac; then
        warn "config/$name differs from the repo copy, is NOT line-oriented text, and matches no past version of that repo path - the subset test that would otherwise separate stale from diverged means nothing for such a file, so this is CANNOT VERIFY rather than a guess"
        continue
      fi ;;
  esac
  case "$st" in
    stale)    stale_list="$stale_list config/$name"
              hist_any oldblob "$CFG/$name" "$real" \
                && weak_list="$weak_list config/$name" ;;
    diverged) if hist_any capped "$CFG/$name" "$real"
              then capped_list="$capped_list config/$name"
              else diverged_list="$diverged_list config/$name"; fi ;;
    absent)
      # ⛔ The two statusline twins are SEPARATE files under a parity contract,
      # never substitutes for each other - and they are installed by different
      # installers: setup.sh ships the .sh on POSIX, setup.ps1 the .js on
      # Windows. A machine that has one therefore LEGITIMATELY lacks the other,
      # and "shipped but never installed" about the twin this OS does not
      # install would be a false positive of exactly the kind already costing
      # this script two lines of apology. Each installed twin is still judged on
      # its OWN content against its OWN source, above; only the absent-report is
      # suppressed, and only while the other twin is actually there.
      case "$name" in
        statusline-command.sh) [ -e "$CFG/statusline-command.js" ] && continue ;;
        statusline-command.js) [ -e "$CFG/statusline-command.sh" ] && continue ;;
      esac
      absent_list="$absent_list config/$name" ;;
  esac
done

if [ "$tracked" = "0" ]; then
  warn "commands/skills/config: nothing shipped to compare - this check did NOT run"
else
  if [ "$nohist_roots" = "0" ]; then
    ok "commands/skills/config: old-copy-vs-current decided against REPO HISTORY - exact blob ids against every past version of each path in $hist_root_names (newest $HIST_CAP revisions of each), then against those repos' whole object stores, so a copy an upstream commit REMOVED lines from, one that shipped from the other root, or one whose path was renamed, is still recognised as an old release of ours"
  else
    warn "commands/skills/config: old-copy-vs-current fell back to the LINE-SUBSET test - $nohist_roots of $((hist_roots + nohist_roots)) source root(s) expose no readable git history (not a checkout, or a root this filesystem cannot open), so no past version can be looked up there. That test sees only a copy MISSING lines: one a newer commit removed lines from is indistinguishable from a local change, and is named below as differing."
  fi
  if [ -n "$stale_list" ]; then
    if [ "$FIX" = "1" ]; then
      for item in $stale_list; do
        kind=${item%%/*}; name=${item#*/}
        if [ "$kind" = "commands" ]; then
          real=$(src_for "claude-setup/commands/$name")
          mkdir -p "$CFG/commands" && cp "$real" "$CFG/commands/$name" && echo "  → refreshed commands/$name"
        elif [ "$kind" = "config" ]; then
          real=$(tl_src "$name")
          # ⚠️ A symlink is REMOVED rather than written through. One pointing at
          # the source is never in this list (that is `link`), but one pointing
          # anywhere else would have this cp overwrite THAT file instead of this
          # destination - install_copy in setup.sh removes it for the same reason.
          [ -L "$CFG/$name" ] && rm -f "$CFG/$name"
          # cp keeps an existing destination's mode, so a refreshed status line
          # stays executable; chmod covers the case where it was not.
          mkdir -p "$CFG" && cp "$real" "$CFG/$name" \
            && { [ -x "$real" ] && chmod +x "$CFG/$name"; echo "  → refreshed config/$name"; }
        else
          real=$(src_for "skills/$name")
          # Safe to replace whole: "stale" proved this tree holds no file the
          # repo does not also ship, so nothing here is anybody's but ours.
          rm -rf "${CFG:?}/skills/$name" && cp -r "$real" "$CFG/skills/$name" && echo "  → refreshed skills/$name"
        fi
      done
      ok "commands/skills/config: refreshed what was only out of date"
    else
      warn "STALE - installed but never refreshed since the repo moved on:$stale_list   (this script with --fix refreshes them; LINK_COMMANDS=1 / LINK_SKILLS=1 / LINK_CLAUDE_MD=1 / LINK_HOOKS=1 in sunstone.conf stop it happening again, each for its own kind)"
    fi
  fi
  if [ -n "$diverged_list" ]; then
    if [ "$nohist_roots" = "0" ]; then
      warn "DIVERGED - matches no version in history: no past version of the path in $hist_root_names (newest $HIST_CAP revisions of each searched) has this content, and neither does any blob in those repos' object stores, so NOT touched and not refreshable:$diverged_list   (diff each against the repo; keep the local change or delete the file and re-run setup)"
    else
      warn "DIVERGED - differs by more than the line-subset test can call out of date, and no past version could be looked up at all (see the basis line above), so NOT touched and not refreshable:$diverged_list   (diff each against the repo; keep the local change or delete the file and re-run setup)"
    fi
  fi
  # ⛔ NOT the same statement as DIVERGED, and it gets its own line for that
  # reason. These matched no version of their repo path within the cap, and there
  # is older history the search never reached - so "not recognised", never
  # "edited here". --fix leaves them alone exactly as it leaves a diverged file.
  # ⚠️ STALE on the weaker of the two tiers, said out loud. "This content came
  # from this repo" is not "this is an old release of this path": a rename, a
  # branch, or path history deeper than the cap all look exactly like this.
  # Refreshable either way - what differs is the strength of the claim.
  [ -n "$weak_list" ] && warn "stale on a CONTENT match, not a path match - no match in the last $HIST_CAP revisions of their own path, but the content IS a blob in the object store of $hist_root_names, so it came from here under some path (a rename, a branch, or history deeper than the cap all look like this). Refreshable, and --fix does:$weak_list"
  [ -n "$capped_list" ] && warn "no match in the last $HIST_CAP revisions of the path in ${hist_root_names:-the source root} and no matching blob in the object store either, but older path history exists that this run did NOT search - so NOT refreshed, and NOT reported as diverged either:$capped_list   (DOCTOR_HISTORY_CAP=<n> searches further back; or diff each against the repo yourself)"
  [ -n "$absent_list" ] && warn "commands/skills/config shipped but never installed:$absent_list   (re-run setup)"
  [ -z "$stale_list$diverged_list$absent_list$capped_list" ] && ok "commands/skills/config: all $tracked match the repo (or are symlinks to it)"
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
