#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# OPTIONAL Claude Code extras installer - lays down the pieces beyond the
# memory layer: the statusline, skills, agents, Codex / OpenCode configs,
# slash commands, subagents, hook scripts, a global CLAUDE.md and the
# settings.json template (merged, never copied over yours).
#
# It reads TWO install roots, in this order, with identical rules for both:
#   1. the framework checkout this script lives in;
#   2. the personal memory repo recorded in ~/.claude/ai-memory-path (or
#      ~/.ai-memory), when it carries the same relative layout - the overlay.
# Whatever both roots ship, the personal copy lands last and wins. The
# framework may ship none of the optional trees (it carries no skills, and
# only the two supermode commands); then only the personal root contributes.
#
# Run from anywhere:  bash claude-setup/install.sh [--skip-overlay]
# Idempotent. Backs up anything it would change to *.bak.<timestamp> (an
# identical file is left alone, so a re-run leaves no clutter).
# Does NOT touch credentials - run `claude login` separately.
#
# The entry point for the documented feature - the portable memory layer
# (personal repo → ~/.claude/ai-memory-path, the SessionStart/SessionEnd sync
# hooks, the memory-doctor notice, the global git guards) - is setup.sh at the
# repo root:  bash setup.sh --memory-repo <git-url-or-path>
# setup.sh applies the same two roots itself, so after a full setup this
# script has nothing new to do; it exists for re-applying the extras alone.
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK="$(cd "$HERE/.." && pwd)"
HOME_DIR="${HOME:?}"
CLAUDE_DIR="$HOME_DIR/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
MERGER="$FRAMEWORK/claude-setup/config/merge-settings-template.py"
MERGER_JS="$FRAMEWORK/claude-setup/config/merge-settings-template.mjs"
# Whether the user had a settings.json before this run. Both roots merge the
# template, and the framework's merge CREATES the file when there was none; so
# without this flag the personal root's merge would "back up" an intermediate
# state the user never wrote - a .bak nobody would ever want restored, left
# behind in a HOME that started clean. setup.sh keeps the same flag for the
# same reason (there it is the hook registration that creates the file).
SETTINGS_PREEXISTED=0
[ -f "$SETTINGS" ] && SETTINGS_PREEXISTED=1

SKIP_OVERLAY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-overlay) SKIP_OVERLAY=1; shift ;;
    -h|--help)
      echo "usage: bash claude-setup/install.sh [--skip-overlay]"
      echo "  --skip-overlay   install the framework's trees only; ignore the personal repo's"
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ── Helpers (same rules as setup.sh) ──────────────

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

# install_copy <src> <dst> - copy <src> over <dst>; a differing <dst> is
# backed up first, an identical one is left alone.
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

# read_path_file <file> - first line, TRIMMED (a path may contain spaces).
read_path_file() {
  [ -f "$1" ] || return 0
  head -n1 "$1" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

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
      # This mirrors setup.sh's step_skills deliberately: the two installers
      # write the same destinations, and a file that survives one installer and
      # is destroyed by the other is the worst kind of surprise.
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
step_hooks() {
  local root="$1" n
  ship_dir "$root" claude-setup/config/hooks "$CLAUDE_DIR/hooks" '*' x; n="$SHIPPED"
  step_end hooks "$root" "$n" "$n → ~/.claude/hooks (copied, not registered)"
}

# claude-setup/config/supermode.settings.json → ~/.claude/supermode.settings.json,
# claude-setup/bin/supermode → ~/.local/bin/supermode. Opt-in per launch: the
# launcher layers the file onto ONE session with `claude --settings`; nothing
# here touches ~/.claude/settings.json. Same step as setup.sh's.
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

# claude-setup/config/statusline-command.sh → ~/.claude/. The settings.json
# template merged from the same root points its statusLine key at it, so the
# script and the key always travel together; setup.sh installs it the same way
# for the same reason. It reads its input with jq and renders empty without it.
step_statusline() {
  local root="$1" n=0
  if ship "$root" claude-setup/config/statusline-command.sh "$CLAUDE_DIR/statusline-command.sh" x; then n=1; fi
  step_end statusline "$root" "$n" "statusline-command.sh → ~/.claude (needs jq)"
}

apply_root() {  # <label> <root>
  local label="$1" root="$2"
  INSTALLED=""
  echo "==> $label root: $root"
  step_statusline "$root"
  step_skills "$root"
  step_agents "$root"
  step_codex "$root"
  step_opencode "$root"
  step_commands "$root"
  step_subagents "$root"
  step_hooks "$root"
  step_supermode "$root"
  step_settings "$root"
  step_claude_global "$root"
  echo ""
}

# ── Roots ─────────────────────────────────────────

echo "==> Target: $CLAUDE_DIR"
mkdir -p "$CLAUDE_DIR/hooks"

# The personal root: the repo recorded in ~/.claude/ai-memory-path, else
# ~/.ai-memory when it is a git repo ([ -e ], because in a worktree .git is a
# file). Never the framework itself twice.
OVERLAY_ROOT=""
if [ "$SKIP_OVERLAY" != "1" ]; then
  # Canonicalised before the guard below can compare it: the recorded path is
  # user-editable, so a trailing slash or a symlinked spelling of THIS
  # checkout would otherwise slip past a raw string comparison and the
  # framework would be installed twice, once as each root. `cd && pwd` is
  # what setup.ps1's Resolve-Path does, and what setup.sh does here too.
  OVERLAY_ROOT="$(read_path_file "$CLAUDE_DIR/ai-memory-path")"
  if [ -n "$OVERLAY_ROOT" ] && [ -d "$OVERLAY_ROOT" ]; then
    OVERLAY_ROOT="$(cd "$OVERLAY_ROOT" && pwd)"
  else
    OVERLAY_ROOT=""
  fi
  [ -z "$OVERLAY_ROOT" ] && [ -e "$HOME_DIR/.ai-memory/.git" ] && OVERLAY_ROOT="$HOME_DIR/.ai-memory"
  # The memory repo IS this checkout: one root, not the same one twice.
  [ "$OVERLAY_ROOT" = "$FRAMEWORK" ] && OVERLAY_ROOT=""
fi

LAST_ROOT="${OVERLAY_ROOT:-$FRAMEWORK}"
for r in "$FRAMEWORK" "$OVERLAY_ROOT"; do
  [ -n "$r" ] && [ -f "$r/claude-setup/config/CLAUDE.global.md" ] && CLAUDE_GLOBAL_ANY=1
done
apply_root framework "$FRAMEWORK"
INSTALLED_FRAMEWORK="$INSTALLED"
INSTALLED_PERSONAL=""
if [ -n "$OVERLAY_ROOT" ]; then
  apply_root personal "$OVERLAY_ROOT"
  INSTALLED_PERSONAL="$INSTALLED"
fi

# ── Summary ───────────────────────────────────────

# Project auto-memory lives under ~/.claude/projects/<slug>/memory/, and the
# slug is derived from the project's REAL working-directory path - copy memory
# into a guessed slug and Claude never loads it. So nothing is copied there
# from here. Durable memory is the personal repo that setup.sh records in
# ~/.claude/ai-memory-path; the SessionStart hook injects it on every machine.
echo "==> Install roots"
echo "  framework: $FRAMEWORK"
echo "    installed: ${INSTALLED_FRAMEWORK:-nothing (this checkout ships none of the optional trees)}"
if [ -n "$OVERLAY_ROOT" ]; then
  echo "  personal:  $OVERLAY_ROOT"
  echo "    installed: ${INSTALLED_PERSONAL:-nothing (the repo carries none of the optional trees)}"
elif [ "$SKIP_OVERLAY" = "1" ]; then
  echo "  personal:  skipped (--skip-overlay)"
else
  echo "  personal:  none - no personal memory repo recorded yet; run:"
  echo "             bash $FRAMEWORK/setup.sh --memory-repo <git-url-or-path>"
fi

cat <<'NEXT'

==> DONE (files in place). Remaining MANUAL steps (see SETUP.md):
  1. claude login                         # auth - credentials are NOT bundled
  2. Verify: jq (statusline) and node (>= 20) are on PATH
     (the settings template merger runs under python3 when present, node otherwise)
  3. Restart Claude Code

  OPTIONAL - third-party plugins. Nothing installed here needs them; the
  CLAUDE.md rules that mention context-mode are written to be ignored when it
  is absent. Install them only if you want those tools:
     /plugin marketplace add mksglu/context-mode
     /plugin marketplace add anthropics/claude-plugins-official
     /plugin install context-mode@context-mode
     /plugin install typescript-lsp@claude-plugins-official
     # then `ctx doctor` checks that context-mode is healthy
NEXT
