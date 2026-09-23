# sunstone

**Your agent's memory is a git repo you own.** Carry it to a new machine, run the installer, and
what you know grows back around you - your memory, and whatever skills, commands and hooks you
keep beside it. No API, no vendor, no database, nothing to sign up for. The machine can die
because the knowledge was never stored on it.

What it does, in plumbing terms:

- **A memory repo you own.** Your memory files live in a private git repo; the framework records its clone path in one line and never assumes a name or a layout.
- **SessionStart pull and inject.** Every session begins by pulling that repo and injecting one file from it into context.
- **SessionEnd commit.** Whatever the session wrote under the memory tree is committed when it ends, and the next start pushes it.
- **Two git guards plus `memory-doctor`.** A mixed-staging guard and a force-push guard keep the repo safe when several sessions write to it; `memory-doctor` checks the wiring, the index and the drains.

```bash
git clone https://github.com/<owner>/sunstone sunstone   # the URL shown on this repository's page
cd sunstone
./setup.sh --memory-repo git@github.com:alice/my-memory.git   # or https://github.com/alice/my-memory.git
```

## The two-repo model

| Repo | What it holds | Who owns it |
|---|---|---|
| **sunstone** (this one) | Hooks, setup scripts, `memory-doctor`, docs. Nothing personal. | Public, shared |
| **your memory repo** | Your memory files, an optional `sunstone.conf`, and optionally your own skills, commands, agents, hooks and statusline in the framework's layout - the [overlay](claude-setup/SETUP.md#the-overlay-your-own-skills-commands-and-hooks). | You, private |

> *A sunstone is the crystal Jor-El used to preserve Kryptonian knowledge past the destruction of
> the planet. Kal-El inherits one, and planting it grows the whole Fortress of Solitude back.*

Concretely: a portable memory layer for Claude Code - its two session hooks are Claude Code hooks -
plus an overlay that carries your skills and config to Codex and OpenCode as well, and two git
hooks that keep the memory repo safe when several sessions write to it at once. Every session
starts by pulling your private memory repo and injecting one file from it into context;
everything a session writes back into the memory tree is committed when the session ends. The
framework itself is plumbing - it ships no skills, no slash commands and no statusline; the
personal half lives in a repo you own. Two third-party conveniences do still ship in the settings
template - a graphify hint on `Bash` searches and a context-mode cache self-heal at SessionStart -
and both are listed under [What the framework deliberately does not
ship](claude-setup/SETUP.md#what-the-framework-deliberately-does-not-ship), with how to drop them.

The framework never assumes a name, a path or a layout for your memory repo beyond
[the minimum](claude-setup/SETUP.md#the-memory-repo). Its clone path is recorded in the
single-line file `~/.claude/ai-memory-path`; the two memory hooks read that file, fall back to
`~/.ai-memory`, and exit silently only when neither is a git repo - so a machine with no memory
repo runs them as no-ops. (The force-push guard is the one exception: it protects a repo named
`sunstone` even on a machine that has no memory repo at all.) A second single-line
file, `~/.claude/sunstone-path`, records where this framework checkout lives, so hooks that are
copies can still find `memory-doctor` in it. Both files are read whole and trimmed, never split
on spaces, so a path containing a space works.

Anything that is a *preference* rather than the memory layer - a statusline, another tool's
auto-updater setting, prose telling an assistant which third-party CLI to reach for - is
deliberately not shipped here and reaches your machine through the overlay instead. (The two
template hooks named above are the surviving exception, and they are inert until the tool they
serve is present.) The reasoning, and the bug that taught it, are
in [What the framework deliberately does not
ship](claude-setup/SETUP.md#what-the-framework-deliberately-does-not-ship).

Throughout these docs the example memory repo is called `my-memory` and its owner is `alice`.

## Platforms

One installer per platform, both installing the same layer. `setup.sh` covers Linux, macOS and
WSL; `setup.ps1` covers native Windows and is described under
[Windows](claude-setup/SETUP.md#windows).

| | Installer | What that platform lacks by default, and what happens |
|---|---|---|
| **Linux** | `setup.sh` | Nothing in particular. This is the most-exercised path. |
| **WSL** | `setup.sh` | Treated as Linux, and it is one - a WSL checkout is a Linux checkout. Only the Windows side of the same machine needs `setup.ps1`, and only if you also run Claude Code natively there. |
| **macOS** | `setup.sh` | No `python3` (it arrives with the Xcode command line tools), so the settings template is merged by `node` instead; no `timeout`, so the SessionStart hook bounds git itself rather than running unbounded. `/bin/bash` is 3.2 - nothing here uses a bash 4 feature. BSD `date`, `readlink` and `sort` differ from GNU and each use falls back. |
| **Windows** | `setup.ps1` | No `python3`, so the three session hooks install as their Node ports (`node` is required for them, and - with no `python3` here - for the `settings.json` template merge too; the git hooks, global `CLAUDE.md` and subagent files land without it). Nothing the settings template registers needs `python3` either: the graphify hint is a Node script that runs only when a graph, the script and `node` are all present. The git hooks are `sh` scripts, which Git for Windows runs through its own bundled shell - nothing extra to install. |

✅ **Honest status.** All four platforms are verified by running the installer end to end. macOS
was the last, on 2026-09-12 (Apple Silicon, macOS 26 / Darwin 25, `/bin/bash` 3.2, `/usr/bin/git`
and `python3` from Xcode): every step landed, `memory-doctor` reported 0 errors, and the
SessionStart hook injected the memory file on the first try. The one macOS lesson lives outside
the framework: bash 3.2's `echo -e` does not know `\e`, so a statusline or hook carried by the
overlay must write `\033[` - the framework's own hooks already do.

On Windows, `setup.ps1` needs **PowerShell 7**: ⚠️ **it does not parse under Windows PowerShell
5.1**, so use `pwsh`, not the `powershell` that ships with the OS. Its first end-to-end run was
2026-09-11 - 44 skills across three roots, both git-hook trees, the settings merge and the memory
wiring. ⚠️ It overwrites `CLAUDE.md`, replaces skill directories whole, and rewrites
`~/.claude/ai-memory-path`, with no `-WhatIf` and no dry run - back those up yourself before a
first run, and see [Windows](claude-setup/SETUP.md#windows). After any first run on a new machine, the [Verify](claude-setup/SETUP.md#verify) steps are what to check.

## Quick start

Then restart Claude Code, and check the result with `node claude-setup/scripts/memory-doctor.js`.
The first session after that restart pulls `my-memory`, injects its memory file, and the
SessionEnd hook starts committing whatever the session writes under the memory tree.

**No memory repo yet?** [Create one first](claude-setup/SETUP.md#the-memory-repo) - an empty
private repo on your host, then a short `git init` recipe fills it and pushes. `setup.sh` needs a
repo that already exists; it will clone one or adopt a local clone, but it will not create one
for you. A memory repo holding nothing but `claude-setup/memory/ABOUT-ME.md` is already complete.

**Give the repo in whichever URL form this machine can already authenticate**: the SSH form needs
an SSH key, the HTTPS form a credential helper or token, and `git ls-remote <url>` is the quick
way to check by hand. `git` itself must be on `PATH` - **both** installers check for it before
they print anything at all and stop with `nothing has been installed` if it is missing, rather
than surfacing a bare `git: command not found` halfway through with the hook files already on
disk. Past that, `setup.sh` resolves the memory repo *first*: the clone, or the check that a local
path is a git repo, happens before anything is written to the machine, so a bad URL or a missing
SSH key leaves the machine exactly as it was and there is nothing to undo.

`setup.sh` also reads the repo from `SUNSTONE_MEMORY_REPO` (the flag wins), and asks for it when
it is running in a terminal with neither. A git URL is cloned into `~/.ai-memory` - the one path
the hooks also try when `ai-memory-path` is missing - or into `--clone-to <dir>`; anything else is
treated as a local clone and used in place. Every flag that takes a value accepts both
`--flag <value>` and `--flag=<value>`. `--skip-memory` leaves `ai-memory-path` alone entirely, and
`--skip-overlay` installs the framework's trees only. The full table is in
[Flags](claude-setup/SETUP.md#flags).

Clone this repository as it is; fork it first only if you intend to change the framework, since
`setup.sh` records the checkout's location in `~/.claude/sunstone-path` and the SessionStart
notice hook runs `memory-doctor` from there.

Windows: `pwsh -ExecutionPolicy Bypass -File setup.ps1 -MemoryRepo <url-or-path>` - **`pwsh`, not
the `powershell` that ships with Windows**, which cannot parse the script - and see
[Windows](claude-setup/SETUP.md#windows) for what differs.

## What gets installed

Twelve steps, run once from the framework root and again from your memory repo. In summary:

- **thirteen hook scripts** in `~/.claude/hooks/` - `ai-memory-sync`, `ai-memory-commit` and
  `memory-doctor-notice` (each with its Node port), `session-bus-notice.js`, `graphify-nudge.mjs`,
  `context-mode-cache-heal.mjs`, supermode's `ctx-gauge.mjs` and `context-guard.mjs`, and `say.sh`
  / `say.ps1` (supermode speaks one sentence per slice; silent where the machine cannot speak) -
  producing six registered entries in `~/.claude/settings.json`: the three memory hooks, plus the
  settings template's own `PreToolUse` entry (the graphify nudge) and its two `SessionStart`
  entries (the cache heal and the session bus, the latter inert until `BUS_DIR` is set). The two supermode scripts are **not** registered there: they run only
  in a session launched as supermode (next bullet);
- **supermode** - `~/.claude/supermode.settings.json`, the `supermode` launcher in
  `~/.local/bin/`, and two slash commands, `/supermode` and `/supercode`, in
  `~/.claude/commands/`. Nothing in it changes an ordinary session; see
  [Supermode and supercode](#supermode-and-supercode);
- **two git hooks** in `~/.git-hooks/` (and the clone-time template `~/.git-templates/hooks/`),
  reached by a global `core.hooksPath`;
- **`~/.claude/CLAUDE.md`**, rewritten on every run from the shipped `CLAUDE.global.md` - 27
  lines on where a memory goes, how to write one, and session continuity. Keep anything you want
  to survive a re-run in your memory repo's own copy, which wins over the framework's;
- **two subagent files** in `~/.claude/agents/` - `architect` and `verify`, both pinned to
  `model: sonnet`, the mid tier, so a framework a stranger runs sight-unseen does not bill at the
  top one. To raise the tier, ship your own copies from your memory repo's
  `claude-setup/config/agents/` with the `model:` line you want - a same-named file there wins;
- **the two single-line path files** above;
- and a merge into `~/.claude/settings.json`. A framework-only install leaves that file holding
  **`hooks` and nothing else**: no `statusLine`, no `env`, and `permissions` is never touched.

Everything else the layout allows - skills, further slash commands, a statusline, Codex and
OpenCode config, extra git hooks - is an empty slot that a framework-only install reports as `skipped`
until your memory repo fills it. The file-by-file list is [What setup
installs](claude-setup/SETUP.md#what-setup-installs), and
[Uninstall](claude-setup/SETUP.md#uninstall) undoes it. There are no opt-in flags for extra
behaviour: what lands is decided by what the two roots ship, not by switches.

`setup.sh` is idempotent and backs up anything it overwrites - the skills step is the one that
replaces a whole `<name>` directory rather than merging it, backing up a differing one beside
itself first. Re-running it is also how an update takes effect: **`git pull` on this repo changes
nothing that runs**, because every hook executes from a copy under `~/.claude/hooks/`,
`~/.git-hooks/` or `~/.git-templates/hooks/`. `memory-doctor`'s wiring check reports that drift
for the memory hooks under `~/.claude/hooks/`, and its [drift check](#config-drift) for the other
hooks, the two `CLAUDE.md` files and the statusline; it never reads the two installed git
guards, so drift in those is only ever fixed by re-running `setup.sh`.
On a machine already set up, a bare `./setup.sh` is enough - the memory repo is remembered.

```bash
cd sunstone && git pull && ./setup.sh
```

## What the hooks do

Every hook fails silently by design: no repo, no network, no `python3`, no `node` - the session
still starts and the commit or push still goes through. That is the right call for one session
and the wrong call for a month, which is what `memory-doctor` is for. **Why each hook is shaped
the way it is** - the failure each one prevents, and the cases each deliberately stands down for -
is in [Guard semantics](claude-setup/SETUP.md#guard-semantics) for the two git hooks, and in
[The doctor notice hook](claude-setup/SETUP.md#the-doctor-notice-hook) and [Checking it still
works](claude-setup/SETUP.md#checking-it-still-works) for the session hooks. Each script's own
header comment carries the same reasoning at the point of use.

| Hook | Event | What it does |
|---|---|---|
| `ai-memory-sync` | Claude Code **SessionStart** | Pulls the memory repo (`--ff-only` first, then `--rebase --autostash` if the branches diverged, aborting on conflict), pushes anything still unpushed, runs the repo's optional `claude-setup/session-start.d/*` scripts, then injects `MEMORY_FILE` - plus whatever those scripts printed - as context. Every network call and every script is time-bounded. See [session-start.d](claude-setup/SETUP.md#session-startd-scripts-the-memory-repo-runs-on-every-machine). |
| `ai-memory-commit` | Claude Code **SessionEnd** | Commits anything changed under `MEMORY_DIR`, staged **by path** and nothing else, with `--no-verify`; then fires a detached, time-bounded push and returns without waiting for it. Refuses to run at all mid-merge, mid-cherry-pick, mid-rebase or on a detached HEAD. |
| `memory-doctor-notice` | Claude Code **SessionStart** | Injects a short notice from `memory-doctor --brief` - a summary line plus up to three WARN lines - at most once per 20 hours, and nothing at all when the stores are clean. Disable with `touch ~/.claude/.memory-doctor-off`. |
| `session-bus-notice` | Claude Code **SessionStart** | Off until `BUS_DIR` is set. Announces, once, every other machine's outbox in the memory repo that has changed since it was last announced - see [The session bus](#the-session-bus). |
| `pre-commit` | git, via global `core.hooksPath` | In `MEMORY_REPOS`, refuses a commit that stages paths both inside and outside `MEMORY_DIR`. Stands down entirely while git is mid-merge, cherry-pick, revert or rebase. Override: `ALLOW_MIXED_COMMIT=1 git commit`. |
| `pre-push` | git, via global `core.hooksPath` | In `GUARDED_REPOS`, refuses any push that is not a fast-forward, any branch deletion, and any push whose remote tip is not in the local object store at all. Override: `ALLOW_FORCE_PUSH=1 git push`. |

⚠️ Both git hooks **chain to the repo's own `.git/hooks/<name>` in every repo, guarded or not**,
because a global `core.hooksPath` means git no longer runs a repo's own hooks by itself. Without
that chaining, installing this framework would silently switch off every husky, lint-staged and
`pre-commit.com` hook on the machine. Read the header of
`claude-setup/config/git-hooks/pre-commit` before changing either one.

The framework ships exactly those two guards, both conf-driven, and no opinion about commit
*content*. `claude-setup/config/git-hooks/` is an overlay tree like every other one, so your
memory repo can add hooks of its own or replace either guard by shipping a file of the same name.
That is deliberately how anything opinionated is meant to travel: carrying the file **is** the
opt-in, no flag is needed, and nobody else inherits your policy by installing this.

### memory-doctor

```bash
node claude-setup/scripts/memory-doctor.js            # human report
node claude-setup/scripts/memory-doctor.js --verbose  # list every item
node claude-setup/scripts/memory-doctor.js --json     # machine-readable
node claude-setup/scripts/memory-doctor.js --brief    # a short notice, or nothing (what the notice hook uses)
```

Read-only, and exit code 1 when there is an ERROR, so it works as a CI or pre-push gate. It
checks the **wiring**, the **sync** state, the memory **index**, file **hygiene**, the
machine-local **working tier**, per-project **repo stores** and **duplicates** across stores -
[what each check catches](claude-setup/SETUP.md#checking-it-still-works). One more check is
off until you switch it on:

#### The work-queue check

If you keep a work queue as a markdown file in your memory repo - a table of what is being worked
on now, under a heading - the doctor can keep it honest. Three `sunstone.conf` keys, all read by
`memory-doctor` only:

| Key | Default | Meaning |
|---|---|---|
| `QUEUE_FILE` | empty = **off** | The queue file, relative to the memory repo (`WORK-QUEUE.md`, say). |
| `QUEUE_NOW_HEADING` | empty = the first `## ` heading whose text contains `NOW`, case-insensitive | The H2 that opens the NOW section, with or without the `## `. |
| `QUEUE_NOW_MAX` | `3` | How many rows the NOW table may hold. |

The NOW section runs from that heading to the next `#`/`##` heading; its rows are the lines in it
that start with `|`, minus the separator rows (`|---|`) and the header row above each one. Two
things raise a WARN, never an ERROR, so the exit code is unchanged:

- more rows than `QUEUE_NOW_MAX`: `QUEUE: NOW has 5 rows (max 3); a longer NOW is a wish list`;
- a row whose **last cell** carries a date that has passed: `QUEUE: NOW row dated 2026-09-01 is
  in the past`, followed by the first 60 characters of the row. Only two forms are read, on
  purpose: an ISO `YYYY-MM-DD` date, and the literal word `yesterday` (`today` is recognised and
  is not past). `Mon D`-style dates are not parsed, so a queue that wants the check to fire writes
  the ISO form.

Both WARNs are part of the `--brief` notice the SessionStart hook injects, so a NOW that has grown
past its cap is mentioned at the start of a session rather than discovered at the end of a month.
A `QUEUE_FILE` that names a missing file, or a queue with no matching heading, is a WARN too.

### Config drift

`setup` installs `~/.claude/CLAUDE.md` (from `CLAUDE.global.md`), `~/CLAUDE.md` (from your memory
repo's `agents/CLAUDE.md`), the statusline and every hook script as **copies**. A copy edited in
place keeps working, `git status` in both repos stays clean, and nothing says the machine and the
repo have parted - until the next `setup` run backs the edit up and overwrites it. Two answers,
one per direction:

- **`memory-doctor` reports it.** The `drift` check is always on and costs a few file reads: each
  installed file whose source is known is compared byte for byte with the file it was installed
  from, resolved the way `setup` resolves it (the framework checkout from `~/.claude/sunstone-path`,
  the memory repo from `ai-memory-path`, and whatever both ship, the memory repo's copy wins).
  A difference is a WARN - `DRIFT: ~/CLAUDE.md differs from my-memory/agents/CLAUDE.md - edit the
  repo file and re-run setup.sh, or copy the live file back into the repo if the live edit is the
  one to keep` - and it is part of the `--brief` notice. Covered: the two `CLAUDE.md` files,
  `statusline-command.sh` / `.js`, and everything in `~/.claude/hooks/` that either root ships
  (the two memory hooks are reported by the **wiring** check instead). Both platforms.
- **`LINK_CLAUDE_MD=1` prevents it, on POSIX.** With that key in `sunstone.conf`, `setup.sh`
  installs the two `CLAUDE.md` files as **symlinks** to their repo sources instead of copies, so
  editing the live file *is* editing the repo file and `git status` shows it. An existing copy
  is backed up beside itself first (only when its content differs from the source); re-running
  is a no-op once the links are in place, and removing the key turns them back into copies on
  the next run. Off by default, because a link into a checkout surprises a machine that later
  moves the checkout. `setup.ps1` ignores the key - a symlink on Windows needs Developer Mode -
  and prints one line saying so; the drift check covers Windows instead.

| Key | Default | Meaning |
|---|---|---|
| `LINK_CLAUDE_MD` | unset = copies | `1`: `setup.sh` symlinks `~/CLAUDE.md` and `~/.claude/CLAUDE.md` to the repo files. POSIX only. |
| `LINK_HOOKS` | unset = copies | `1`: `setup.sh` symlinks `~/.claude/hooks/*` at this repo's `claude-setup/config/hooks/*`. A `git pull` here then updates every hook on that machine, instead of the fix waiting for somebody to re-run setup on each box. POSIX only; `setup.ps1` ignores it. |

## The session bus

Two machines of one user - a laptop and a desktop, the WSL side and the Windows side of one box -
share the memory repo but not a terminal. The session bus lets a session on one side leave a note
the next session on the other side will see, with nothing but the repo in between. Off until you
set it up; two `sunstone.conf` keys:

| Key | Default | Meaning |
|---|---|---|
| `BUS_DIR` | unset = **off** | The bus directory, relative to the memory repo (`claude-setup/bus`, say). |
| `BUS_SIDE` | detected | This machine's side name. Detection: `windows` on Windows, `mac` on macOS, `wsl` when `/proc/version` mentions Microsoft, else `linux`. Set it when two machines would detect the same name. |

**The protocol.** `BUS_DIR/outbox-<side>.md`, one writer per file: a machine writes **only its own**
outbox, newest entry at the top under a `## <stamp> - <subject>` heading, then commits that file
by path and pushes. (The memory repo's commit hook only commits `MEMORY_DIR`; a bus entry is a
commit you or the session make on purpose, `git add <BUS_DIR>/outbox-<side>.md && git commit`.)
The other side sees it at its next SessionStart, because `ai-memory-sync` pulled first.

**The hook.** `session-bus-notice.js` runs at SessionStart, registered by the settings template
after the sync hook on both platforms (Node, no dependencies). For every `outbox-*.md` in `BUS_DIR`
that is not this side's own, it compares the file's git blob hash with the last one it announced,
kept under `~/.claude/session-bus/<file>.seen`, and when they differ it injects one line:

```
📬 session bus: outbox-windows.md has a new entry - "2026-09-21 10:00 - please pull the fonts branch"
```

The quoted part is the file's first `## ` heading. It is silent when `BUS_DIR` is unset or the
directory is missing, when nothing changed, when a file it has never seen is empty, and on every
failure. Claude Code may start SessionStart hooks together, so a message that arrives in the very
same pull can be announced one session late; nothing is lost, because the comparison is against
what is on disk. The `.seen` files are machine-local by design - each machine keeps its own
record of what it has been told.

## Supermode and supercode

Two ways of working that ship as procedures, not as defaults. Neither changes an ordinary
session.

**Supermode** is unattended work - the session keeps going after you have left the chair,
with the checkpoints that make that safe. Launch it as `supermode` instead of `claude` (every
argument passes through). That does three things, for that session only:

- `SUPERMODE=1` in the environment - a successor session inherits it;
- `supermode.settings.json` layered on with `claude --settings`: **auto-compaction off**, a
  `PostToolUse` context guard, and your status line fronted by a gauge. Your
  `~/.claude/settings.json` is not touched;
- the `/supermode` command carries the loop: one slice → the repo's gate → commit on green →
  a handoff note after **every** slice, because the model cannot see its own context gauge.

The reason for the settings layer is compaction. When the window fills, Claude Code's default
is to compact: the largest single request of the session, returning a summary without the
numbers. Supermode hands off instead. Claude Code shows the percentage only to the status
line, so `ctx-gauge.mjs` sits in front of yours (it delegates to `statusline-command.sh` /
`.js`, or `$SUPERMODE_STATUSLINE`, and prints a one-liner when you have none) and writes it
to `~/.claude/ctx/<session>.pct`. After every tool call `context-guard.mjs` reads it and, from
**70%** (`SUPERMODE_CTX_PCT`), once per 5% band, tells the model in hook context: finish the
slice, commit, write the handoff, start the successor (`supermode --bg --permission-mode auto
"supermode: resume"`), stop. Without the gauge file - a `-p` run, say - it estimates from the
transcript's `usage` against `SUPERMODE_CTX_WINDOW` (default 200000) and says the figure is an
estimate. The guard exits immediately unless `SUPERMODE=1`, so registering it globally would
cost nothing; the launcher is the opt-in.

**Supercode** is width: `/supercode` fans the work out over concurrent agents - plain means
the minimum that gives assurance (2-3 disjoint lenses, one refuter per finding), `max` means
as wide as the work splits. It carries the four rules that make a fan-out pay (exclusive file
ownership, hand over the verified facts, name the shared resources nobody may touch, gate
centrally once) and the two things it cannot do (one shared file, ambiguous work). The two
compose: a supermode session fans out at the minimum unless told `supercode max`.

Both words are one person's; the mechanism is anyone's. Rename the commands in your memory
repo's `claude-setup/commands/` if you want other words - a same-named file there wins.

## Layout

```
sunstone/
├── README.md
├── setup.sh                       # Linux / macOS / WSL - the installer these docs describe
├── setup.ps1                      # Windows equivalent (Node hook ports; keeps its UTF-8 BOM)
└── claude-setup/
    ├── SETUP.md                   # the runbook: flags, what lands where, verifying, uninstall
    ├── install.sh                 # optional: re-applies the eleven non-memory steps alone
    ├── scripts/
    │   └── memory-doctor.js
    └── config/
        ├── hooks/
        │   ├── ai-memory-sync.sh / .js       # SessionStart (sh on POSIX, js on Windows)
        │   ├── ai-memory-commit.sh / .js     # SessionEnd
        │   ├── memory-doctor-notice.sh / .js # SessionStart notice (sh on POSIX, js on Windows)
        │   ├── session-bus-notice.js         # SessionStart: another machine's outbox changed (BUS_DIR)
        │   ├── graphify-nudge.mjs            # PreToolUse: the graphify hint; no python3 needed
        │   ├── context-mode-cache-heal.mjs   # unrelated to memory; ships with the hooks tree
        │   ├── ctx-gauge.mjs                 # supermode: fronts your status line, writes the %
        │   ├── context-guard.mjs             # supermode: PostToolUse checkpoint nudge from 70%
        │   └── say.sh / say.ps1              # supermode: "<slice> is done. Taking up <next>."
        ├── git-hooks/
        │   ├── pre-commit                    # mixed-staging guard
        │   └── pre-push                      # force-push guard
        │                                     #   (a personal repo may add its own here - they
        │                                     #    install after these and override by filename)
        ├── merge-ai-memory-hook.py           # setup.sh: registers the memory hooks in settings.json
        ├── merge-claude-settings.mjs         # setup.ps1: the same, plus an optional statusLine
        ├── merge-settings-template.py / .mjs # the template merger (one tool, two ports)
        ├── agents/                           # architect.md, verify.md → ~/.claude/agents/
        ├── settings.json                     # template merged into ~/.claude/settings.json
        ├── supermode.settings.json           # → ~/.claude/; layered on supermode launches only
        └── CLAUDE.global.md                  # → ~/.claude/CLAUDE.md; a memory-repo copy wins
    ├── bin/
    │   ├── supermode                     # → ~/.local/bin/supermode (POSIX launcher)
    │   └── supermode.ps1                 # → ~\.claude\bin\supermode.ps1 (Windows launcher)
    └── commands/
        ├── supermode.md                  # /supermode - the unattended procedure
        └── supercode.md                  # /supercode - the fan-out procedure
```

There is no `skills/`, no `plugins/` and no statusline in that tree, and `commands/` holds only
the two above. They are overlay slots, filled by whatever your memory repo carries in the same
relative layout.

`claude-setup/install.sh` is a separate, optional script that re-applies the eleven non-memory steps
alone. It deliberately omits the twelfth, `git-hooks`, because installing hook files without
also setting `core.hooksPath` would put them on disk where nothing runs them - and it registers
no memory hooks, so on its own it leaves them installed and inert. `setup.sh` is what installs the
memory layer; see [The second installer](claude-setup/SETUP.md#the-second-installer-installsh).

Flags, prerequisites, the memory repo's layout and file format, the `sunstone.conf` reference,
what lands where file by file, how to verify a fresh install, Windows, troubleshooting and
uninstall are all in [claude-setup/SETUP.md](claude-setup/SETUP.md).
