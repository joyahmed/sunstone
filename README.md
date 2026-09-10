# sunstone

A portable memory layer for Claude Code, plus two git hooks that keep it safe when several
sessions write to the same repo at once. Every session starts by pulling your private memory repo
and injecting one file from it into context; everything a session writes back into the memory
tree is committed when the session ends. The framework itself is plumbing — it ships no skills,
no slash commands and no statusline; the personal half lives in a repo you own. Two third-party
conveniences do still ship in the settings template — a graphify hint on `Bash` searches and a
context-mode cache self-heal at SessionStart — and both are listed under [What the framework
deliberately does not ship](claude-setup/SETUP.md#what-the-framework-deliberately-does-not-ship),
with how to drop them.

## The two-repo model

| Repo | What it holds | Who owns it |
|---|---|---|
| **sunstone** (this one) | Hooks, setup scripts, `memory-doctor`, docs. Nothing personal. | Public, shared |
| **your memory repo** | Your memory files, an optional `sunstone.conf`, and optionally your own skills, commands, agents, hooks and statusline in the framework's layout — the [overlay](claude-setup/SETUP.md#the-overlay-your-own-skills-commands-and-hooks). | You, private |

The framework never assumes a name, a path or a layout for your memory repo beyond
[the minimum](claude-setup/SETUP.md#the-memory-repo). Its clone path is recorded in the
single-line file `~/.claude/ai-memory-path`; the two memory hooks read that file, fall back to
`~/.ai-memory`, and exit silently only when neither is a git repo — so a machine with no memory
repo runs them as no-ops. (The force-push guard is the one exception: it protects a repo named
`sunstone` even on a machine that has no memory repo at all.) A second single-line
file, `~/.claude/sunstone-path`, records where this framework checkout lives, so hooks that are
copies can still find `memory-doctor` in it. Both files are read whole and trimmed, never split
on spaces, so a path containing a space works.

Anything that is a *preference* rather than the memory layer — a statusline, another tool's
auto-updater setting, prose telling an assistant which third-party CLI to reach for — is
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
| **WSL** | `setup.sh` | Treated as Linux, and it is one — a WSL checkout is a Linux checkout. Only the Windows side of the same machine needs `setup.ps1`, and only if you also run Claude Code natively there. |
| **macOS** | `setup.sh` | No `python3` (it arrives with the Xcode command line tools), so the settings template is merged by `node` instead; no `timeout`, so the SessionStart hook bounds git itself rather than running unbounded. `/bin/bash` is 3.2 — nothing here uses a bash 4 feature. BSD `date`, `readlink` and `sort` differ from GNU and each use falls back. |
| **Windows** | `setup.ps1` | No `python3`, so the two session hooks install as their Node ports (`node` is required for them, and — with no `python3` here — for the `settings.json` template merge too; the git hooks, global `CLAUDE.md` and subagent files land without it). The git hooks are `sh` scripts, which Git for Windows runs through its own bundled shell — nothing extra to install. |

⚠️ **Honest status.** Linux and WSL are verified by running the installer end to end. macOS is
reviewed and its divergences are handled, but **it has not been run on a Mac yet**. `setup.ps1`
parses cleanly under Windows PowerShell 5.1 and every parameter binds, but **it has not been run
end to end on Windows yet** either. Treat those two as expected-to-work rather than proven, and if
you are the first to try one, the [Verify](claude-setup/SETUP.md#verify) steps are what to check.

## Quick start

```bash
git clone https://github.com/<owner>/sunstone sunstone   # the URL shown on this repository's page
cd sunstone
./setup.sh --memory-repo git@github.com:alice/my-memory.git   # or https://github.com/alice/my-memory.git
```

Then restart Claude Code, and check the result with `node claude-setup/scripts/memory-doctor.js`.
The first session after that restart pulls `my-memory`, injects its memory file, and the
SessionEnd hook starts committing whatever the session writes under the memory tree.

**No memory repo yet?** [Create one first](claude-setup/SETUP.md#the-memory-repo) — an empty
private repo on your host, then a short `git init` recipe fills it and pushes. `setup.sh` needs a
repo that already exists; it will clone one or adopt a local clone, but it will not create one
for you. A memory repo holding nothing but `claude-setup/memory/ABOUT-ME.md` is already complete.

**Give the repo in whichever URL form this machine can already authenticate**: the SSH form needs
an SSH key, the HTTPS form a credential helper or token, and `git ls-remote <url>` is the quick
way to check by hand. `git` itself must be on `PATH` — **both** installers check for it before
they print anything at all and stop with `nothing has been installed` if it is missing, rather
than surfacing a bare `git: command not found` halfway through with the hook files already on
disk. Past that, `setup.sh` resolves the memory repo *first*: the clone, or the check that a local
path is a git repo, happens before anything is written to the machine, so a bad URL or a missing
SSH key leaves the machine exactly as it was and there is nothing to undo.

`setup.sh` also reads the repo from `SUNSTONE_MEMORY_REPO` (the flag wins), and asks for it when
it is running in a terminal with neither. A git URL is cloned into `~/.ai-memory` — the one path
the hooks also try when `ai-memory-path` is missing — or into `--clone-to <dir>`; anything else is
treated as a local clone and used in place. Every flag that takes a value accepts both
`--flag <value>` and `--flag=<value>`. `--skip-memory` leaves `ai-memory-path` alone entirely, and
`--skip-overlay` installs the framework's trees only. The full table is in
[Flags](claude-setup/SETUP.md#flags).

Clone this repository as it is; fork it first only if you intend to change the framework, since
`setup.sh` records the checkout's location in `~/.claude/sunstone-path` and the SessionStart
notice hook runs `memory-doctor` from there.

Windows: `powershell -ExecutionPolicy Bypass -File setup.ps1 -MemoryRepo <url-or-path>`, and see
[Windows](claude-setup/SETUP.md#windows) for what differs.

## What gets installed

Eleven steps, run once from the framework root and again from your memory repo. In summary:

- **six hook scripts** in `~/.claude/hooks/` — `ai-memory-sync` and `ai-memory-commit` (each with
  its Node port), `memory-doctor-notice.sh`, and `context-mode-cache-heal.mjs` — producing five
  registered entries in `~/.claude/settings.json`: the three memory hooks, plus the settings
  template's own `PreToolUse` and `SessionStart` pair;
- **two git hooks** in `~/.git-hooks/` (and the clone-time template `~/.git-templates/hooks/`),
  reached by a global `core.hooksPath`;
- **`~/.claude/CLAUDE.md`**, rewritten on every run from the shipped `CLAUDE.global.md` — 27
  lines on where a memory goes, how to write one, and session continuity. Keep anything you want
  to survive a re-run in your memory repo's own copy, which wins over the framework's;
- **two subagent files** in `~/.claude/agents/` — ⚠️ both pin `model: fable`, the highest-priced
  tier, and every invocation bills there. Change the `model:` line or delete them if that is not
  what you want;
- **the two single-line path files** above;
- and a merge into `~/.claude/settings.json`. A framework-only install leaves that file holding
  **`hooks` and nothing else**: no `statusLine`, no `env`, and `permissions` is never touched.

Everything else the layout allows — skills, slash commands, a statusline, Codex and OpenCode
config, extra git hooks — is an empty slot that a framework-only install reports as `skipped`
until your memory repo fills it. The file-by-file list is [What setup
installs](claude-setup/SETUP.md#what-setup-installs), and
[Uninstall](claude-setup/SETUP.md#uninstall) undoes it. There are no opt-in flags for extra
behaviour: what lands is decided by what the two roots ship, not by switches.

`setup.sh` is idempotent and backs up anything it overwrites — the skills step is the one that
replaces a whole `<name>` directory rather than merging it, backing up a differing one beside
itself first. Re-running it is also how an update takes effect: **`git pull` on this repo changes
nothing that runs**, because every hook executes from a copy under `~/.claude/hooks/`,
`~/.git-hooks/` or `~/.git-templates/hooks/`. `memory-doctor`'s wiring check reports that drift
for the memory hooks under `~/.claude/hooks/`; it never reads the two installed git guards, so
drift in those is only ever fixed by re-running `setup.sh`.
On a machine already set up, a bare `./setup.sh` is enough — the memory repo is remembered.

```bash
cd sunstone && git pull && ./setup.sh
```

## What the hooks do

Every hook fails silently by design: no repo, no network, no `python3`, no `node` — the session
still starts and the commit or push still goes through. That is the right call for one session
and the wrong call for a month, which is what `memory-doctor` is for. **Why each hook is shaped
the way it is** — the failure each one prevents, and the cases each deliberately stands down for
— is in [Guard semantics](claude-setup/SETUP.md#guard-semantics) for the two git hooks, and in
[The doctor notice hook](claude-setup/SETUP.md#the-doctor-notice-hook) and [Checking it still
works](claude-setup/SETUP.md#checking-it-still-works) for the session hooks. Each script's own
header comment carries the same reasoning at the point of use.

| Hook | Event | What it does |
|---|---|---|
| `ai-memory-sync` | Claude Code **SessionStart** | Pulls the memory repo (`--ff-only` first, then `--rebase --autostash` if the branches diverged, aborting on conflict), pushes anything still unpushed, then injects `MEMORY_FILE` as context. Every network call is time-bounded. |
| `ai-memory-commit` | Claude Code **SessionEnd** | Commits anything changed under `MEMORY_DIR`, staged **by path** and nothing else, with `--no-verify`; then fires a detached, time-bounded push and returns without waiting for it. Refuses to run at all mid-merge, mid-cherry-pick, mid-rebase or on a detached HEAD. |
| `memory-doctor-notice` | Claude Code **SessionStart** | Injects a short notice from `memory-doctor --brief` — a summary line plus up to three WARN lines — at most once per 20 hours, and nothing at all when the stores are clean. Disable with `touch ~/.claude/.memory-doctor-off`. |
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
machine-local **working tier**, per-project **repo stores** and **duplicates** across stores —
[what each check catches](claude-setup/SETUP.md#checking-it-still-works).

## Layout

```
sunstone/
├── README.md
├── setup.sh                       # Linux / macOS / WSL — the installer these docs describe
├── setup.ps1                      # Windows equivalent (Node hook ports; keeps its UTF-8 BOM)
└── claude-setup/
    ├── SETUP.md                   # the runbook: flags, what lands where, verifying, uninstall
    ├── install.sh                 # optional: re-applies the ten non-memory steps alone
    ├── scripts/
    │   └── memory-doctor.js
    └── config/
        ├── hooks/
        │   ├── ai-memory-sync.sh / .js       # SessionStart (sh on POSIX, js on Windows)
        │   ├── ai-memory-commit.sh / .js     # SessionEnd
        │   ├── memory-doctor-notice.sh       # SessionStart notice
        │   └── context-mode-cache-heal.mjs   # unrelated to memory; ships with the hooks tree
        ├── git-hooks/
        │   ├── pre-commit                    # mixed-staging guard
        │   └── pre-push                      # force-push guard
        │                                     #   (a personal repo may add its own here — they
        │                                     #    install after these and override by filename)
        ├── merge-ai-memory-hook.py           # setup.sh: registers the memory hooks in settings.json
        ├── merge-claude-settings.mjs         # setup.ps1: the same, plus an optional statusLine
        ├── merge-settings-template.py / .mjs # the template merger (one tool, two ports)
        ├── agents/                           # architect.md, verify.md → ~/.claude/agents/
        ├── settings.json                     # template merged into ~/.claude/settings.json
        └── CLAUDE.global.md                  # → ~/.claude/CLAUDE.md; a memory-repo copy wins
```

There is no `skills/`, no `commands/`, no `plugins/` and no statusline in that tree. They are
overlay slots, filled by whatever your memory repo carries in the same relative layout.

`claude-setup/install.sh` is a separate, optional script that re-applies the ten non-memory steps
alone. It deliberately omits the eleventh, `git-hooks`, because installing hook files without
also setting `core.hooksPath` would put them on disk where nothing runs them — and it registers
no memory hooks, so on its own it leaves them installed and inert. `setup.sh` is what installs the
memory layer; see [The second installer](claude-setup/SETUP.md#the-second-installer-installsh).

Flags, prerequisites, the memory repo's layout and file format, the `sunstone.conf` reference,
what lands where file by file, how to verify a fresh install, Windows, troubleshooting and
uninstall are all in [claude-setup/SETUP.md](claude-setup/SETUP.md).
