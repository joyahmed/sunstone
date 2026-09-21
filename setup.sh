#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="${HOME:?}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m'

# ── Arguments ────────────────────────────────────
#
#   --memory-repo <v>, --memory-repo=<v>
#                       your personal memory repo (any git repo you own): a git
#                       URL or a local path
#   --clone-to <v>, --clone-to=<v>
#                       where to clone it when --memory-repo is a URL
#                       (default: ~/.ai-memory, the path the hooks also try when
#                       ~/.claude/ai-memory-path is missing). Ignored, with a
#                       notice, when --memory-repo is a local path.
#   --skip-memory       do not touch ~/.claude/ai-memory-path
#   --skip-overlay      install this checkout's trees only; ignore any skills,
#                       agents, commands, hooks, configs or settings.json the
#                       personal repo carries in the same layout
#   -h, --help
#
# The repo can also come from the SUNSTONE_MEMORY_REPO environment variable, or
# from an interactive prompt when stdin is a terminal.

usage() {
  sed -n '/^# ── Arguments/,/^$/p' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
  cat <<USAGE
Examples:
  bash setup.sh --memory-repo git@github.com:alice/my-memory.git
  bash setup.sh --memory-repo=~/src/my-memory
  bash setup.sh --memory-repo https://github.com/alice/my-memory --clone-to=~/src/my-memory
  SUNSTONE_MEMORY_REPO=https://github.com/alice/my-memory bash setup.sh
USAGE
}

MEMORY_REPO_SPEC="${SUNSTONE_MEMORY_REPO:-}"
CLONE_TO=""
SKIP_MEMORY=0
SKIP_OVERLAY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --memory-repo)   [ $# -ge 2 ] || { echo "--memory-repo needs a value" >&2; exit 2; }
                     MEMORY_REPO_SPEC="$2"; shift 2 ;;
    --memory-repo=*) MEMORY_REPO_SPEC="${1#*=}"; shift ;;
    --clone-to)      [ $# -ge 2 ] || { echo "--clone-to needs a value" >&2; exit 2; }
                     CLONE_TO="$2"; shift 2 ;;
    --clone-to=*)    CLONE_TO="${1#*=}"; shift ;;
    --skip-memory)   SKIP_MEMORY=1; shift ;;
    --skip-overlay)  SKIP_OVERLAY=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ⛔ git is a hard dependency of every step that follows: the memory repo is
# resolved with it, and the two guards are installed by pointing the GLOBAL
# core.hooksPath at ~/.git-hooks. Checked here, before the banner, because a
# missing git used to surface as a bare "git: command not found" halfway
# through - after the hook files had already landed, which is exactly the
# half-configured machine the ordering below is designed to prevent.
if ! command -v git >/dev/null 2>&1; then
  echo "! git is required and was not found on PATH; nothing has been installed." >&2
  exit 1
fi

echo -e "${CYAN}========================================"
echo " sunstone setup (Linux / macOS / WSL)"
echo -e "========================================${NC}"
echo ""

# ── Helpers ──────────────────────────────────────

# backup <path> - copy an existing file or directory to <path>.bak.<timestamp>.
backup() {
  local src="$1"
  if [ -f "$src" ] || [ -d "$src" ]; then
    local bak i=1
    bak="${src}.bak.$(date +%Y%m%d_%H%M%S)"
    # Unique even when the same file is replaced twice within one second.
    while [ -e "$bak" ]; do bak="${src}.bak.$(date +%Y%m%d_%H%M%S)-$i"; i=$((i + 1)); done
    cp -r "$src" "$bak" 2>/dev/null || true
    echo "  backed up: $src → $bak"
  fi
}

# install_copy <src> <dst> - copy <src> over <dst>. An existing <dst> that
# differs is backed up first; an identical one is left alone, so a re-run of
# setup produces no backup clutter.
install_copy() {
  local src="$1" dst="$2"
  if [ -e "$dst" ] && ! cmp -s "$src" "$dst"; then
    backup "$dst"
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
}

# install_file <src> <dst> - install_copy, then mark <dst> executable.
install_file() {
  install_copy "$1" "$2"
  chmod +x "$2"
}

# read_path_file <file> - the first line of a one-line path file, TRIMMED (a
# path may contain spaces, so whitespace is never squeezed out of it). Prints
# nothing when the file is missing.
read_path_file() {
  [ -f "$1" ] || return 0
  head -n1 "$1" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# is_git_url <spec> - true for scheme://... and for the scp form, which must
# START with user@host: (the same rule setup.ps1 applies; a local directory
# named "a@b:c" deep in a path is not a URL).
is_git_url() {
  case "$1" in *://*) return 0 ;; esac
  printf '%s' "$1" | grep -qE '^[^/\\]+@[^/\\]+:'
}

# Read one KEY from <personal-repo>/claude-setup/config/sunstone.conf.
# Source-free on purpose: the file is user content, so it is grepped, never
# executed. Prints the default when the file or the key is absent. Same rules
# as the hooks: last matching line wins, leading whitespace allowed, a '#'
# starts a comment only at line start or after whitespace (so a bare '#' inside
# a value or a double-quoted value is kept), surrounding double quotes are
# stripped, whitespace is trimmed (never deleted from inside a value).
conf_get() {
  local repo="$1" key="$2" default="$3" file val
  file="$repo/claude-setup/config/sunstone.conf"
  val=""
  if [ -f "$file" ]; then
    # Byte-for-byte the body of conf_get in claude-setup/config/hooks/
    # ai-memory-sync.sh: the two must agree or setup's closing summary names a
    # different memory file than the hook actually injects. Leading whitespace
    # is kept until the comment rule has run - KEY=#x is the value "#x", while
    # KEY= #x is a comment (empty → the default) - and a quoted value runs to
    # the next '"', so anything after the closing quote is ignored.
    val="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null | tail -n1 \
           | sed -e "s/^[[:space:]]*${key}[[:space:]]*=//" -e 's/[[:space:]]*$//')"
    case "$(printf '%s' "$val" | sed 's/^[[:space:]]*//')" in
      \"*) val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*"//' -e 's/".*$//')" ;;
      *)   val="$(printf '%s' "$val" | sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" ;;
    esac
  fi
  if [ -n "$val" ]; then printf '%s\n' "$val"; else printf '%s\n' "$default"; fi
}

# ~/.claude/settings.json is edited by merge scripts several times in one run.
# snapshot_settings prints the path of a fresh backup (unique even within one
# second); settle_settings_backup removes it again when the merge turned out
# to be a no-op, and otherwise says where it is.
CLAUDE_DIR="$HOME_DIR/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
MERGER="$SCRIPT_DIR/claude-setup/config/merge-settings-template.py"
MERGER_JS="$SCRIPT_DIR/claude-setup/config/merge-settings-template.mjs"
# Whether the user had a settings.json before this run. The hook registration
# below creates one, so without this flag the template merge that follows would
# "back up" a file the user never wrote - a .bak of an intermediate state
# nobody would ever want restored.
SETTINGS_PREEXISTED=0
[ -f "$SETTINGS" ] && SETTINGS_PREEXISTED=1
snapshot_settings() {
  [ -f "$SETTINGS" ] || return 0
  local b i=1
  b="$SETTINGS.bak.$(date +%Y%m%d_%H%M%S)"
  while [ -e "$b" ]; do b="$SETTINGS.bak.$(date +%Y%m%d_%H%M%S)-$i"; i=$((i + 1)); done
  cp "$SETTINGS" "$b"
  printf '%s\n' "$b"
}
settle_settings_backup() {
  [ -n "${1:-}" ] || return 0
  if cmp -s "$SETTINGS" "$1"; then rm -f "$1"; else echo "  backed up: $SETTINGS → $1"; fi
}


# ── Personal memory repo (resolved FIRST) ─────────
# Records the PERSONAL memory repo's path in ~/.claude/ai-memory-path so the
# SessionStart hook can pull it and inject its memory file into Claude on any
# machine. The personal repo is any git repo you own; this framework repo holds
# only the hooks.
#
# ⛔ This step runs before anything else is written. A typo in --memory-repo or
# a failed clone (no SSH key for a git@ URL, say) exits 1 here, with the global
# git config, ~/.git-hooks and ~/.claude untouched - so "setup stopped" means
# "nothing landed", and there is nothing to roll back. Earlier versions
# installed the git hooks first, and a failure left a half-configured machine
# with no message saying so.

echo -e "${CYAN}Resolving the personal memory repo...${NC}"
PATH_FILE="$HOME_DIR/.claude/ai-memory-path"
MEMORY_REPO=""
CLONE_TO_USED=0

# 1) Decide which personal repo to use: flag/env, else prompt on a TTY.
if [ "$SKIP_MEMORY" = "1" ]; then
  echo "  --skip-memory: leaving $PATH_FILE untouched"
elif [ -z "$MEMORY_REPO_SPEC" ]; then
  current="$(read_path_file "$PATH_FILE")"
  # [ -e ] not [ -d ]: in a worktree .git is a file. Same test as the hooks.
  [ -n "$current" ] && [ -e "$current/.git" ] || current=""
  if [ -t 0 ]; then
    # Ask whenever stdin is a terminal, even with stdout piped (the prompt then
    # goes to stderr so it still reaches the screen).
    if [ -n "$current" ]; then
      prompt="  Personal memory repo (git URL or local path) [$current]: "
    else
      prompt="  Personal memory repo (git URL or local path) [Enter to skip]: "
    fi
    if [ -t 1 ]; then printf '%s' "$prompt"; else printf '%s' "$prompt" >&2; fi
    read -r MEMORY_REPO_SPEC || true
    [ -n "$MEMORY_REPO_SPEC" ] || MEMORY_REPO_SPEC="$current"
  else
    MEMORY_REPO_SPEC="$current"
    if [ -n "$current" ]; then
      echo "  no --memory-repo given; keeping existing $PATH_FILE → $current"
    else
      echo "  no --memory-repo given and no terminal to ask on; skipping."
      echo "  re-run with:  bash setup.sh --memory-repo <git-url-or-path>"
    fi
  fi
fi

# 2) Resolve it: a local path is used in place; a URL is cloned into --clone-to,
#    or by default into ~/.ai-memory - the one path every hook also tries when
#    ~/.claude/ai-memory-path is missing, so a lost path file still finds it.
#    An existing clone at the destination is reused.
#
#    --skip-memory short-circuits the whole block, MEMORY_REPO_SPEC or not: the
#    flag promises the path file is left alone, and SUNSTONE_MEMORY_REPO being
#    exported in the environment must not quietly break that promise (it used
#    to - the spec was resolved, cloned and written one line after the script
#    said it would not touch anything). setup.ps1 keeps the same shape.
if [ "$SKIP_MEMORY" != "1" ] && [ -n "$MEMORY_REPO_SPEC" ]; then
  if is_git_url "$MEMORY_REPO_SPEC"; then
    CLONE_TO_USED=1
    dest="${CLONE_TO:-$HOME_DIR/.ai-memory}"
    dest="${dest/#\~/$HOME_DIR}"
    if [ -e "$dest/.git" ]; then
      echo "  using existing clone: $dest"
    elif [ -e "$dest" ]; then
      echo -e "  ${RED}! $dest exists but is not a git repo; pass --clone-to <dir> or remove it${NC}"
      echo "  nothing has been installed."
      exit 1
    else
      echo "  cloning $MEMORY_REPO_SPEC → $dest"
      if ! git clone --quiet "$MEMORY_REPO_SPEC" "$dest"; then
        echo -e "  ${RED}! clone of $MEMORY_REPO_SPEC failed${NC}"
        echo "  a git@host: URL needs an SSH key registered with the host; an https:// URL"
        echo "  needs no key for a public repo. Nothing has been installed."
        exit 1
      fi
    fi
    MEMORY_REPO="$(cd "$dest" && pwd)"
  else
    spec="${MEMORY_REPO_SPEC/#\~/$HOME_DIR}"
    if [ ! -d "$spec" ]; then
      echo -e "  ${RED}! $spec is not a directory (and does not look like a git URL)${NC}"
      echo "  nothing has been installed."
      exit 1
    fi
    MEMORY_REPO="$(cd "$spec" && pwd)"
    if ! git -C "$MEMORY_REPO" rev-parse --git-dir >/dev/null 2>&1; then
      echo -e "  ${RED}! $MEMORY_REPO is not a git repository; the sync hook needs one${NC}"
      echo "  nothing has been installed."
      exit 1
    fi
  fi
  mkdir -p "$HOME_DIR/.claude"
  printf '%s\n' "$MEMORY_REPO" > "$PATH_FILE"
  echo "  ai-memory-path → $MEMORY_REPO"
fi
if [ -n "$CLONE_TO" ] && [ "$CLONE_TO_USED" != "1" ]; then
  echo "  ignored: --clone-to only applies to a URL"
fi
echo "  ok"
echo ""

# ── Global git hooks (memory staging guard + force-push guard) ─────
#
# ⛔ `init.templateDir` alone does NOT reach existing repos. Templates are
# copied at `git init` / `git clone` only, so every repo that already exists is
# untouched. `core.hooksPath` is the setting that reaches existing repos too,
# which is why it is used; the template is kept in step only as a fallback if
# core.hooksPath is ever unset by hand.
#
# ⚠️ **A repo-local `core.hooksPath` overrides the global one completely** -
# git does not merge them, and there is no chaining at that level. A repo that
# sets its own hooks directory is not reached by the global setting; the files
# have to be copied into that directory as well. **Any coverage check that
# reads `.git/hooks` is wrong** - resolve each repo's effective hooks dir
# instead, or you will report gaps that do not exist and miss ones that do.
#
# ⚠️ The source of truth is claude-setup/config/git-hooks/* in this repo; the
# live copies are ~/.git-hooks/*. **Pulling this repo does not update the live
# copies** - re-run setup.sh after a pull that touches a hook.
#
# WHICH hooks land is not decided here. The files are installed per install
# root by step_git_hooks, exactly like every other tree, so the personal repo
# can ship guards of its own and can override a shipped one by carrying the
# same filename. This section only prepares the directories and points git at
# them - a one-time global setting, not a per-root one.
#
# The framework itself ships only the two conf-driven guards, pre-commit and
# pre-push. Anything opinionated about commit CONTENT - a message
# rewriter, a template, a linter - belongs in a personal repo rather than
# in a framework other people install: carrying the file there IS the opt-in,
# which is why there is no flag to gate it with.
echo -e "${CYAN}Preparing global git hooks (memory staging guard + force-push guard)...${NC}"
mkdir -p "$HOME_DIR/.git-hooks" "$HOME_DIR/.git-templates/hooks"

# Record whatever global git config is about to be replaced, so an uninstall
# can restore it rather than only unset it.
PREV_GIT_CONFIG="$HOME_DIR/.claude/git-config.previous"
record_previous() {
  local key="$1" want="$2" old
  old="$(git config --global --get "$key" 2>/dev/null || true)"
  if [ -n "$old" ] && [ "$old" != "$want" ]; then
    mkdir -p "$HOME_DIR/.claude"
    printf '%s=%s\n' "$key" "$old" >> "$PREV_GIT_CONFIG"
    echo -e "  ${RED}! global $key was '$old'; replacing it (old value recorded in $PREV_GIT_CONFIG)${NC}"
  fi
}
record_previous core.hooksPath "$HOME_DIR/.git-hooks"
record_previous init.templateDir "$HOME_DIR/.git-templates"
git config --global core.hooksPath "$HOME_DIR/.git-hooks"
git config --global init.templateDir "$HOME_DIR/.git-templates"
echo "  core.hooksPath: $(git config --global --get core.hooksPath)"
echo "  ok"
echo ""

# ── Session hooks (memory sync / commit / doctor notice) ─────
# Independent of the repo choice, so a later `--memory-repo` run only has to
# write the path file.
echo -e "${CYAN}Installing portable AI-memory sync...${NC}"
mkdir -p "$HOME_DIR/.claude/hooks"
install_file "$SCRIPT_DIR/claude-setup/config/hooks/ai-memory-sync.sh" "$HOME_DIR/.claude/hooks/ai-memory-sync.sh"
# The write half of sync: SessionEnd commits memory (no network), SessionStart
# pushes it on the next run. Split that way so ending a session is never slower.
install_file "$SCRIPT_DIR/claude-setup/config/hooks/ai-memory-commit.sh" "$HOME_DIR/.claude/hooks/ai-memory-commit.sh"
# The doctor notice: one throttled line from `memory-doctor --brief` at
# SessionStart, nothing when the stores are clean. It runs memory-doctor.js
# from THIS checkout, located through ~/.claude/sunstone-path (the hook itself
# is a copy, so its own location says nothing).
install_file "$SCRIPT_DIR/claude-setup/config/hooks/memory-doctor-notice.sh" "$HOME_DIR/.claude/hooks/memory-doctor-notice.sh"
printf '%s\n' "$SCRIPT_DIR" > "$HOME_DIR/.claude/sunstone-path"
# Register the SessionStart + SessionEnd hooks in ~/.claude/settings.json
# (idempotent, non-destructive: existing entries are kept). The file is backed
# up first; the backup is dropped again if the merge turned out to be a no-op.
# Every path is double-quoted inside the command: a home directory with a
# space in it must still run.
MERGE_HOOK="$SCRIPT_DIR/claude-setup/config/merge-ai-memory-hook.py"
HOOK_SYNC_CMD="bash \"$HOME_DIR/.claude/hooks/ai-memory-sync.sh\""
HOOK_DOCTOR_CMD="bash \"$HOME_DIR/.claude/hooks/memory-doctor-notice.sh\""
HOOK_COMMIT_CMD="bash \"$HOME_DIR/.claude/hooks/ai-memory-commit.sh\""
print_manual_hooks() {
  echo "  add these to $SETTINGS by hand:"
  echo "      SessionStart: $HOOK_SYNC_CMD"
  echo "      SessionStart: $HOOK_DOCTOR_CMD"
  echo "      SessionEnd:   $HOOK_COMMIT_CMD   (async)"
}
if command -v python3 >/dev/null 2>&1; then
  settings_bak="$(snapshot_settings)"
  merge_ok=1
  # One call per hook; the third argument only labels the log line.
  python3 "$MERGE_HOOK" "$SETTINGS" "$HOOK_SYNC_CMD" ai-memory-sync || merge_ok=0
  python3 "$MERGE_HOOK" "$SETTINGS" "$HOOK_DOCTOR_CMD" memory-doctor-notice || merge_ok=0
  settle_settings_backup "$settings_bak"
  if [ "$merge_ok" = "1" ]; then
    echo "  ok"
  else
    echo -e "  ${RED}! could not auto-register the hooks; $SETTINGS may be incomplete${NC}"
    print_manual_hooks
  fi
else
  echo "  ! python3 not found;"
  print_manual_hooks
fi
echo ""

# ── Install roots: this checkout, then the personal repo (the overlay) ─────
#
# The personal memory repo MAY carry the same relative layout as this checkout
# - skills/, agents/, config/, plugins/, claude-setup/commands/,
# claude-setup/config/{agents,hooks,settings.json,CLAUDE.global.md} - and it is
# then applied as a SECOND install root, after this one, with identical rules.
# Whatever both roots ship, the personal copy lands last and wins. This
# checkout may ship none of these trees (the framework carries no skills, and
# only the two supermode commands); then only the personal root contributes. --skip-overlay applies
# this checkout only.
#
# Each step is one function taking the root as its argument; it prints
# "<step>: from <root>" or "<step>: skipped" and records what it installed for
# the summary at the end.

# The overlay root: the repo resolved above, or - with --skip-memory or when
# nothing was passed and no terminal asked - the repo already recorded in
# ~/.claude/ai-memory-path (or ~/.ai-memory, the hooks' own fallback).
OVERLAY_ROOT=""
if [ "$SKIP_OVERLAY" != "1" ]; then
  if [ -n "$MEMORY_REPO" ]; then
    OVERLAY_ROOT="$MEMORY_REPO"
  else
    # Canonicalised before the guard below can compare it: the recorded path is
    # user-editable, so a trailing slash or a symlinked spelling of THIS
    # checkout would otherwise slip past a raw string comparison and the
    # framework would be installed twice, once as each root. `cd && pwd` is
    # what setup.ps1's Resolve-Path does.
    OVERLAY_ROOT="$(read_path_file "$PATH_FILE")"
    if [ -n "$OVERLAY_ROOT" ] && [ -d "$OVERLAY_ROOT" ]; then
      OVERLAY_ROOT="$(cd "$OVERLAY_ROOT" && pwd)"
    else
      OVERLAY_ROOT=""
    fi
    [ -z "$OVERLAY_ROOT" ] && [ -e "$HOME_DIR/.ai-memory/.git" ] && OVERLAY_ROOT="$HOME_DIR/.ai-memory"
  fi
  # The memory repo IS this checkout: one root, not the same one twice.
  [ "$OVERLAY_ROOT" = "$SCRIPT_DIR" ] && OVERLAY_ROOT=""
fi

INSTALLED=""   # comma list of the steps that installed something from the current root
OVERRIDDEN=0   # files of the current step that a later root ships too
LAST_ROOT=""   # the root applied last; set before the roots are applied
CLAUDE_GLOBAL_ANY=0   # 1 when any root ships claude-setup/config/CLAUDE.global.md
step_done() {  # <step> <root> [detail]
  echo "  $1: from $2${3:+ ($3)}"
  INSTALLED="${INSTALLED:+$INSTALLED, }$1"
}
step_skip() { echo "  $1: skipped"; }
# step_end <step> <root> <count> <detail> - the one line every step prints.
step_end() {
  local step="$1" root="$2" n="$3" detail="$4"
  if [ "$n" -gt 0 ]; then
    [ "$OVERRIDDEN" -gt 0 ] && detail="$detail; $OVERRIDDEN overridden by the personal root"
    step_done "$step" "$root" "$detail"
  elif [ "$OVERRIDDEN" -gt 0 ]; then
    echo "  $step: skipped ($OVERRIDDEN overridden by the personal root)"
  else
    step_skip "$step"
  fi
  OVERRIDDEN=0
}

# ship <root> <rel> <dst> [x] - install <root>/<rel> at <dst> (executable with
# "x") unless a LATER root ships the same <rel>: the last root wins without the
# earlier copy landing first, which would back the file up on every run.
# Returns 0 installed, 1 not shipped by this root, 2 overridden.
ship() {
  local root="$1" rel="$2" dst="$3" mode="${4:-}"
  [ -f "$root/$rel" ] || return 1
  if [ "$root" != "$LAST_ROOT" ] && [ -f "$LAST_ROOT/$rel" ]; then
    OVERRIDDEN=$((OVERRIDDEN + 1))
    return 2
  fi
  if [ "$mode" = "x" ]; then install_file "$root/$rel" "$dst"; else install_copy "$root/$rel" "$dst"; fi
}

# ship_dir <root> <rel-dir> <dst-dir> <glob> [x] - ship every matching regular
# file of <root>/<rel-dir> into <dst-dir>; leaves the number installed in
# SHIPPED (a variable, not stdout: a subshell would lose the OVERRIDDEN count).
SHIPPED=0
ship_dir() {
  local root="$1" rel="$2" dst="$3" glob="$4" mode="${5:-}" f
  SHIPPED=0
  for f in "$root/$rel"/$glob; do
    [ -f "$f" ] || continue
    if ship "$root" "$rel/$(basename "$f")" "$dst/$(basename "$f")" "$mode"; then SHIPPED=$((SHIPPED + 1)); fi
  done
}

# skills/<name>/ → ~/.codex/skills, ~/.config/opencode/skills, ~/.claude/skills
# (each <name> replaced whole - a skill is a tree, not a file to diff - and a
# name the later root also ships is left to that root).
step_skills() {
  local root="$1" n=0 d name dest
  for d in "$root"/skills/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    if [ "$root" != "$LAST_ROOT" ] && [ -d "$LAST_ROOT/skills/$name" ]; then
      OVERRIDDEN=$((OVERRIDDEN + 1)); continue
    fi
    for dest in "$HOME_DIR/.codex/skills" "$HOME_DIR/.config/opencode/skills" "$CLAUDE_DIR/skills"; do
      mkdir -p "$dest"
      # ⚠️ A skill is replaced WHOLE (rm -rf + cp -r) rather than merged: a
      # merge would strand files that an older version of the skill shipped
      # and the new one dropped. That makes this the one step that can destroy
      # work, because an existing <name>/ here is not necessarily an earlier
      # copy of ours - it may be a skill the user wrote by hand under the same
      # name. So back it up first. Only when it DIFFERS, so re-running an
      # unchanged tree still leaves no .bak clutter, exactly like install_file.
      if [ -d "$dest/$name" ] && ! diff -rq "${d%/}" "$dest/$name" >/dev/null 2>&1; then
        backup "$dest/$name"
      fi
      rm -rf "${dest:?}/$name"
      cp -r "${d%/}" "$dest/$name"
    done
    n=$((n + 1))
  done
  step_end skills "$root" "$n" "$n → ~/.codex/skills, ~/.config/opencode/skills, ~/.claude/skills"
}

# agents/AGENTS.md → ~/AGENTS.md ; agents/CLAUDE.md → ~/CLAUDE.md + ~/.claude/CLAUDE.md
# (a differing existing file is backed up beside itself). Claude Code reads
# user-level instructions from ~/.claude/CLAUDE.md; a file at the home root is
# only picked up as a project-parent file when a project lives directly under
# $HOME. A CLAUDE.global.md shipped by either root takes ~/.claude/CLAUDE.md
# instead - see step_claude_global.
step_agents() {
  local root="$1" got="" n=0
  if ship "$root" agents/AGENTS.md "$HOME_DIR/AGENTS.md"; then
    got="AGENTS.md → ~/AGENTS.md"; n=$((n + 1))
  fi
  if ship "$root" agents/CLAUDE.md "$HOME_DIR/CLAUDE.md"; then
    n=$((n + 1))
    if [ "$CLAUDE_GLOBAL_ANY" = "1" ]; then
      got="${got:+$got, }CLAUDE.md → ~/CLAUDE.md (~/.claude/CLAUDE.md comes from CLAUDE.global.md)"
    else
      install_copy "$root/agents/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
      got="${got:+$got, }CLAUDE.md → ~/CLAUDE.md, ~/.claude/CLAUDE.md"
    fi
  fi
  step_end agents "$root" "$n" "$got"
}

# config/codex-config.toml, codex-hooks.json, codex-AGENTS.md, codex-rules/ → ~/.codex/
step_codex() {
  local root="$1" got="" n=0 r
  if ship "$root" config/codex-config.toml "$HOME_DIR/.codex/config.toml"; then got="config.toml"; n=$((n + 1)); fi
  if ship "$root" config/codex-hooks.json "$HOME_DIR/.codex/hooks.json"; then got="${got:+$got, }hooks.json"; n=$((n + 1)); fi
  if ship "$root" config/codex-AGENTS.md "$HOME_DIR/.codex/AGENTS.md"; then got="${got:+$got, }AGENTS.md"; n=$((n + 1)); fi
  ship_dir "$root" config/codex-rules "$HOME_DIR/.codex/rules" '*'; r="$SHIPPED"
  if [ "$r" -gt 0 ]; then got="${got:+$got, }$r rules"; n=$((n + r)); fi
  step_end codex "$root" "$n" "$got → ~/.codex"
}

# config/opencode-config.jsonc → ~/.config/opencode/opencode.jsonc ; plugins/*.js → ~/.opencode/plugins/
step_opencode() {
  local root="$1" got="" n=0 p
  if ship "$root" config/opencode-config.jsonc "$HOME_DIR/.config/opencode/opencode.jsonc"; then
    got="opencode.jsonc → ~/.config/opencode"; n=$((n + 1))
  fi
  ship_dir "$root" plugins "$HOME_DIR/.opencode/plugins" '*.js'; p="$SHIPPED"
  if [ "$p" -gt 0 ]; then got="${got:+$got, }$p plugins → ~/.opencode/plugins"; n=$((n + p)); fi
  step_end opencode "$root" "$n" "$got"
}

# claude-setup/commands/*.md → ~/.claude/commands/
step_commands() {
  local root="$1" n
  ship_dir "$root" claude-setup/commands "$CLAUDE_DIR/commands" '*.md'; n="$SHIPPED"
  step_end commands "$root" "$n" "$n → ~/.claude/commands"
}

# claude-setup/config/agents/*.md → ~/.claude/agents/ - nothing in Claude Code
# switches the main model on a condition, so subagent files are the mechanism
# for "escalate this kind of work to a stronger model".
step_subagents() {
  local root="$1" n
  ship_dir "$root" claude-setup/config/agents "$CLAUDE_DIR/agents" '*.md'; n="$SHIPPED"
  step_end subagents "$root" "$n" "$n → ~/.claude/agents"
}

# claude-setup/config/hooks/* → ~/.claude/hooks/ (executable). Scripts are only
# COPIED here, never registered: the framework's memory hooks are registered
# by setup.sh, anything else - a personal hook in particular - by the
# settings.json of the root that ships it (step_settings).
# claude-setup/config/git-hooks/* → ~/.git-hooks/ and ~/.git-templates/hooks/.
# An overlay step like every other one: whatever both roots ship, the personal
# copy lands last and wins, and a guard only the personal repo carries is
# installed from there alone. That is what lets a policy hook live in a
# personal repo instead of being gated by a flag in this one.
step_git_hooks() {
  local root="$1" f name n=0
  for f in "$root"/claude-setup/config/git-hooks/*; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    # The later root ships this same guard: it wins, so skip it here.
    if [ "$root" != "$LAST_ROOT" ] && [ -f "$LAST_ROOT/claude-setup/config/git-hooks/$name" ]; then
      OVERRIDDEN=$((OVERRIDDEN + 1)); continue
    fi
    # ⚠️ An existing ~/.git-hooks/$name that differs is REPLACED (backed up
    # first by install_file). record_previous says nothing when core.hooksPath
    # already pointed here, so this is the only place the user learns their own
    # hook logic has just stopped running. Both shipped guards exec
    # <repo>/.git/hooks/$name at the end, so that is where such logic belongs;
    # the backup is what to move.
    if [ -e "$HOME_DIR/.git-hooks/$name" ] && ! cmp -s "$f" "$HOME_DIR/.git-hooks/$name"; then
      echo -e "  ${YELLOW}! $HOME_DIR/.git-hooks/$name exists and differs; replacing it (backup kept beside it).${NC}"
      echo    "    if that was your own hook rather than an earlier copy from this framework, its logic"
      echo    "    no longer runs: move it into <repo>/.git/hooks/$name - the shipped $name chains to it."
    fi
    install_file "$f" "$HOME_DIR/.git-hooks/$name"
    # Keep the clone-time template in step, as a fallback if core.hooksPath is
    # ever unset by hand.
    install_file "$f" "$HOME_DIR/.git-templates/hooks/$name"
    n=$((n + 1))
  done
  step_end git-hooks "$root" "$n" "$n → ~/.git-hooks, ~/.git-templates/hooks"
}

step_hooks() {
  local root="$1" n
  ship_dir "$root" claude-setup/config/hooks "$CLAUDE_DIR/hooks" '*' x; n="$SHIPPED"
  step_end hooks "$root" "$n" "$n → ~/.claude/hooks (copied, not registered)"
}

# claude-setup/config/supermode.settings.json → ~/.claude/supermode.settings.json and
# claude-setup/bin/supermode → ~/.local/bin/supermode. Supermode is opt-in per
# launch: the launcher layers that file onto ONE session with `claude --settings`,
# so auto-compaction off and the context guard never enter ~/.claude/settings.json.
# The guard and gauge scripts arrive with step_hooks, the /supermode and /supercode
# commands with step_commands.
step_supermode() {
  local root="$1" got="" n=0
  if ship "$root" claude-setup/config/supermode.settings.json "$CLAUDE_DIR/supermode.settings.json"; then
    got="settings → ~/.claude/supermode.settings.json"; n=$((n + 1))
  fi
  if ship "$root" claude-setup/bin/supermode "$HOME_DIR/.local/bin/supermode" x; then
    got="${got:+$got, }launcher → ~/.local/bin/supermode"; n=$((n + 1))
    case ":$PATH:" in
      *":$HOME_DIR/.local/bin:"*) ;;
      *) echo "    note: ~/.local/bin is not on PATH - add it, or run ~/.local/bin/supermode by path" ;;
    esac
  fi
  step_end supermode "$root" "$n" "$got"
}

# claude-setup/config/settings.json → MERGED into ~/.claude/settings.json by
# the template merger, never copied over it (a wholesale copy would discard
# the hooks setup.sh registered and the permissions you have approved). The
# merger appends a hook only if no entry under that event already runs the
# same script (matched by basename, so `~/.claude/hooks/x` and an absolute
# spelling count as one), copies statusLine / env keys only when absent, never
# touches permissions, and leaves '~' in commands as written. The personal
# root's merge runs after the framework's because the roots are applied in
# that order.
step_settings() {
  local root="$1" tpl="$root/claude-setup/config/settings.json" bak
  [ -f "$tpl" ] || { step_skip settings; return 0; }
  # The .py and .mjs mergers are two ports of one tool applying identical
  # rules, so either interpreter will do: a node-only machine used to lose the
  # whole template merge even though the port it needs ships beside the other.
  local runner="" script=""
  if command -v python3 >/dev/null 2>&1 && [ -f "$MERGER" ]; then
    runner="python3"; script="$MERGER"
  elif command -v node >/dev/null 2>&1 && [ -f "$MERGER_JS" ]; then
    runner="node"; script="$MERGER_JS"
  else
    echo "  settings: skipped (no python3 or node with a merger beside it - merge $tpl into $SETTINGS by hand)"
    return 0
  fi
  bak=""
  [ "$SETTINGS_PREEXISTED" = "1" ] && bak="$(snapshot_settings)"
  if "$runner" "$script" "$SETTINGS" "$tpl" | sed 's/^/    /'; then
    step_done settings "$root" "merged into $SETTINGS"
  else
    echo "  ! settings: merge of $tpl failed; merge it into $SETTINGS by hand"
  fi
  settle_settings_backup "$bak"
}

# claude-setup/config/CLAUDE.global.md → ~/.claude/CLAUDE.md. The last root
# that ships one wins, and it beats agents/CLAUDE.md for this one destination.
step_claude_global() {
  local root="$1" n=0
  if ship "$root" claude-setup/config/CLAUDE.global.md "$CLAUDE_DIR/CLAUDE.md"; then n=1; fi
  step_end CLAUDE.global.md "$root" "$n" "→ ~/.claude/CLAUDE.md"
}

# claude-setup/config/statusline-command.sh → ~/.claude/.
#
# ⚠️ The framework ships NO statusline. A statusline is a preference, not part
# of a memory layer, so this is an overlay slot: a personal root that carries
# claude-setup/config/statusline-command.sh gets it installed, and a root that
# does not simply reports `skipped`. The settings template no longer names a
# statusLine key either - the two must travel together or you get the bug this
# framework shipped for a while, where every session ran a statusline command
# that did not exist. A personal root that wants one ships both: the script
# here, and the statusLine key in its own settings.json, merged after this one.
#
# The shell script wants `jq` at runtime; hence the note when it is missing.
step_statusline() {
  local root="$1" f got="" n=0
  for f in statusline-command.sh; do
    if ship "$root" "claude-setup/config/$f" "$CLAUDE_DIR/$f" x; then got="${got:+$got, }$f"; n=$((n + 1)); fi
  done
  step_end statusline "$root" "$n" "$got → ~/.claude"
  if [ "$n" -gt 0 ] && ! command -v jq >/dev/null 2>&1; then
    echo "    note: the statusline reads its input with jq; without jq it renders empty"
  fi
}

apply_root() {  # <label> <root>
  local label="$1" root="$2"
  INSTALLED=""
  echo -e "${CYAN}Installing from the $label root: $root${NC}"
  step_statusline "$root"
  step_skills "$root"
  step_agents "$root"
  step_codex "$root"
  step_opencode "$root"
  step_commands "$root"
  step_subagents "$root"
  step_hooks "$root"
  step_supermode "$root"
  step_git_hooks "$root"
  step_settings "$root"
  step_claude_global "$root"
  echo ""
}

LAST_ROOT="${OVERLAY_ROOT:-$SCRIPT_DIR}"
for r in "$SCRIPT_DIR" "$OVERLAY_ROOT"; do
  [ -n "$r" ] && [ -f "$r/claude-setup/config/CLAUDE.global.md" ] && CLAUDE_GLOBAL_ANY=1
done
apply_root framework "$SCRIPT_DIR"
INSTALLED_FRAMEWORK="$INSTALLED"
INSTALLED_PERSONAL=""
if [ -n "$OVERLAY_ROOT" ]; then
  apply_root personal "$OVERLAY_ROOT"
  INSTALLED_PERSONAL="$INSTALLED"
fi

# ── Verify ───────────────────────────────────────

echo -e "${GREEN}========================================"
echo " Setup Complete!"
echo -e "========================================${NC}"
echo ""
echo "Installed:"
# Listed from what is actually on disk rather than from a fixed name list:
# which guards land now depends on what each root ships, so a hardcoded list
# would go stale the moment a personal repo carries one of its own.
gh_live="$(ls "$HOME_DIR/.git-hooks" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
echo "  git hooks:     $HOME_DIR/.git-hooks/{${gh_live:-none}} (core.hooksPath) + $HOME_DIR/.git-templates/hooks"
echo "  session hooks: $HOME_DIR/.claude/hooks/{ai-memory-sync,ai-memory-commit,memory-doctor-notice}.sh"
echo "  framework:     $SCRIPT_DIR  (recorded in $HOME_DIR/.claude/sunstone-path for the doctor notice)"
echo ""

echo "Install roots:"
echo "  framework: $SCRIPT_DIR"
echo "    installed: ${INSTALLED_FRAMEWORK:-nothing (this checkout ships none of the optional trees)}"
if [ -n "$OVERLAY_ROOT" ]; then
  echo "  personal:  $OVERLAY_ROOT"
  echo "    installed: ${INSTALLED_PERSONAL:-nothing (the repo carries none of the optional trees)}"
elif [ "$SKIP_OVERLAY" = "1" ]; then
  echo "  personal:  skipped (--skip-overlay)"
else
  echo "  personal:  none (no personal repo recorded; its skills/, agents/, config/, plugins/ and"
  echo "             claude-setup/{commands,config} would be installed after the framework's)"
fi
echo ""

echo "Memory:"
if [ -n "$MEMORY_REPO" ]; then
  mem_file="$(conf_get "$MEMORY_REPO" MEMORY_FILE claude-setup/memory/ABOUT-ME.md)"
  mem_dir="$(conf_get "$MEMORY_REPO" MEMORY_DIR claude-setup/memory)"
  echo "  personal repo: $MEMORY_REPO  (recorded in $PATH_FILE)"
  if [ -f "$MEMORY_REPO/$mem_file" ]; then
    echo "  injected file: $mem_file"
  elif [ -f "$MEMORY_REPO/$mem_dir/MEMORY.md" ]; then
    echo "  injected file: $mem_dir/MEMORY.md  (MEMORY_FILE $mem_file not found; using the index)"
  else
    echo "  injected file: none yet - create $mem_file in the repo and the hook picks it up next session"
  fi
  echo "  memory tree:   $mem_dir  (the SessionEnd hook commits only this path)"
  echo "  optional config: $MEMORY_REPO/claude-setup/config/sunstone.conf"
else
  echo "  no personal repo recorded; hooks are installed and stay silent until"
  echo "  $PATH_FILE points at a git repo (or ~/.ai-memory is one)."
  echo "  re-run:  bash setup.sh --memory-repo <git-url-or-path>"
  echo "  optional config: <personal-repo>/claude-setup/config/sunstone.conf"
fi
cat <<'CONF'
  config keys (KEY=VALUE, all optional; defaults shown):
    MEMORY_DIR=claude-setup/memory              tree the SessionEnd hook may commit
    MEMORY_FILE=claude-setup/memory/ABOUT-ME.md file injected into every session
    MEMORY_INDEX=claude-setup/memory/MEMORY.md  index memory-doctor checks
    MEMORY_REPOS="<repo-name>"                  repos with the mixed-staging guard
    GUARDED_REPOS="sunstone <repo-name>"        repos with the force-push guard
    MEMORY_META_FILES=""                        files in MEMORY_DIR that are structure, not memories
    PROJECT_ROOTS=""                            dirs projects live under (memory-doctor slug resolution)
    QUEUE_FILE=""                               a markdown work queue; set, memory-doctor checks its NOW table
    QUEUE_NOW_HEADING=""                        its NOW heading (default: the first H2 containing "NOW")
    QUEUE_NOW_MAX=3                             rows the NOW table may hold
CONF
echo ""
echo "Restart Claude Code to pick up the hooks."
