# Setup runbook

How `setup.sh` / `setup.ps1` wire the sunstone memory layer into Claude Code on one machine,
what lands where, how to verify it, what to do when it goes quiet - and why every piece is
shaped the way it is. The README is the front door: what this is, what to type, and the smallest
true mental model. This file is everything behind it, and it is meant to be read by section
rather than end to end.

Throughout, the example memory repo is `my-memory`, owned by `alice`.

---

## TL;DR

```bash
# 0. Prerequisites below: git (required), sh, Claude Code; python3 and node
#    recommended. The framework ships no statusline, so nothing here needs jq.
# 1. Get the framework (the URL shown on this repository's page; fork only to change it)
git clone https://github.com/<owner>/sunstone sunstone && cd sunstone
# 2. Install, naming your memory repo by a URL this machine can already authenticate to
./setup.sh --memory-repo git@github.com:alice/my-memory.git    # or https://github.com/alice/my-memory.git
# 3. Restart Claude Code, then verify
node claude-setup/scripts/memory-doctor.js
```

### Flags

| `setup.sh` | `setup.ps1` | Meaning |
|---|---|---|
| `--memory-repo <url-or-path>`, `--memory-repo=<url-or-path>` | `-MemoryRepo` | The memory repo. A git URL (`scheme://` or `user@host:`) is cloned; anything else is a local path (`~` allowed) to a clone you already have, used in place - it must be a directory and a git repo, or setup stops **before writing anything** and says `nothing has been installed`. Also read from `SUNSTONE_MEMORY_REPO`; the flag wins. |
| `--clone-to <dir>`, `--clone-to=<dir>` | `-CloneTo` | Where a URL is cloned. Both default to `~/.ai-memory`, the one path every hook also tries when `~/.claude/ai-memory-path` is missing. An existing clone at the destination is reused; a non-git directory there is an error (again before anything is installed). Ignored, with a printed notice rather than silently, when the memory repo you gave is a local path - there is nothing to clone. |
| `--skip-memory` | `-SkipMemory` | Do not touch `~/.claude/ai-memory-path` at all. The hooks are still installed. |
| `--skip-overlay` | `-SkipOverlay` | Install from the framework root only; ignore any skills, commands, agents, hooks or `settings.json` template the memory repo carries. See [The overlay](#the-overlay-your-own-skills-commands-and-hooks). |
| `-h`, `--help` | the comment header at the top of `setup.ps1` | Usage. |

The memory repo is the only setting with an environment form (`SUNSTONE_MEMORY_REPO`); the
others are `SUNSTONE_PUSH_TIMEOUT` for the SessionEnd push and the two guard overrides,
`ALLOW_MIXED_COMMIT` and `ALLOW_FORCE_PUSH`, none of which setup reads. With no repo given,
`setup.sh` running in a terminal asks for one - Enter keeps the clone already recorded in
`~/.claude/ai-memory-path`, or skips when there is none. Without a terminal it keeps the recorded
clone, or skips and prints the `--memory-repo` re-run line; the hooks are installed either way.
The session hooks and the mixed-staging guard stay silent until `ai-memory-path` (or
`~/.ai-memory`) names a git repo - but `pre-push` does not: it guards a repo whose remote
basename is `sunstone` even on a machine with no memory repo and no config at all, so the
framework's own force-push protection never silently vanishes on a half-set-up box.

Order matters and is deliberate: the memory repo is resolved **first** - cloned, or checked to
be a git repo - and only then does setup touch the global git config, `~/.git-hooks` or
`~/.claude`. A typo in the URL or a missing SSH key therefore exits 1 with the machine exactly as
it was; the message says `nothing has been installed`, and there is nothing to roll back.

---

## Platforms

`setup.sh` is for Linux, macOS and WSL; `setup.ps1` is for native Windows ([Windows](#windows)).
A WSL checkout is a Linux checkout and needs nothing special - run `setup.sh` inside WSL, and
`setup.ps1` on the Windows side only if you also run Claude Code natively there.

What each platform is missing by default is covered row by row in [Prerequisites](#prerequisites)
below; the short version is that macOS ships neither `python3` nor `timeout` and both have a
fallback, and Windows ships no `python3` so the session hooks install as Node ports.

✅ **Verified where, honestly:** all four platforms are exercised end to end - Windows first on
2026-09-11, under **PowerShell 7** (`setup.ps1` does not parse under Windows PowerShell 5.1), and
macOS on 2026-09-12 (Apple Silicon, `/bin/bash` 3.2, Xcode's `git`/`python3`): every step landed,
`memory-doctor` 0 errors, memory injected on the first session. [Verify](#verify) is still what
to check after a first run on any new machine.

⛔ **`setup.ps1` does not parse under Windows PowerShell 5.1** - the `powershell` that ships with
Windows. It needs `pwsh` (PowerShell 7), which is a separate install. It is the first thing to hit
anyone who runs `powershell -ExecutionPolicy Bypass -File setup.ps1`, so use `pwsh` in its place;
[Windows](#windows) says where to get it.

## Prerequisites

| Tool | Needed for | Notes |
|---|---|---|
| **git** | everything | Any recent version, and a **hard** requirement: `setup.sh` checks for it before it prints its banner and exits 1 with `! git is required and was not found on PATH; nothing has been installed.` when it is absent - every step that follows needs git, and a missing one used to surface as a bare `git: command not found` halfway through, after the hook files had landed. **`setup.ps1` refuses identically** - the same check, before its own banner, throwing `git is required and was not found on PATH; nothing has been installed.` On Windows the silent-failure mode was the worse of the two: its `Invoke-GitQuiet` helper swallows the "command not found" exception and leaves `$LASTEXITCODE` holding some earlier command's status, so a clone that never happened could read as success and the run would carry on against a directory that is not there. Hooks resolve the repo name from `git remote get-url origin`, falling back to the worktree's directory name where there is no `origin` - see [`sunstone.conf` reference](#sunstoneconf-reference). The memory repo URL must be one this machine can already authenticate to - an SSH key for `git@github.com:` URLs, a credential helper or token for `https://` ones; `git ls-remote <url>` is the quick check. `setup.sh` clones before it writes anything else, so an auth failure stops it with `nothing has been installed`; re-run with a working URL. |
| **POSIX `sh`** | the git hooks and the Claude Code hooks on Linux/macOS/WSL | Present everywhere but Windows, where Git for Windows supplies it. |
| **Claude Code** | the SessionStart / SessionEnd hooks | https://claude.com/claude-code - install and `claude login` before running setup. |
| **python3** | the JSON `additionalContext` envelope in the sync and notice hooks; registering the three memory hooks in `settings.json` | Optional on Linux, but registration is the one step of setup with no Node fallback: `merge-ai-memory-hook.py` has no port, so without `python3` setup prints the three commands to add by hand - see [Registering the hooks by hand](#registering-the-hooks-by-hand) - and the hooks themselves fall back to plain stdout, which Claude Code also adds to context. |
| **node** | `memory-doctor` and the doctor notice hook; the `settings.json` **template** merge when there is no `python3`; all hooks on Windows | Optional on Linux (the notice hook exits silently without it); required on Windows. A node-only machine is no longer a machine that loses the template merge: `setup.sh` runs `merge-settings-template.mjs` when `python3` is missing, so the template's own hooks still land. |
| **jq** | nothing the framework ships | **Not a dependency of this framework.** It appears here only because the statusline *slot* is a real one: if **your** memory repo ships `claude-setup/config/statusline-command.sh`, setup installs it and prints a note when `jq` is missing, because that shell script reads its input with `jq` and renders an empty line without it. A framework-only install never puts a statusline on disk and never needs `jq`. |

`setup.sh` itself has no other dependencies: no `jq`, no package manager, and no network access
after the clone except to clone the memory repo. No `timeout` binary is needed either - the sync
hook prefers `timeout`, then `gtimeout`, and where a machine has neither (stock macOS, or a hook
running under a stripped `PATH`) it becomes the watchdog itself, backgrounding git and killing it
on time, so a dead network still cannot hang a session start.

---

## What setup installs

`setup.sh` is idempotent: a file that is already identical is left alone, one that differs is
backed up beside the original as `<file>.bak.<timestamp>` before it is replaced. It never
touches credentials. Steps run in this order: memory repo, global git hooks, session hooks and
their registration, then the overlay steps for each root (framework first, memory repo second).
This is the complete list of what it writes:

⚠️ **The skills step replaces a whole directory rather than merging it, and the backup promise
covers that too.** A skill is a directory, not a file to diff, so `~/.claude/skills/<name>` (and
its `~/.codex` and `~/.config/opencode` twins) is deleted with `rm -rf` and re-copied whole - a
merge would strand files an older version of the skill shipped and the new one dropped. Because
an existing `<name>/` there may be a skill **you** wrote by hand rather than an earlier copy of
setup's, it is backed up beside itself first whenever it differs from what is about to replace
it. An identical one is left alone, so re-running an unchanged tree still leaves no `.bak`
clutter - the same rule the per-file copy helper applies.

| Target | Source in this repo | Purpose |
|---|---|---|
| `~/.claude/ai-memory-path` | written from `--memory-repo` / `SUNSTONE_MEMORY_REPO` / the prompt | One line: the absolute path of the memory repo clone. The two memory hooks read it, fall back to `~/.ai-memory` when it is missing, and exit silently only when neither is a git repo. Not written with `--skip-memory` or when no repo was given. |
| the memory repo clone | `git clone` of the URL you gave, into `~/.ai-memory` or `--clone-to` | Only when a URL was given and no clone exists there yet. A local path is used in place and nothing is cloned. |
| `~/.claude/hooks/ai-memory-sync.sh` | `claude-setup/config/hooks/ai-memory-sync.sh` | SessionStart: pull, push last session's commits, inject `MEMORY_FILE`. |
| `~/.claude/hooks/ai-memory-commit.sh` | `claude-setup/config/hooks/ai-memory-commit.sh` | SessionEnd: commit `MEMORY_DIR` by path, then fire a detached, time-bounded `git push` (`SUNSTONE_PUSH_TIMEOUT`, default 20s) and return without waiting for it. Skipped outright when the branch has no upstream; a rejected push is normal and silent, and the next SessionStart pulls and pushes properly. |
| `~/.claude/hooks/memory-doctor-notice.sh` | `claude-setup/config/hooks/memory-doctor-notice.sh` | SessionStart: a throttled notice from `memory-doctor --brief` - a summary line plus up to three WARN lines - or nothing. |
| `~/.claude/sunstone-path` | the directory `setup.sh` was run from | One line: the framework checkout. The notice hook runs `memory-doctor.js` from there, because the hook itself is a copy and cannot find the checkout from its own location. Move or delete the checkout and the notice goes quiet - nothing else this framework installs breaks. ⛔ **But check what else on your machine points into that directory before you move it.** A checkout is not self-describing: things outside it can name it, and neither `git status` nor this repo will mention them. On one machine `%APPDATA%\Zed` turned out to be a junction into `<checkout>/config/zed`, so the editor was reading and writing inside the working tree - renaming the directory would have silently reverted a live setting, and deleting it would have taken the whole editor config. Look for symlinks and junctions (`Get-Item <path> -Force` on Windows and read `LinkType`/`Target`; `ls -l` on POSIX) as well as path files, before you move anything. |
| `~/.claude/settings.json` | merged by `claude-setup/config/merge-ai-memory-hook.py`, needs `python3` | Adds `ai-memory-sync.sh` and `memory-doctor-notice.sh` under `SessionStart` and `ai-memory-commit.sh` (async) under `SessionEnd`, each only if not already present. Every other key and hook is kept. Backed up first; the backup is removed again when the merge changed nothing. This is the one step with no Node fallback - without `python3` the three commands are printed instead, and the template merge two rows down still runs. |
| `~/.git-hooks/pre-commit`, `~/.git-hooks/pre-push` | `claude-setup/config/git-hooks/` | The mixed-staging guard and the force-push guard. |
| `~/.git-hooks/<name>`, `~/.git-templates/hooks/<name>` | `claude-setup/config/git-hooks/<name>` under **either root** | Overlay step. The framework ships `pre-commit` and `pre-push`; the personal repo may ship more, or replace either by carrying the same filename - its copies install last and win. This is where a hook that is a *policy* rather than a guard belongs: carrying the file is the opt-in, so no flag gates it and nobody else inherits it. |
| `~/.git-templates/hooks/` | the same files as `~/.git-hooks/` | Clone-time template, a fallback if `core.hooksPath` is ever unset by hand. |
| global git config | `core.hooksPath=~/.git-hooks`, `init.templateDir=~/.git-templates` | Makes the guards reach every repo on the machine, including ones that already exist. |
| `~/.claude/git-config.previous` | appended by `setup.sh` | If either git setting already had a different value, the old `key=value` is recorded here (and printed in red) so [Uninstall](#uninstall) can restore it. |
| `~/.claude/statusline-command.sh` | `claude-setup/config/statusline-command.sh` under either root | Overlay step, `chmod +x`, and the **first** one to run - but **the framework ships no statusline**, so from the framework root this step always reports `skipped` and nothing is written. It is a slot: a memory repo that carries the script gets it installed, and must also carry the `statusLine` key in its own `claude-setup/config/settings.json` so the two arrive together. See [What the framework deliberately does not ship](#what-the-framework-deliberately-does-not-ship). |
| `~/.claude/skills/<name>`, `~/.codex/skills/<name>`, `~/.config/opencode/skills/<name>` | `skills/<name>/` under either root | Overlay step. The framework ships no skills; these come from the memory repo. ⚠️ Each `<name>` is **replaced whole** (`rm -rf` then `cp -r`), never merged, in all three destinations; one that differs from the incoming tree - a hand-written skill of the same name included - is backed up beside itself first, and an identical one is left untouched. And when both roots ship the same `<name>`, the framework's copy is not installed at all: the step reports it as `overridden by the personal root` and only the memory repo's tree lands. |
| `~/AGENTS.md`, `~/CLAUDE.md` | `agents/AGENTS.md`, `agents/CLAUDE.md` under either root | Overlay step; an existing file is backed up first. Neither is shipped by the framework today. `~/.claude/CLAUDE.md` is **not** written from here: it comes from `claude-setup/config/CLAUDE.global.md` (last row), and only falls back to `agents/CLAUDE.md` if no root ships a `CLAUDE.global.md` at all - which, since the framework ships one, does not happen in practice. |
| `~/.codex/config.toml`, `~/.codex/hooks.json`, `~/.codex/AGENTS.md`, `~/.codex/rules/` | `config/codex-config.toml`, `codex-hooks.json`, `codex-AGENTS.md`, `codex-rules/` under either root | Overlay step, Codex CLI configuration. **The framework ships none of these**, so from the framework root this step always reports `skipped`; it is a slot for your memory repo to fill if you use Codex. |
| `~/.config/opencode/opencode.jsonc`, `~/.opencode/plugins/*.js` | `config/opencode-config.jsonc`, `plugins/*.js` under either root | Overlay step, OpenCode configuration. **The framework ships neither half** - no `opencode.jsonc` and no `plugins/` directory at all - so from the framework root this step always reports `skipped`. Both are slots for your memory repo. |
| `~/.claude/commands/*.md` | `claude-setup/commands/*.md` under either root | Overlay step, slash commands. The framework ships two, `supermode.md` and `supercode.md` - the procedures behind [Supermode](#supermode); a memory repo carrying the same filename replaces either. |
| `~/.claude/agents/*.md` | `claude-setup/config/agents/*.md` under either root | Overlay step, subagent files; the framework ships `architect.md` and `verify.md`. Both pin `model: sonnet` in their frontmatter, the mid tier. Nothing in Claude Code switches the main model on a condition, so a subagent file is the mechanism for "escalate this kind of work to a different model", and these two exist to be escalated to; they are installed by a framework a stranger runs sight-unseen, so the default is the tier that does not surprise a bill. To raise it, carry your own `architect.md` / `verify.md` in your memory repo's `claude-setup/config/agents/` with the `model:` line you want (`opus`, `fable`) - the overlay installs last and the same filename wins. Delete the two files from `~/.claude/agents/` if you want neither. |
| `~/.claude/hooks/*` | `claude-setup/config/hooks/*` under either root | Overlay step, `chmod +x`. Copied only: a memory-repo hook is registered solely by the memory repo's `settings.json` template. From the framework root this lands the two supermode scripts too, `ctx-gauge.mjs` and `context-guard.mjs` - registered by `supermode.settings.json` (next two rows), never by `settings.json`. |
| `~/.claude/supermode.settings.json` | `claude-setup/config/supermode.settings.json` under either root | Overlay step, plain copy. The settings a supermode session runs under - `autoCompactEnabled: false`, `statusLine` → `ctx-gauge.mjs`, `PostToolUse` → `context-guard.mjs`. Reaches a session only through the launcher's `claude --settings`; it is never merged into `~/.claude/settings.json`. See [Supermode](#supermode). |
| `~/.local/bin/supermode` | `claude-setup/bin/supermode` under either root | Overlay step, `chmod +x`. The launcher: `SUPERMODE=1 exec claude --settings ~/.claude/supermode.settings.json "$@"`. Setup notes when `~/.local/bin` is not on `PATH`; it does not edit your shell profile. On Windows the twin is `claude-setup\bin\supermode.ps1` → `~\.claude\bin\supermode.ps1`. |
| `~/.claude/settings.json` (again) | `claude-setup/config/settings.json` under either root, via `merge-settings-template.py` - or `merge-settings-template.mjs` under `node` when there is no `python3` | Overlay step, after the memory-hook registration above. Framework template merged first, memory repo's second; see [The template merger](#the-template-merger). The framework's template contributes exactly three hook entries and no other key: a `PreToolUse` hint on `Bash`, and two `SessionStart` entries, `context-mode-cache-heal.mjs` and `session-bus-notice.js` (inert until `BUS_DIR` is set). Because this merge runs after the memory hooks were registered, the bus notice lands after `ai-memory-sync` in the `SessionStart` list. It carries **no `statusLine` and no `env`** - those are preferences, and belong in your own template, which is merged after this one. Skipped, with a note, only when the machine has neither interpreter. |
| `~/.claude/CLAUDE.md` | `claude-setup/config/CLAUDE.global.md` under either root | Overlay step - but the framework ships this file, so **a plain `setup.sh` writes it on every run, `--skip-overlay` included**. A `~/.claude/CLAUDE.md` of your own is replaced, backed up first as `CLAUDE.md.bak.<timestamp>`; a memory repo that carries its own copy wins over the framework's. Keep anything you want to survive a re-run in the memory repo's copy, not in the installed file. |

`setup.sh` creates the target directories it needs if they do not exist. It installs no
packages.

### Supermode

Supermode is unattended work - the session keeps going after you have left, with the
checkpoints that make that safe - and it is **opt-in per launch**, which is why it does not
appear in `~/.claude/settings.json` at all. `supermode [args...]` runs
`SUPERMODE=1 claude --settings ~/.claude/supermode.settings.json [args...]`; that file layers
three things onto the one session:

- **`autoCompactEnabled: false`.** Compaction is the largest single request of a session and
  returns a summary without the numbers. A supermode session hands off to a fresh one instead.
- **`statusLine` → `ctx-gauge.mjs`.** Claude Code gives the context percentage to the status
  line and to nothing else, and the model cannot see it. The gauge reads the status-line JSON,
  writes `~/.claude/ctx/<session_id>.pct`, then runs your own status line on the same input
  (`~/.claude/statusline-command.sh`, `.js`, `.mjs`, or `$SUPERMODE_STATUSLINE`) and prints its
  output - or a one-line `supermode · ctx NN% · <model> · <dir>` when you have none.
- **`PostToolUse` → `context-guard.mjs`.** After every tool call: read the gauge (fresh within
  10 minutes; otherwise estimate from the transcript's last `usage` over `SUPERMODE_CTX_WINDOW`,
  default 200000, and say so); from `SUPERMODE_CTX_PCT` (default 70), once per 5% band, inject
  hook context telling the model to checkpoint - finish the slice at a green gate, commit, write
  the handoff, start the successor, stop, do not compact. Exits at once unless `SUPERMODE=1`.

The procedure itself is the `/supermode` command; `/supercode` is its companion for fanning
work out over concurrent agents. Both are ordinary command files under
`~/.claude/commands/` - replace either from your memory repo by shipping the same filename.
The successor a session starts is `supermode --bg --permission-mode auto "supermode: resume"`
from the repo root, so `~/.local/bin` (or the `.ps1` on Windows) must be on `PATH` for the
session that runs it - setup prints a note when it is not.

Verify: `SUPERMODE=1 SUPERMODE_CTX_PCT=1 supermode -p "run one Bash tool call, then say whether
you received hook context mentioning 'supermode context guard'" --max-turns 3` - a
one-shot session with the threshold forced to 1% answers yes and quotes the notice. The
`.pct` gauge is not written in `-p` mode (no status line renders), so that run exercises the
transcript estimate; an interactive `supermode` session exercises the gauge. With `--skip-overlay`, or when neither root carries a tree, the overlay steps print
`skipped` and write nothing; the framework root has no `skills/`, `commands/` or `agents/` at
the top level, so a bare framework install leaves `~/.claude/skills/` and `~/.claude/commands/`
untouched.

### What the framework deliberately does not ship

Three things used to be installed from this root and are not any more, and the reason is the same
one in all three cases: **they are preferences, not the memory layer.** A framework a stranger
clones and runs should not decide what their prompt looks like, how another tool updates itself,
or which third-party CLIs they are told to reach for. They now live in a personal repo and
arrive through [the overlay](#the-overlay-your-own-skills-commands-and-hooks), where carrying the
file is the opt-in and nobody inherits anyone else's taste - with one honest exception, noted in
the third bullet, that still ships from this root.

- **The statusline.** `claude-setup/config/statusline.sh`, `statusline-command.sh` and
  `statusline-command.js` are gone from this repo. `step_statusline` still exists and still runs
  first, but from the framework root it always reports `skipped`. A memory repo that carries
  `claude-setup/config/statusline-command.sh` gets it installed exactly as before.
- **`env.DISABLE_AUTOUPDATER`.** The shipped `settings.json` template no longer sets it. Whether
  Claude Code updates itself is a decision about someone else's machine.
- **Guidance about third-party tools.** `CLAUDE.global.md` is now 27 lines - memory tiers, how to
  write a memory, session continuity - and nothing else. Its "Optional tools" sections about
  `context-mode` and `graphify` were removed: a memory layer has no business teaching an
  assistant about tools it does not install. The `plugins/` directory (and the OpenCode plugin
  in it) went the same way.

  ⚠️ **This one is not finished.** Two third-party hooks still ship from this root, in
  `claude-setup/config/settings.json`: a `PreToolUse` hint on `Bash` that points grep-style
  searches at `graphify-out/GRAPH_REPORT.md`, and a `SessionStart` entry running
  `context-mode-cache-heal.mjs`. The first injects prose about graphify into the model's context
  whenever a graph exists; the second requires `node` and a tool the framework does not install.
  Both are inert without their tool, but neither is the memory layer, and by the reasoning above
  both belong in a personal template rather than here. Delete the two entries from
  `~/.claude/settings.json` if you do not use those tools.

⚠️ **The `statusLine` key and the statusline script must ship from the same root.** This is not a
style rule; it is the most-reported bug in this repo's history. The framework's settings template
used to set `statusLine` to a script that another step - the *optional* `install.sh` - was
expected to install, so a plain `setup.sh` run ended with every single session executing a
command that did not exist. Whoever ships the key ships the file. That is why the framework, now
that it ships no statusline script, ships no `statusLine` key either, and why a memory repo that
wants one must put both in its own root. The Windows merger encodes the same rule in its
signature: see [Windows](#windows).

### Registering the hooks by hand

Without `python3`, `setup.sh` prints the three commands and registers nothing:
`merge-ai-memory-hook.py` has no Node port, so this one step has no fallback. It does **not**
follow that `settings.json` is left alone. The settings *template* merge later in the same run
does fall back to `node claude-setup/config/merge-settings-template.mjs`, so on a node-only
machine the file is still created and still gains the template's own hook entries - what is
missing is precisely the three memory hooks below, which is why the machine looks configured and
remembers nothing.

If `python3` is present but the merge script fails (an unparsable `settings.json` is the usual
cause), setup prints `! could not auto-register the hooks; <settings> may be incomplete`, prints
the same three commands, and carries on with the rest of the install. The
`settings.json.bak.<timestamp>` it took before trying is kept whenever the file ended up
different, and dropped again when it did not - so a backup left behind always means something
changed. Either way the shape to add by hand - merge these into any existing
`hooks` object rather than replacing it, and put your real home directory in place of `<home>`,
since the merge script writes absolute paths - is:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "bash <home>/.claude/hooks/ai-memory-sync.sh" } ] },
      { "hooks": [ { "type": "command", "command": "bash <home>/.claude/hooks/memory-doctor-notice.sh" } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "bash <home>/.claude/hooks/ai-memory-commit.sh", "async": true } ] }
    ]
  }
}
```

`"async": true` on the SessionEnd entry matters: it is what keeps ending a session from waiting
on the commit. `memory-doctor`'s wiring check accepts any command string that contains the hook's
filename under the right event, so a `~`-relative path passes too.

### The doctor notice hook

`memory-doctor-notice.sh` is the third hook `setup.sh` installs and registers. It needs `node`
and a framework checkout: it reads `~/.claude/sunstone-path` first, then falls back to its own
location (for a checkout that runs the hook in place) and to the memory repo (or a directory named
`sunstone` beside it), and gives up silently when none of those contains
`claude-setup/scripts/memory-doctor.js`. The doctor's own wiring check covers the two memory
hooks, not this one, so a broken notice hook is only visible as an absent notice. Disable it with
`touch ~/.claude/.memory-doctor-off`; its throttle stamp is `~/.claude/.memory-doctor-last`.

### The second installer: `install.sh`

`claude-setup/install.sh` is unrelated to the memory layer and optional. It walks the same two
roots as `setup.sh` (framework, then memory repo; `--skip-overlay` applies here too) and repeats
the same non-memory steps - **all ten** of them, the statusline slot included. On a machine where
`setup.sh` has already run it therefore changes nothing. Note what that looks like on screen - it
is not silence, and it is not ten `from framework` lines either. From the framework root only four
steps have a source file to copy at all - subagents, hooks, settings and `CLAUDE.global.md` - and
those print their ordinary `<step>: from <root>` line, because that line reports which root
supplied the files, not whether they were rewritten. The other six (statusline, skills, agents,
codex, opencode, commands) print `<step>: skipped` on every run, first or second alike, because
the framework ships nothing for them. The only step that says `no change` in so many words is the
settings merge, which prints it because the merger reports its own diff.

Do not use backup files to tell a first run from a second. A `*.bak.<timestamp>` appears only
where `install.sh` replaced a file that already existed **and differed** - so a clean first
install onto a machine with no `~/.claude` leaves none either, exactly like a no-op second run.
It exists for re-applying the extras alone. What it changes:

- **`~/.claude/CLAUDE.md` is replaced** by the root's `claude-setup/config/CLAUDE.global.md` -
  the shipped one is 27 lines and carries only the memory rules: which of the three tiers a fact
  belongs in, how to write one (edit the tree, do not commit - the hooks do that), and session
  continuity. The file you had is kept as `CLAUDE.md.bak.<timestamp>`
  (no backup when it was already identical). If the memory repo carries its own
  `CLAUDE.global.md`, that is the one that ends up in place. `setup.sh` performs this same step;
  `install.sh` only re-applies it.
- **`~/.claude/settings.json` is merged with the root's `claude-setup/config/settings.json`**
  through the [template merger](#the-template-merger). The shipped template contributes two hook
  entries and nothing else: a `PreToolUse` hook on `Bash` that points grep-style searches at
  `graphify-out/GRAPH_REPORT.md` when a graph exists, and a `SessionStart` entry for
  `context-mode-cache-heal.mjs`. Each lands only where you have nothing equivalent; there is no
  `statusLine` and no `env` key in it (see [What the framework deliberately does not
  ship](#what-the-framework-deliberately-does-not-ship)); `permissions` is never touched; a
  `settings.json.bak.<timestamp>` is kept when the merge changed something. Needs `python3`
  **or** `node` - the `.py` and `.mjs` mergers are two ports of one tool, so the step is skipped
  with a note only when neither interpreter is present. `setup.sh` merges the same template, so on
  a machine it has already run this step reports `no change`.
- **Copies** - the nine file-copying steps, run per root in this order, from the same sources
  `setup.sh` uses (they are nine of the eleven steps `install.sh` runs in a root; the settings
  merge and `CLAUDE.global.md`, the two bullets above, are the other two). `setup.sh` runs a
  twelfth step, `git-hooks`, that `install.sh` deliberately does not - see below.
  `claude-setup/config/statusline-command.sh` → `~/.claude/` - **a slot the framework leaves
  empty**, so this one reports `skipped` unless your memory repo fills it;
  `skills/<name>/` → `~/.claude/skills/<name>`, `~/.codex/skills/<name>` **and**
  `~/.config/opencode/skills/<name>`; `agents/AGENTS.md` → `~/AGENTS.md` and `agents/CLAUDE.md` →
  `~/CLAUDE.md`; the Codex tree - `config/codex-config.toml`, `config/codex-hooks.json`,
  `config/codex-AGENTS.md` and `config/codex-rules/*` → `~/.codex/config.toml`, `hooks.json`,
  `AGENTS.md` and `rules/`; the OpenCode tree - `config/opencode-config.jsonc` →
  `~/.config/opencode/opencode.jsonc` and `plugins/*.js` → `~/.opencode/plugins/` (the framework
  ships neither, so this one is a slot too);
  `claude-setup/commands/*.md` → `~/.claude/commands/`; `claude-setup/config/agents/*.md` →
  `~/.claude/agents/`; and every file of `claude-setup/config/hooks/` → `~/.claude/hooks/`,
  executable, `context-mode-cache-heal.mjs` among them. Each file that would be overwritten and
  differs is backed up as `<file>.bak.<timestamp>` first, the skills step included - its
  `step_skills` is byte-identical to `setup.sh`'s, so both installers back up a `<name>/` that
  differs from the incoming tree before replacing it whole.

  ⚠️ **A skill directory is replaced whole (`rm -rf` + `cp -r`), never merged**, in all three
  destinations. Merging would strand files an older version of the skill shipped and the new one
  dropped. That makes this the one step that can destroy work, because a `<name>/` already there
  is not necessarily an earlier copy of the shipped skill - it may be one **you wrote by hand**
  under the same name. Hence the backup, and hence it firing only when the trees differ, so
  re-running an unchanged one leaves no `.bak` clutter.

It copies the three memory hook *scripts* - its hooks step ships that whole directory, all six
files of it, exactly as `setup.sh` does - but it never **registers** them in `settings.json`, and
it writes neither `~/.claude/ai-memory-path` nor `~/.claude/sunstone-path`.
Registration comes from `setup.sh` alone. Running `install.sh` on its own therefore leaves the
memory hooks sitting on disk and inert, which is exactly the "installed and dead" state
`memory-doctor`'s wiring check exists to flag; run `setup.sh` for the memory layer. Both
installers write the same files from the same sources, so they can run in either order. Its
closing message asks you to check for `jq` and `node` and offers some Claude Code plugins. Read
both as optional: `jq` matters only if **your** root ships the shell statusline, since the
framework ships none, and nothing in this runbook needs the plugins.

### The template merger

`claude-setup/config/merge-settings-template.py` and `merge-settings-template.mjs` are two
identical ports of one tool, so a machine with only `node` (Windows) and one with only `python3`
behave the same:

```bash
python3 claude-setup/config/merge-settings-template.py ~/.claude/settings.json <template.json>
node    claude-setup/config/merge-settings-template.mjs ~/.claude/settings.json <template.json>
```

Rules, applied idempotently: for each event under the template's `hooks`, append each entry that
no entry under that event already runs - matched either by the **exact command string** or, when
the command names a script, by that **script's basename** (the same two-part identity rule
`merge-ai-memory-hook.py` uses, so a `~`-relative and an absolute path to one script count as one
hook, and the framework's own `PreToolUse` entry - an inline `python3 -c` pipeline naming no
script - is matched by its command string alone); copy `statusLine` and `env` keys only where the target has none, and likewise any other
top-level key whose template value is a **scalar** (`autoCompactEnabled: false`, say) - copied
only when the target lacks the key, so a value set by hand on a machine is never overridden;
objects and arrays other than those three are not copied, and `$comment` never is - a
capability the framework's own template never uses, since it carries none of them;
**never touch `permissions`**;
create `settings.json` when it does not exist; exit 0 and print one line per change, or
`no change`. Commands in a template may use `~` and are written as they are - Claude
Code expands them. `setup.sh` and `install.sh` call it once per root that carries a template,
with `python3` where that exists and `node` otherwise - which is why a node-only machine gets the
same merge rather than none. `setup.ps1` always uses `node`.

### The overlay: your own skills, commands and hooks

The memory repo may carry any of the trees the framework's layout defines, and setup applies it
as a second install root after the framework. The tree-by-tree list is the "under either root"
rows of [What setup installs](#what-setup-installs) above - every one of them reads from the
memory repo exactly as it reads from the framework. Operationally:

- Each overlay step prints `<step>: from <root>` for every root that has the tree, or `skipped`,
  and the final summary repeats the list per root.
- The framework root runs first, the memory repo second, so on a name clash the memory repo's
  copy is the one left on disk. It does **not** get there by overwriting the framework's: when a
  later root ships the same relative path, the earlier root's copy is **never installed at all**.
  The framework step reports it as `<step>: skipped (N overridden by the personal root)` - or
  appends `; N overridden by the personal root` when it installed other files in the same step -
  and only the memory repo's copy is written. That is deliberate: landing the framework's copy
  first and replacing it a moment later would back the file up on every single run, filling
  `~/.claude` with `.bak.<timestamp>` files that record nothing but setup's own two passes. A
  backup is still taken when the file **you** already had at the destination differs, which is the
  only overwrite worth recording.
- Hook scripts from `claude-setup/config/hooks/` are copied and made executable but **not
  registered**; the only thing that registers them is a `hooks` entry in the memory repo's
  `claude-setup/config/settings.json`, merged by the template merger after the framework's
  template. The memory hooks themselves are still registered by `merge-ai-memory-hook.py`, not
  by any template.
- A `claude-setup/config/CLAUDE.global.md` in the memory repo takes the place of the
  framework's wherever it is used.
- `--skip-overlay` / `-SkipOverlay` turns all of this off for one run and installs the framework
  root only; nothing previously installed from the memory repo is removed.

### About `core.hooksPath`

`init.templateDir` alone would not work: templates are copied at `git init` / `git clone` only,
so every repo that already exists would be untouched. `core.hooksPath` reaches existing repos
too, which is why it is used.

The trade-off: with a global `core.hooksPath` set, **git ignores each repo's own `.git/hooks`
directory**. Both installed hooks compensate by chaining to the repo-local hook of the same name
in **every** repo, guarded or not: `pre-push` with stdin buffered so the chained hook reads the
same ref list, and `pre-commit` on every exit path, so a husky or lint-staged `pre-commit` in an
unrelated project keeps running after setup. The header of
`claude-setup/config/git-hooks/pre-commit` states the rule:

> ⚠️ ALWAYS CHAINS, guarded repo or not. [...] If the unguarded repos exited here without
> chaining, running setup.sh would silently switch off every one of those hooks on the machine.
> So every exit path below goes through chain_local, exactly as pre-push does - the memory guard
> is an extra check in front of the repo's own hook, never a replacement for it.

The chain resolves the repo's hook through `git rev-parse --git-dir`, never `--git-path hooks`,
which obeys `core.hooksPath` and would make the hook exec itself. A hook of your own that lived
in `~/.git-hooks/` **under one of the shipped names** (`pre-commit`, `pre-push`) is a different
case: setup replaces it (backup beside it) and prints a warning, because its logic no longer runs;
move that logic into `<repo>/.git/hooks/<hook>`, where the chain reaches it. A hook of yours under
any other name - `commit-msg`, `prepare-commit-msg`, `post-checkout` - is left untouched there and
keeps running, since `core.hooksPath` now points git at that same directory.

A **global** `core.hooksPath` of your own is the third case and the widest one: setup replaces
the value, so every hook in your old directory stops running, in every repo, at once. Setup says
so in red and records the old `key=value` in `~/.claude/git-config.previous`, but nothing chains
to that directory - the chain only ever reaches `<repo>/.git/hooks/<hook>`. Copy the hooks you
still want out of it: into `~/.git-hooks/` under the same name to run *instead of* the shipped
one (setup backs up whatever it replaces there), or into `<repo>/.git/hooks/<hook>` in each repo
that needs them, where the shipped hooks chain to them. [Uninstall](#uninstall) restores the
recorded value.

A repo that sets its own `core.hooksPath` is not reached by the global hooks at all. Copy the
two files into that repo's hooks directory if you want the guards there.

---

## The memory repo

Any git repo you own. Setup needs its URL, or the path of a clone you already have - either goes
in `--memory-repo`. Minimum layout, using the defaults:

```
my-memory/
└── claude-setup/
    ├── config/
    │   └── sunstone.conf        # optional
    ├── session-start.d/         # optional - scripts run after every pull, on every machine
    │   └── 10-something.sh
    └── memory/
        ├── ABOUT-ME.md          # MEMORY_FILE - injected into every session
        ├── MEMORY.md            # MEMORY_INDEX - one line per memory file
        └── <topic>.md
```

Starting from nothing, with one topic file and one index line in the shape `memory-doctor`
expects (frontmatter `name` = filename, one-line `description`; index line = list item with a
markdown link - the **index** and **hygiene** rows of [Checking it still
works](#checking-it-still-works) are what enforce it):

```bash
mkdir my-memory && cd my-memory && git init
mkdir -p claude-setup/memory
printf '# About me\n\nOne paragraph on who I am and how I like to work.\n' > claude-setup/memory/ABOUT-ME.md
cat > claude-setup/memory/coding-style.md <<'EOF'
---
name: coding-style
description: How I format code and name things; applies in every repo.
---

# Coding style

Two-space indent, one exported symbol per file.
EOF
printf '# Memory index\n\n- [coding-style](coding-style.md) - how I format code and name things\n' > claude-setup/memory/MEMORY.md
git add -A && git commit -m "memory: initial store"
# Now create the remote - see the paragraph below; nothing so far has done it for you
git remote add origin git@github.com:alice/my-memory.git && git push -u origin HEAD
```

**The last line pushes to a repository that has to exist already.** `git remote add` only records
a URL locally; it does not create anything on the host, and `git push` to a URL that names no
repository fails with a message about the repository not being found - which reads like an auth
problem and is not one. So before that line, create an **empty** private repository on your host
under the name you are about to use (`my-memory` here), with no README, no `.gitignore` and no
licence - anything the host pre-populates it with becomes a divergent commit your first push has
to be talked past. On GitHub that is `gh repo create alice/my-memory --private` from the command
line, or "New repository" in the web UI with every "initialize with" box left unticked; other
hosts have the same option under a similar name. Private is the sensible default: this repo is
about to hold everything you tell Claude about yourself. The repo may also stay local and remoteless -
the guards still cover it under its directory name - but then nothing syncs between machines,
which is the whole point of the layer.

The branch needs an upstream. Without one, `memory-doctor` reports `sync` ERROR and the hooks
can neither pull nor push (they stay silent about it, which is the point of the doctor). A
plain-text index line such as `- coding-style.md - ...` is not a link and the doctor reports the
file as unindexed.

### session-start.d: scripts the memory repo runs on every machine

`claude-setup/session-start.d/` is optional. When it exists, `ai-memory-sync` runs every
`*.sh` in it (bash; the Node port also runs `*.js` / `*.mjs` under node) **after the pull and
before the injection**, from the repo root, sorted by name, each with a 60-second bound. Whatever
a script prints to stdout is appended to the injected context under `## session-start.d/<name>`;
stderr is dropped; a non-zero exit is silent and the next script still runs; an absent directory
costs nothing.

It exists for one reason: **a change committed on one machine should reach every other machine
without anyone typing anything there.** The pull already brings the files; this runs them. What
belongs here is small and idempotent - a per-machine migration runner that stamps what it has
done under `~/.claude/` and prints what it changed, a check that something is still wired - and
its output should tell the session what happened, or what it is being asked to do next. What
does not belong here is anything slow, interactive or surprising: the scripts run inside session
start, on every machine that clones the repo, as the user.

The framework ships nothing in this directory and never will; it is the memory repo's, like the
overlay. ⚠️ A script here runs with the user's full permissions on every machine that pulls the
repo - it is exactly as trusted as the repo's push access. Keep the memory repo private and its
branch protected accordingly.

### `sunstone.conf` reference

Location: `<memory-repo>/claude-setup/config/sunstone.conf`. Optional; every consumer works with
it absent.

Format: POSIX `KEY=VALUE`, one per line. **Whitespace around the `=` is accepted**, so
`MEMORY_DIR = notes` is valid and means what it looks like. Values may be double-quoted and the
quotes are stripped - a quoted value runs to the next `"`, so a `#` inside it is literal and
anything after the closing quote is ignored. Surrounding whitespace is trimmed, never deleted
from inside a value (a path may contain spaces). `#` begins a comment only at the start of a line
or after whitespace, so `MEMORY_DIR=notes#1` keeps its `#`, `MEMORY_DIR=notes # tree` does not,
and `MEMORY_DIR= #tree` is an empty value that falls back to the default. The last line for a key
wins; an empty value falls back to the default. It is never sourced, so a value cannot execute
anything.

**Nine readers parse this file and they now agree line for line**: `setup.sh`, `setup.ps1`, the
two git guards (`pre-commit`, `pre-push`), the two shell session hooks (`ai-memory-sync.sh`,
`ai-memory-commit.sh`), their two Node ports (`ai-memory-sync.js`, `ai-memory-commit.js`) and
`memory-doctor.js`. Shell greps `^[[:space:]]*KEY[[:space:]]*=`; the Node and PowerShell ports
split on the first `=` and trim the key. That agreement is the point rather than a detail: a
reader stricter than the hook it audits reports a live memory tree as empty, and a guard reading a
different `MEMORY_DIR` than the hook it guards goes quiet on exactly the tree being written.

⚠️ **`MEMORY_REPOS`, `GUARDED_REPOS`, `MEMORY_META_FILES` and `PROJECT_ROOTS` are
space-separated lists, so an entry containing a space cannot be expressed** - quoting does not
help, because the quotes delimit the whole value and every reader then splits what is inside on
whitespace. That is inherent to the format, not a bug in a reader, and there is no escape for it;
a repo or directory whose name contains a space cannot go in one of these lists. The one place
such a name still works is the *derived* default for `MEMORY_REPOS` / `GUARDED_REPOS`, which the
guards compare whole instead of splitting, precisely so a checkout at `~/my notes` is not left
unguarded by word-splitting.

| Key | Default | Consumed by |
|---|---|---|
| `MEMORY_DIR` | `claude-setup/memory` | `ai-memory-commit` (what gets staged), `pre-commit` (what counts as a memory path), `memory-doctor`. Relative to the memory repo. |
| `MEMORY_FILE` | `claude-setup/memory/ABOUT-ME.md` | `ai-memory-sync` (what gets injected). Relative to the memory repo. If absent, `MEMORY.md` inside `MEMORY_DIR` is tried; if that is absent too, nothing is injected and the hook exits 0. |
| `MEMORY_REPOS` | basename of the memory repo's `origin` URL, `.git` stripped - or of its checkout directory when it has no `origin` | `pre-commit`: the repos in which a commit mixing `MEMORY_DIR` paths with other paths is refused. Space-separated list, so a repo name containing a space cannot be listed. |
| `GUARDED_REPOS` | `sunstone <that same basename>` | `pre-push`: the repos in which a push that rewrites or deletes remote history is refused. Space-separated list, so a repo name containing a space cannot be listed. |
| `MEMORY_INDEX` | `claude-setup/memory/MEMORY.md` | `memory-doctor`: the index whose links are checked against the files in `MEMORY_DIR`. |
| `MEMORY_META_FILES` | empty | `memory-doctor` only: space-separated basenames inside `MEMORY_DIR` that are structure rather than memories (a template, a changelog). They are never reported as unindexed and never counted as memory files. The basenames of `MEMORY_INDEX` and `MEMORY_FILE`, plus `README.md`, are always treated this way, whether or not they are listed. Space-separated, so a filename containing a space cannot be listed; a value written with a directory part still counts by its basename. |
| `PROJECT_ROOTS` | empty | `memory-doctor` only: space-separated directories, `~` allowed, under which the doctor may look for `<project>/docs/ai-memory/` repo stores when a working-tier slug resolves to a project inside one of them. Empty keeps the slug resolution the doctor does today and adds no scanning. Space-separated, so a directory whose path contains a space cannot be listed. A listed directory that does not exist on this machine is reported as INFO, not an error - the same conf is meant to be shared across machines. |
| `QUEUE_FILE` | empty (check off) | `memory-doctor` only: a markdown work queue, relative to the memory repo. Set, it turns on the **queue** check - see [The work-queue check](../README.md#the-work-queue-check). |
| `QUEUE_NOW_HEADING` | empty | `memory-doctor` only: the H2 that opens the queue's NOW section, with or without the leading `## `. Empty: the first H2 whose text contains `NOW`, case-insensitive. |
| `QUEUE_NOW_MAX` | `3` | `memory-doctor` only: the rows the NOW table may hold before the doctor calls it a wish list. |
| `BUS_DIR` | unset (bus off) | `session-bus-notice.js`: the session-bus directory, relative to the memory repo, holding one `outbox-<side>.md` per machine - see [The session bus](../README.md#the-session-bus). |
| `BUS_SIDE` | detected: `windows`, `mac`, `wsl` or `linux` | `session-bus-notice.js`: this machine's side name, i.e. which outbox is its own and is never announced. |

Repo names are the basename of `git remote get-url origin` with `.git` stripped. The URL is
preferred over the directory name because a clone whose remote was renamed keeps living in a
folder called by the OLD name, so folder names lie. **Where there is no `origin` at all, both
derivations fall back to the worktree's directory name, and they fall back the same way** - which
is what makes a local-only memory repo guarded rather than silently unguarded:

- the *default* for `MEMORY_REPOS` / `GUARDED_REPOS` is the personal repo's `origin` basename, or
  its checkout directory's basename when it has no `origin`;
- `pre-commit` identifies the repo the commit is happening in the same way: `remote.origin.url`
  first, then `git rev-parse --show-toplevel`. So a memory repo you never gave a remote **is**
  guarded, under its directory name. (Earlier the two derivations disagreed: the derived default
  could never match an empty name, and a remote-less memory repo went unguarded.)
- `pre-push` has no such case. A push always names a remote, and the repo name is the basename of
  the URL git hands the hook - for a path remote, the basename of the path minus `.git`.

Example:

```sh
# sunstone.conf
MEMORY_DIR=notes
MEMORY_FILE=notes/ABOUT-ME.md
MEMORY_INDEX=notes/INDEX.md
MEMORY_REPOS="my-memory"
GUARDED_REPOS="sunstone my-memory team-notes"
MEMORY_META_FILES="TEMPLATE.md CHANGELOG.md"   # structure inside notes/, not memories
PROJECT_ROOTS="~/src ~/work"                   # where docs/ai-memory/ stores may be found
QUEUE_FILE=WORK-QUEUE.md                       # turns on the work-queue check
QUEUE_NOW_MAX=3
BUS_DIR=claude-setup/bus                       # turns on the session bus
```

### Guard semantics

⛔ **If you ever override `pre-push` and rewrite history, every old clone becomes an archive, not
just a stale copy - and git will tell you it is safe when it is not.** After the rewrite, the
commits an old clone holds are unreachable on the remote. `git log --branches --not --remotes`
reports nothing unpushed, which is *correct against its tracking ref* and *misleading*, because
the remote that ref names no longer contains those commits. "Everything is pushed" and "nothing
would be lost" stop being the same statement. Before deleting such a clone, confirm the history
survives **somewhere you can name** - a differently-named repo that was never force-pushed, or a
`git bundle create <file> --all` taken from the clone itself. Content living on in a successor
repo is not the same as history living on. This is a second-order cost of the override, which is
part of why the guard asks for it explicitly.

- **`pre-commit` in `MEMORY_REPOS`.** Staged paths are split into those under `MEMORY_DIR` and
  everything else. If both sets are non-empty the commit is refused with both lists printed and
  the fix spelled out (`git restore --staged <not yours>` then `git commit -- <MEMORY_DIR>`).
  Rename detection is off so that moving a file out of the memory tree counts as touching both.
  An empty staging area is allowed through (otherwise every `--amend` no-op would be refused).
  The initial commit of a repo, which has no `HEAD` to diff against, is diffed against the empty
  tree. Override for a genuinely single change: `ALLOW_MIXED_COMMIT=1 git commit ...`.
- **`pre-commit` stands down while git is mid-operation.** With `MERGE_HEAD`, `CHERRY_PICK_HEAD`,
  `REVERT_HEAD`, `REBASE_HEAD`, `rebase-merge` or `rebase-apply` present in the git dir, the
  staged set is one **git** composed - a merge, cherry-pick, revert or rebase - not a session
  running `git add -A`, so the failure this guard exists to catch cannot be what is happening.
  Refusing there would hand you a blocked commit halfway through resolving a conflict, for a
  commit you did not compose. The check is skipped and the repo's own hook still runs. These are
  the markers the SessionEnd commit hook tests too, so the two agree on what "git is busy" means
  (that hook drops `REVERT_HEAD` and adds a detached-HEAD refusal of its own - see
  [Troubleshooting](#troubleshooting)).
- **`pre-push` in `GUARDED_REPOS`.** For each ref being pushed: deleting a remote branch is
  refused; a brand-new branch passes; a remote tip not present locally is refused with "run
  `git fetch`"; otherwise the push is refused if the remote tip is not an ancestor of the local
  commit. Override: `ALLOW_FORCE_PUSH=1 git push ...`. Both hooks print the override in their
  refusal message, so the escape hatch is visible rather than something to go looking for.
- **Everywhere else** both hooks are no-ops as guards - but neither is a no-op as a hook: every
  exit path in both of them chains to `<repo>/.git/hooks/<name>`, which a global `core.hooksPath`
  would otherwise disable machine-wide. See [About `core.hooksPath`](#about-corehookspath).

---

## Verify

1. Restart Claude Code. Start a session anywhere. The contents of `MEMORY_FILE` should appear as
   background context (ask "what do you know about me?").
2. In the memory repo: `git log --oneline -3`. After a session that wrote a memory, a commit
   `memory: N file(s) from a session - ...` appears after the session ends and is normally pushed
   right away by the SessionEnd hook; if that push does not go through, the next SessionStart
   pulls and pushes it. A session writes there only if something has told it to, and that
   something is `~/.claude/CLAUDE.md` - installed from `claude-setup/config/CLAUDE.global.md`,
   whose 27 lines are what explain the memory tiers and the writing rules to the assistant. The
   hooks themselves never ask Claude to write anything; they only carry what it wrote.
3. `node claude-setup/scripts/memory-doctor.js` reports no ERROR.
4. `git config --global --get core.hooksPath` prints `~/.git-hooks` (expanded).
5. Force-push guard, against a throwaway **local** remote. The guard keys on the repo name, which
   for a path remote is the basename of the path minus `.git`, so name the bare repo after a
   guarded one (`sunstone` is guarded by default):
   ```bash
   d=$(mktemp -d) && git init -q --bare "$d/sunstone.git" && git clone -q "$d/sunstone.git" "$d/wc" && cd "$d/wc"
   git commit -q --allow-empty -m one && git commit -q --allow-empty -m two && git push -q -u origin HEAD
   git reset -q --hard HEAD~1 && git push --force        # refused with ⛔ pre-push
   ALLOW_FORCE_PUSH=1 git push --force                   # the override goes through
   cd - >/dev/null && rm -rf "$d"
   ```
   Do not run this against a real shared remote. If the guard is not reached - repo-local
   `core.hooksPath`, hooks not installed, a renamed remote, all cases described below - the
   force-push simply succeeds and rewrites history that other clones depend on.
6. Mixed-staging guard, the same way. `MEMORY_REPOS` defaults to your memory repo's name, so
   name the bare repo after it (`my-memory` here). This also exercises the no-`HEAD` initial
   commit path:
   ```bash
   d=$(mktemp -d) && git init -q --bare "$d/my-memory.git" && git clone -q "$d/my-memory.git" "$d/wc" && cd "$d/wc"
   mkdir -p claude-setup/memory && echo x > claude-setup/memory/note.md && echo y > other.txt
   git add -A && git commit -q -m mixed                  # refused with ⛔ pre-commit
   git rm -q --cached other.txt && git commit -q -m "memory: note"     # goes through
   cd - >/dev/null && rm -rf "$d"
   ```
   (`git rm --cached` instead of the `git restore --staged` the hook suggests, only because this
   scratch repo has no commit yet for `restore` to resolve `HEAD` against.)
7. Restart Claude Code once more. If the doctor found anything, the first session shows one
   "Memory-system status" line; if it found nothing, there is nothing to see, which is correct.

---

## Checking it still works

Every hook in the memory stack fails silently on purpose: a dead network must never block a
session. That is right for one session and wrong for a month. A machine can stop syncing, or a
memory can be written into the tier that syncs nowhere, and nothing ever says so.

```bash
node claude-setup/scripts/memory-doctor.js            # human report
node claude-setup/scripts/memory-doctor.js --verbose  # list every item
node claude-setup/scripts/memory-doctor.js --json     # machine-readable
node claude-setup/scripts/memory-doctor.js --brief    # a few lines, or nothing (what the notice hook uses)
```

Read-only: it never writes, moves, commits or deletes. Exit code is 1 when there is an ERROR, 0
otherwise, so it works as a pre-push or CI gate.

| Check | Catches |
|---|---|
| **wiring** | `ai-memory-path` missing or stale; a hook missing from `~/.claude/hooks/`, unregistered in `settings.json` (installed and dead), or drifted from the repo copy. |
| **sync** | No upstream, a large unpushed backlog, uncommitted memory writes, or a mid-rebase repo: every state in which the hooks quietly stop saving anything. |
| **index** | `MEMORY_INDEX` links pointing at files that do not exist, files with no index line, one file indexed twice. The index is what enters context; a dead link is a memory the assistant believes it has. |
| **hygiene** | Frontmatter `name` disagreeing with the filename, missing descriptions, `[[wikilinks]]` naming nothing. |
| **working-tier** | Files left in `~/.claude/projects/<slug>/memory/`, which syncs nowhere, with the store each one should be promoted to. |
| **repo-store** | `docs/ai-memory/` files never committed, or sitting outside a git repo. |
| **duplicates** | One slug living in two stores, and near-duplicates by name + description overlap. |
| **queue** | Off unless `QUEUE_FILE` is set: a NOW table longer than `QUEUE_NOW_MAX`, or a NOW row whose last cell carries an ISO date (or the word `yesterday`) that has passed. WARN only. |

The **wiring** check covers `ai-memory-sync` and `ai-memory-commit` (either the `.sh` or the
`.js` port counts as installed); it does not check the notice hook.

The SessionStart notice hook injects at most one notice per 20 hours - a summary line plus up to
three WARN lines, not a single line. The throttle bounds the *notice*, not the run: while the
stores are clean the doctor prints nothing and writes no stamp, so `--brief` is still executed on
every session start. It prints nothing when the stores are drained and the wiring is sound, so it retires itself
once the work is done. Disable it with `touch ~/.claude/.memory-doctor-off`; the stamp file is
`~/.claude/.memory-doctor-last`. See [The doctor notice hook](#the-doctor-notice-hook) for what
it needs in order to run.

---

## Updating

```bash
cd sunstone && git pull && ./setup.sh
```

**A `git pull` of this repo changes nothing that runs.** Every hook executes from a copy under
`~/.claude/hooks/`, `~/.git-hooks/` or `~/.git-templates/hooks/`. Until `setup.sh` runs again,
the installed copy is the old one, and the framework will look installed from every angle except
the one that matters. `memory-doctor`'s **wiring** check reports the drift as a WARN. If you do
not want to re-run the whole script, copy the changed file into place by hand and `chmod +x` it.

---

## Windows

```powershell
pwsh -ExecutionPolicy Bypass -File setup.ps1 -MemoryRepo git@github.com:alice/my-memory.git
```

⛔ **`pwsh`, not `powershell`.** PowerShell 7 is a separate install from the Windows PowerShell 5.1
that ships with the OS, and `setup.ps1` does not parse under 5.1. If you do not have it:
`winget install Microsoft.PowerShell`. Check with `pwsh -NoProfile -Command
'$PSVersionTable.PSVersion.ToString()'` - 7.x is what you want.

✅ **`setup.ps1` completed end to end on native Windows on 2026-09-11** - 44 skills across the
three roots, both git-hook trees, the settings merge and the memory wiring. That was its second
run. The **first** aborted partway, on a bug in this repo now fixed: `Get-TreeSignature` let
`Get-FileHash` throw, and under `$ErrorActionPreference = "Stop"` a single unreadable file killed
the whole install. It died on
`~\.codex\skills\agile-product-owner\agile-product-owner\SKILL.md` with *"The file cannot be
accessed by the system."*

⭐ **The unreadable files are WSL-created symlinks, and our own docs caused them.** Reparse tag
`0xA000001D` is `IO_REPARSE_TAG_LX_SYMLINK`; Win32 returns error 1920 because the tag is
Linux-specific. Git-bash resolves them, PowerShell cannot. They land on `C:` whenever a recursive
copy is run **from inside WSL** - which is the documented workaround for the 9P-share copy
failure. So any machine set up that way already has this residue, and the failing side is the
**destination**, not the clone. Cloning natively on `C:` is still right; it just cannot prevent
this. An unreadable file now folds into the signature as a sentinel, which reads as "differs" and
routes to backup-then-replace.

On the completing run, all eleven unreadable files were reported, backed up and replaced exactly
as intended - the residue is survivable, not blocking. Before a first run, still back these up
yourself rather than trusting the script - its own backup helper uses `-ErrorAction
SilentlyContinue` and can fail quietly:

- There is **no `-WhatIf`, no `-DryRun`, no `SupportsShouldProcess`**, and `$ErrorActionPreference
  = "Stop"`. It begins writing early and there is no safe partial invocation.
- It **force-overwrites `CLAUDE.md`** in two places - `$HomeDir\CLAUDE.md` and
  `$ClaudeDir\CLAUDE.md`.
- It runs **`Remove-Item -Recurse -Force`** on each skill directory before re-copying, across the
  three skill roots (`~\.codex\skills`, `~\.config\opencode\skills`, `~\.claude\skills`) - though
  a differing tree is backed up first, so this is replace-with-backup rather than plain deletion.
- It **rewrites `~/.claude/ai-memory-path`**.
- Its backup helper uses `Copy-Item -Recurse ... -ErrorAction SilentlyContinue`, so it **fails
  quietly** - and `Copy-Item -Recurse` over these paths is precisely the operation known to break
  on Windows. Do not rely on it.

⭐ **The fix worth building is a `-Prefix` parameter**, redirecting `$HomeDir` and the derived
paths at a scratch directory. That turns "does it run?" into a real end-to-end test anyone can run
on any machine with nothing of their own at risk, and it is the only thing that makes this claim
permanently verifiable instead of permanently inferred. Until that exists, **do not run
`setup.ps1` to find out whether it runs** - and be especially careful that the copy you are
looking at is the current one, since an older checkout installs an older generation over a working
setup.

`SUNSTONE_MEMORY_REPO` is honoured as well. Differences from the shell version - and, third
bullet, one thing that is deliberately *not* one, because this file used to claim it was:

- Windows ships neither `python3` nor a POSIX shell for Claude Code hooks, so the Claude Code
  hooks are installed as their Node ports, `ai-memory-sync.js` and `ai-memory-commit.js`, and
  Node is required. They read the same `ai-memory-path`, the same `sunstone.conf`, and behave
  identically. The doctor notice has no Node port shipped today, so `setup.ps1` installs the
  POSIX `memory-doctor-notice.sh` and registers it as `bash "...\memory-doctor-notice.sh"`, run by
  Git for Windows' shell; it prefers a `.js` port whenever one is shipped beside it.
  `memory-doctor` itself can always be run by hand.
- **Supermode on Windows** is the same two Node scripts (they have no shell dependency) plus
  `~\.claude\bin\supermode.ps1` in place of `~/.local/bin/supermode`; `setup.ps1` prints a note
  when `~\.claude\bin` is not on `PATH`. The layered file is the same
  `~\.claude\supermode.settings.json`, and `ctx-gauge.mjs` delegates to a
  `statusline-command.js` there exactly as it does to the `.sh` on POSIX. ⚠️ **`setup.ps1`'s
  supermode step is typed, not run** - this repo's Windows verification predates it; the POSIX
  step and both scripts are verified (see [Supermode](#supermode)).
- **The statusline is a slot on both platforms, and the framework fills neither.** *When a root
  ships* `claude-setup/config/statusline-command.js`, `setup.ps1` installs it to
  `~\.claude\statusline-command.js` and passes it to `claude-setup/config/merge-claude-settings.mjs`
  as an optional last argument, which then **sets** the `statusLine` key to it - replacing whatever
  was there - in the same call that registers the two memory hooks. From the framework root that
  argument is never passed, so the merger registers the hooks and writes no `statusLine`.
  `setup.sh` is the mirror image: `step_statusline` runs first and looks for
  `claude-setup/config/statusline-command.sh`, which the framework does not ship either, so the
  step reports `skipped` and nothing is written. There is likewise no template key to collide
  with - the shipped `settings.json` carries no `statusLine` at all. The rule that matters is
  unchanged: whoever ships the key ships the script, because a `statusLine` pointing at a file
  that is not on disk is a per-prompt error nobody asked for. A memory repo filling the slot on
  POSIX must ship the `statusLine` key in its own template too; on Windows `merge-claude-settings.mjs`
  sets it from the script path itself. The `.js` port needs no `jq`; the `.sh` one does.
- **`git` is a hard stop here too, exactly as it is in `setup.sh`.** `setup.ps1` checks for it
  before its banner and throws `git is required and was not found on PATH; nothing has been
  installed.` The two entry points refuse identically on purpose - on this side the alternative
  was worse than a bare error, because `Invoke-GitQuiet` swallows the missing-command exception
  and leaves `$LASTEXITCODE` holding an earlier command's status, so a clone that never ran could
  read as a success and the install would continue against a directory that does not exist.
  Install Git for Windows and re-run; there is nothing to clean up first.
- The summary can still say `git hooks: NOT installed` - but that line means something else: it
  appears in yellow when this **checkout** has no `claude-setup\config\git-hooks` directory to
  install from, not when `git` is absent. Read the parenthetical, and re-read the summary rather
  than assuming the guards are in place.
- A URL given to `-MemoryRepo` is cloned into `~\.ai-memory` unless `-CloneTo` says otherwise,
  the same default as `setup.sh`; both record the result in `ai-memory-path`. `-SkipMemory`,
  `-SkipOverlay` mirrors the shell flag, and the overlay steps walk the
  same two roots.
- The git hooks are POSIX `sh` scripts. Git for Windows runs hooks through its bundled shell, so
  they work unchanged; `core.hooksPath` is set the same way.
- `~/.claude/ai-memory-path` is written with forward slashes (`C:/dev/my-memory`), which
  both git and Node accept.
- A machine that runs both WSL and Windows Claude Code has two Claude homes and two installs.
  Each needs its own `setup` run and its own clone of the memory repo (or a shared clone reachable
  from both, recorded in each `ai-memory-path`). The sync hook's rebase path exists precisely so
  two writers to one memory repo converge instead of one silently stalling.

---

## Troubleshooting

**Nothing is injected at session start.** In order: does `~/.claude/ai-memory-path` exist and
name a directory with a `.git`? Does `MEMORY_FILE` (or `MEMORY.md` in `MEMORY_DIR`) exist there?
Is `ai-memory-sync.sh` registered under `SessionStart` in `~/.claude/settings.json` (the exact
shape is in [Registering the hooks by hand](#registering-the-hooks-by-hand))? Run the hook by
hand: `bash ~/.claude/hooks/ai-memory-sync.sh` should print a JSON envelope (or the file, if no
`python3`). `memory-doctor` asks all of these questions for you.

**The doctor notice never appears.** Run `node <framework>/claude-setup/scripts/memory-doctor.js
--brief`; empty output means there is nothing to say. Otherwise check that `~/.claude/sunstone-path`
names a checkout that still contains `claude-setup/scripts/memory-doctor.js`, that `node` is
resolvable from a non-interactive shell (an nvm shell function is not), that
`~/.claude/.memory-doctor-off` does not exist, and that `~/.claude/.memory-doctor-last` is older
than 20 hours (delete it to force a notice).

**Memory changes are never committed.** The SessionEnd hook stages only `MEMORY_DIR`. A file
written elsewhere in the repo is deliberately left alone. It also refuses outright, silently, in
three states, and the files simply stay on disk for the next session to commit:

- mid-merge, mid-rebase or mid-cherry-pick - `ls $(git rev-parse --git-dir) | grep -iE 'merge|rebase|cherry'`
  - because committing into that state makes a mess a human then has to unpick;
- on a **detached HEAD**, because a commit made there is on no branch: check a branch back out and
  the session's memory is gone from the tree, with no branch for the sync hook to push either.
  `git -C <memory-repo> symbolic-ref -q HEAD` prints nothing when you are in this state. (An
  unborn branch before the first commit is fine.)
- when `git commit` itself fails - no committer identity, a signing key a non-interactive hook
  cannot unlock, a locked index. The hook then **unstages the memory tree again** rather than
  leaving it staged: those causes outlast the session, and staging left behind would be swept
  into your next unrelated commit in that repo, or refused outright by the framework's own
  mixed-staging guard.

**Commits are made but never reach the remote.** Pushing is attempted at both ends: opportunistically
at SessionEnd (detached, time-bounded and silent on failure - skipped outright when the branch has
no upstream), then reliably at the next SessionStart, which pulls first. If the branch has no
upstream, or both attempts are rejected, the commits stay local. `memory-doctor` reports a missing
upstream as a **sync** ERROR, and warns under **sync** once more than 20 commits are unpushed; a
smaller backlog shows only in the header counter (`+N/-N`) and in `--json`.

**`pre-push` refused a push I meant.** Prefer integrating: `git pull --rebase origin <branch> &&
git push`. If the rewrite is genuinely intended, `ALLOW_FORCE_PUSH=1 git push --force-with-lease`.

**`pre-commit` refused a commit that is genuinely one change.** `ALLOW_MIXED_COMMIT=1 git
commit ...`. If this happens often, the change is probably not a memory change, and the memory
files should be committed separately.

**The statusline is blank, or every prompt prints an error about it.** The framework ships no
statusline, so one on your machine came from your own memory repo's root - or from an install
predating its removal from this repo. The `statusLine` key and the script it names must travel
together from the same root: `setup.sh` installs `~/.claude/statusline-command.sh` only when a
root carries it, and `setup.ps1` the `.js` on the same condition. A blank line usually means `jq` is missing
(the `.sh` script reads its input with it and renders empty without it) - install `jq`, or delete
the `statusLine` key from `~/.claude/settings.json` to turn the statusline off. It has nothing to
do with the memory layer either way.

**A commit was refused in the middle of a merge or rebase.** It was not `pre-commit`: that guard
stands down while git is mid-merge, cherry-pick, revert or rebase. Read the message again - it is
another hook, most likely the repo's own, which the shipped `pre-commit` chains to on every path.

**A repo's own hooks stopped running.** That is `core.hooksPath`. See
[About `core.hooksPath`](#about-corehookspath).

**The guards do nothing in a repo I expected them to guard.** The name is the basename of
`git remote get-url origin` with `.git` stripped, or - where the repo has no `origin` - the
worktree's own directory name. Check it matches an entry in `MEMORY_REPOS` / `GUARDED_REPOS`, and
remember a renamed remote changes the name even when the folder keeps the old one. A name
containing a space cannot be put in either list at all (see
[`sunstone.conf` reference](#sunstoneconf-reference)); only the derived default handles one.

---

## Uninstall

The reverse of [What setup installs](#what-setup-installs). Files are removed by name, never by
directory, because `~/.git-hooks/` and `~/.git-templates/hooks/` may have held hooks of your own
before setup ran.

```bash
# 1. git: hooks and the two global settings
for h in $(ls ~/.git-hooks 2>/dev/null); do
  rm -f ~/.git-hooks/$h ~/.git-templates/hooks/$h
done
ls ~/.git-hooks/*.bak.* ~/.git-templates/hooks/*.bak.* 2>/dev/null   # a hook of YOUR OWN that setup
                                                 # replaced is here as <hook>.bak.<timestamp>;
                                                 # mv it back to <hook> before the rmdir
rmdir ~/.git-hooks ~/.git-templates/hooks ~/.git-templates 2>/dev/null   # only succeeds when empty
git config --global --unset core.hooksPath      # both settings: setup wrote both
git config --global --unset init.templateDir
cat ~/.claude/git-config.previous 2>/dev/null   # if setup replaced earlier values they are listed
                                                 # here as key=value; restore each with
                                                 # git config --global <key> <value>
rm -f ~/.claude/git-config.previous

# 2. Claude Code: the hook scripts and the state files. Setup ships the whole
#    claude-setup/config/hooks/ directory, not just the three memory hooks, so
#    all nine go here. A personal root may have added more - see Overlay
#    residue below.
for h in ai-memory-sync.sh ai-memory-sync.js ai-memory-commit.sh ai-memory-commit.js \
         memory-doctor-notice.sh session-bus-notice.js context-mode-cache-heal.mjs ctx-gauge.mjs context-guard.mjs; do
  rm -f ~/.claude/hooks/$h
done
# Supermode: the layered settings file, the launcher, the two commands, and the
# per-session gauge files the guard wrote. None of it is referenced from
# settings.json, so nothing else needs editing.
rm -f ~/.claude/supermode.settings.json ~/.local/bin/supermode ~/.claude/bin/supermode.ps1
rm -f ~/.claude/commands/supermode.md ~/.claude/commands/supercode.md
rm -rf ~/.claude/ctx
# The statusline: the framework ships none, so these exist only if YOUR memory
# repo shipped statusline-command.sh (setup.sh) or .js (setup.ps1), or an older
# version of this framework left one behind. If you remove them, remove the
# statusLine key from settings.json too - see below - or every prompt runs a
# command that is no longer there.
rm -f ~/.claude/statusline-command.sh ~/.claude/statusline-command.js
# The two subagent files (model: sonnet by default).
rm -f ~/.claude/agents/architect.md ~/.claude/agents/verify.md
rm -f ~/.claude/ai-memory-path ~/.claude/sunstone-path ~/.claude/.memory-doctor-last ~/.claude/.memory-doctor-off
rm -rf ~/.claude/session-bus                # what the session-bus notice has already announced

# 3. The global CLAUDE.md setup replaced (every run rewrites it from CLAUDE.global.md)
ls ~/.claude/CLAUDE.md.bak.* 2>/dev/null    # mv the newest one back to ~/.claude/CLAUDE.md,
                                            # or delete ~/.claude/CLAUDE.md if it was setup that
                                            # created it
```

Then edit `~/.claude/settings.json` and remove what setup merged in: the two `SessionStart`
entries (`ai-memory-sync.sh`, `memory-doctor-notice.sh`) and the `SessionEnd` entry
(`ai-memory-commit.sh`), whose shape is in
[Registering the hooks by hand](#registering-the-hooks-by-hand); and, from the shipped template,
the two further `SessionStart` entries (`context-mode-cache-heal.mjs`, `session-bus-notice.js`)
and the `PreToolUse` entry on `Bash`. That is the whole of it: the shipped template carries no `statusLine` and no `env` key, so
anything of either kind in the file is yours or your memory repo's template's - including an
`env.DISABLE_AUTOUPDATER`, which older versions of this framework did merge in. `permissions` was
never touched, so leave it. If the file did not exist before setup ran, the merge created it, and
the reverse is deleting it rather than editing it. `rmdir ~/.claude/hooks 2>/dev/null` removes the
directory setup created if nothing else is left in it - a hook the memory repo's own
`claude-setup/config/hooks/` overlaid is not in the loop above and has to go by name first.
Optionally delete the `settings.json.bak.*` and other `*.bak.*` files setup left beside anything
it replaced.

**Residue in repos created during the install.** While `init.templateDir` was set, every repo you
cloned or `git init`ed received its own copies of `pre-commit` and `pre-push` in `.git/hooks/`.
Unsetting `core.hooksPath` makes those copies live repo-local hooks: they keep guarding, and they
shadow a `husky`-style hook a project later tries to install there.

⚠️ **The residue bites before you unset anything.** The shipped hooks deliberately chain to
`<repo>/.git/hooks/<hook>` at the end, so with `core.hooksPath` still set the global hook runs
**and then execs the repo-local copy** - both fire, and you see the guard's message printed twice.
That is the symptom to recognise: a duplicated `pre-push` or `pre-commit` warning means this repo
has template residue, not that the guard is broken. Worse, the copies are frozen at whatever
generation was current when the repo was created, so an old one can still be matching a stale
repo-name list while the global copy reads your current `sunstone.conf`.

Find and remove them where you do not want them:

```bash
grep -ls 'ALLOW_FORCE_PUSH\|ALLOW_MIXED_COMMIT' ~/src/*/.git/hooks/pre-commit ~/src/*/.git/hooks/pre-push 2>/dev/null
```

(adjust `~/src/*` to wherever you keep repos; both installed hooks name their override variable).

**Overlay residue.** Step 2 names what the *framework* root ships (the eight hook scripts, the two
guards in `~/.git-hooks/`, the two subagent files, the supermode settings file, launcher and two
commands). A statusline and anything under
`~/.opencode/plugins/` are **not** in that list - the framework leaves both slots empty, so
whatever is at `~/.claude/statusline-command.*` or `~/.opencode/plugins/*.js` came from your
memory repo or from an older version of this framework. Whatever the **memory repo** root added
on top stays until you remove it, and only its own copies say which files those were:
`~/.claude/skills/<name>`, `~/.codex/skills/<name>` and `~/.config/opencode/skills/<name>` for
each `skills/<name>/`; `~/.claude/commands/*.md`; any further `~/.claude/agents/*.md`; the hook
scripts under `~/.claude/hooks/` that came from its `claude-setup/config/hooks/`;
`~/.codex/config.toml`, `hooks.json`, `AGENTS.md`, `rules/`; `~/.config/opencode/opencode.jsonc`
and any further `~/.opencode/plugins/*.js`; and `~/AGENTS.md` and `~/CLAUDE.md` (restore each from
its `.bak.<timestamp>` copy if you had one - `~/.claude/CLAUDE.md` is step 3 above). In
`settings.json`, remove the hook entries the memory repo's template registered.

Left alone on purpose: your memory repo, including a clone `setup.sh` made in `~/.ai-memory` or
`--clone-to` - it is an ordinary git repo and nothing here owns it. **`install.sh` puts nothing on
the machine the steps above do not already cover**: every file it writes - a memory repo's
statusline if one is shipped, `~/.claude/CLAUDE.md`, the settings template keys, all six scripts of
`claude-setup/config/hooks/` (the three memory hooks among them, copied but never registered),
the `~/.claude/agents/*.md` files, `~/AGENTS.md` and `~/CLAUDE.md`, the skills, commands and
Codex / OpenCode trees - `setup.sh` writes too, from the same sources. (It has not shipped a second `statusline.sh` since that file was
deleted as dead; nothing installs one, and a stale `~/.claude/statusline.sh` on your machine came
from an older version and can go.) Either way you can instead restore the
`settings.json.bak.<timestamp>` left when a merge changed something. On Windows the files are
`~\.claude\hooks\ai-memory-sync.js`, `ai-memory-commit.js` and `memory-doctor-notice.sh` - plus,
only if a root shipped `claude-setup/config/statusline-command.js`,
`~\.claude\statusline-command.js` and the `statusLine` key `setup.ps1` then set in `settings.json`.
