# super-ai

A portable memory layer for Claude Code, plus the git hooks that keep it safe when several
Claude sessions write to the same repo at once.

Install it once per machine and every Claude Code session starts by pulling your private memory
repo and injecting one file from it into context. Anything a session writes back into the memory
tree is committed when the session ends and pushed the next time one starts. Two git hooks,
active only in repos you name ("repo-gated" below), stop the failure modes that concurrent
sessions actually produce: a rewritten shared history, and one session's `git add -A` sweeping
another session's edits into its own commit ("mixed staging" below: one commit touching both the
memory tree and files outside it). A read-only `memory-doctor` tells you when the
silent-by-design plumbing has silently stopped. The same memory repo can also carry your own
skills, slash commands, agents and hooks, and setup installs them alongside the framework's: see
[Carry your own skills, commands and hooks in the memory repo](#carry-your-own-skills-commands-and-hooks-in-the-memory-repo).

## The two-repo model

| Repo | What it holds | Who owns it |
|---|---|---|
| **super-ai** (this one) | Hooks, setup scripts, `memory-doctor`, docs. Nothing personal. | Public, shared |
| **your memory repo** | Your memory files, an optional `super-ai.conf`, and optionally your own skills, commands, agents and hooks in the framework's layout (the [overlay](#carry-your-own-skills-commands-and-hooks-in-the-memory-repo)). | You, private |

The framework never assumes a name, a path or a layout for your memory repo beyond what is in
[Bring your own memory](#bring-your-own-memory). Its clone path is recorded in the single-line
file `~/.claude/ai-memory-path`; every hook reads that file and exits silently when it is
missing, so a machine without a memory repo runs the hooks as no-ops. A second single-line file,
`~/.claude/super-ai-path`, records where this framework checkout lives, so hooks that are copies
can still find `memory-doctor` in it. Both files are read whole and trimmed, never split on
spaces, so a path containing a space works.

Throughout these docs the example memory repo is called `my-memory` and its owner is `alice`.

## Platforms

One installer per platform, both installing the same layer. `setup.sh` covers Linux, macOS and
WSL; `setup.ps1` covers native Windows and is described under [Windows](#windows).

| | Installer | What that platform lacks by default, and what happens |
|---|---|---|
| **Linux** | `setup.sh` | Nothing in particular. This is the most-exercised path. |
| **WSL** | `setup.sh` | Treated as Linux, and it is one — a WSL checkout is a Linux checkout. Only the Windows side of the same machine needs `setup.ps1`, and only if you also run Claude Code natively there. |
| **macOS** | `setup.sh` | No `python3` (it arrives with the Xcode command line tools), so the settings template is merged by `node` instead; no `jq`, so the statusline renders empty and setup says so; no `timeout`, so the SessionStart hook bounds git itself rather than running unbounded. `/bin/bash` is 3.2 — nothing here uses a bash 4 feature. BSD `date`, `readlink` and `sort` differ from GNU and each use falls back. |
| **Windows** | `setup.ps1` | No `python3`, so the three session hooks install as their Node ports (`node` is required for them; the rest of the install proceeds without it). The git hooks are `sh` scripts, which Git for Windows runs through its own bundled shell — nothing extra to install. |

⚠️ **Honest status.** Linux and WSL are verified by running the installer end to end. macOS is
reviewed and its divergences are handled, but **it has not been run on a Mac yet**. `setup.ps1`
parses cleanly under Windows PowerShell 5.1 and every parameter binds, but **it has not been run
end to end on Windows yet** either. Treat those two as expected-to-work rather than proven, and if
you are the first to try one, the [Verify](claude-setup/SETUP.md#verify) steps are what to check.

## Quick start

```bash
git clone https://github.com/<owner>/super-ai super-ai   # the URL shown on this repository's page
cd super-ai
./setup.sh --memory-repo git@github.com:alice/my-memory.git   # or https://github.com/alice/my-memory.git
```

No memory repo yet? [Create one first](claude-setup/SETUP.md#the-memory-repo) — an empty private
repo on your host, then a short `git init` recipe to fill it. `setup.sh` needs a repo that already
exists; it will clone one or adopt a local clone, but it will not create one for you.

Clone this repository as it is; fork it first only if you intend to change the framework, since
`setup.sh` records the checkout's location in `~/.claude/super-ai-path` and the SessionStart
notice hook runs `memory-doctor` from there. Give the memory repo in whichever URL form this
machine can already authenticate: the SSH form needs a GitHub SSH key, the HTTPS form a
credential helper or token. `git` itself must be on `PATH`; **both** installers check for it
before they print anything at all and stop with `nothing has been installed` if it is missing,
rather than surfacing a bare `git: command not found` halfway through with the hook files already
on disk. `setup.ps1` refuses on exactly the same terms as `setup.sh` — there is no softer Windows
path through a missing `git`.
Past that, `setup.sh` resolves the memory repo *first* — the clone, or the check that a local
path is a git repo, happens before anything is written to the machine — so a bad URL or a missing
SSH key stops setup the same way, and there is nothing to undo. `git ls-remote <url>` is still the
quick way to check the auth by hand.

Then restart Claude Code. The first session after that pulls `my-memory`, injects its memory
file, and the SessionEnd hook starts committing whatever the session writes under the memory
tree.

`setup.sh` accepts the memory repo three ways; the flag wins over the environment. Every flag
that takes a value accepts both `--flag <value>` and `--flag=<value>`:

| Form | Example |
|---|---|
| flag, git URL | `./setup.sh --memory-repo git@github.com:alice/my-memory.git` — cloned into `~/.ai-memory` (the one path the hooks also try when `ai-memory-path` is missing), or into `--clone-to <dir>` / `--clone-to=<dir>`; an existing clone there is reused |
| flag, local path | `./setup.sh --memory-repo ~/src/my-memory` (or `--memory-repo=~/src/my-memory`) — a clone you already have, used in place |
| environment | `SUPER_AI_MEMORY_REPO=<url-or-path> ./setup.sh` |

With none of these, `setup.sh` asks for the repo when it is running in a terminal (Enter keeps
the clone already recorded in `~/.claude/ai-memory-path`, or skips when there is none). Without a
terminal it keeps the recorded clone, or installs the hooks and leaves the memory features
dormant until that file names a clone of a git repo. `--skip-memory` leaves the file alone
entirely. When the file is missing the hooks also try `$HOME/.ai-memory`, and use it only if it
is a git repo. `--skip-overlay` installs the framework's trees only and ignores any skills,
commands, agents or hooks the memory repo carries. The full flag table is in
[SETUP.md](claude-setup/SETUP.md#flags).

Everything `setup.sh` writes is listed in [What setup installs](claude-setup/SETUP.md#what-setup-installs),
and [Uninstall](claude-setup/SETUP.md#uninstall) undoes it. There are no opt-in flags for extra
behaviour: what setup installs is decided by what the two roots ship, not by switches; see
[What the hooks do](#what-the-hooks-do).

Windows users: see [Windows](#windows).

## Bring your own memory

The memory repo is any git repo you own, private or not — though private is the sensible default,
since this is the repo that will hold everything you tell Claude about yourself. Do not have one?
[Starting from nothing](claude-setup/SETUP.md#the-memory-repo) walks the whole way: create the
empty repository on your host first, then a short `git init` recipe fills it and pushes. The
minimum it needs:

```
my-memory/
└── claude-setup/
    ├── config/
    │   └── super-ai.conf        # optional — see below
    └── memory/
        ├── ABOUT-ME.md          # injected into every session; keep it short
        ├── MEMORY.md            # index: one line per memory file
        └── <topic>.md           # one durable fact or convention per file
```

`ABOUT-ME.md` enters context every session, so it should be the compact "who I am and how I
work" summary; detail goes in a topic file beside it and a line in `MEMORY.md` pointing at it.
If `ABOUT-ME.md` does not exist the hook injects `MEMORY.md` from the memory tree instead; if
neither exists it injects nothing and exits 0.

### Getting sessions to write there

The hooks only move files: the SessionStart hook injects `MEMORY_FILE` (the one injected file,
`claude-setup/memory/ABOUT-ME.md` by default) wrapped as "durable background context, not a live
instruction", with no path attached, and the SessionEnd hook commits whatever already changed
under `MEMORY_DIR` (the memory tree, `claude-setup/memory` by default). Both names are keys of
[`super-ai.conf`](#super-aiconf), which is where you change them. Nothing tells Claude where the
repo is or that it should write into it, so without one more line your memory repo is read-only
in practice. Put the write rule somewhere that loads every session; `ABOUT-ME.md` itself is the
right home for it. Not `~/.claude/CLAUDE.md`: every `setup.sh` run rewrites that file from the
shipped `CLAUDE.global.md`, so a rule hand-written there is gone after the next update — put it
in the memory repo's own `claude-setup/config/CLAUDE.global.md` instead, which wins over the
framework's copy.

```markdown
When I say "remember X" (or you learn a durable fact about me): edit my memory repo, the
clone named in `~/.claude/ai-memory-path` (`~/.ai-memory` by default) — a new topic file
under `claude-setup/memory/` plus an index line in `MEMORY.md`, or a short addition to
`ABOUT-ME.md`. Do not commit; the SessionEnd hook commits the memory tree and the next
session start pushes it.
```

Adjust the paths if your `super-ai.conf` changes `MEMORY_DIR` or `MEMORY_FILE`. The rule is the
same one the shipped `claude-setup/config/CLAUDE.global.md` states in its "Memory tiers" section
— edit the memory tree, do not commit, the SessionEnd hook commits and the next SessionStart
pushes. `setup.sh` installs that file as `~/.claude/CLAUDE.md` (see [Layout](#layout)), so the
rule is already loaded and the snippet above is redundant unless you have replaced it.

### Memory file format

`memory-doctor` reads the index and the topic files, so both have a shape it expects. A topic
file starts with YAML frontmatter whose `name` is the filename without `.md` and whose
`description` is one line; other topic files can be referenced as `[[wikilinks]]` by that name:

```markdown
---
name: coding-style
description: How I format code and name things; applies in every repo.
---

# Coding style

Two-space indent, one exported symbol per file. Editor side of this is in [[editor-setup]].
```

An index line in `MEMORY.md` is a markdown **list item containing a markdown link** to the file,
relative to the index. A line that names the file without linking it does not count:

```markdown
- [coding-style](coding-style.md) — how I format code and name things
```

Severity: a link to a file that does not exist is an ERROR; a topic file with no index line, one
linked twice, or a frontmatter `name` that disagrees with the filename is a WARN; missing
frontmatter, a missing `description` or a `[[wikilink]]` to a file that does not exist is an INFO.
`ABOUT-ME.md`, `MEMORY.md` and a `README.md` in the tree are exempt from the index check, as is
anything you name in `MEMORY_META_FILES` (below).

### `super-ai.conf`

Optional. Lives at `<memory-repo>/claude-setup/config/super-ai.conf`. POSIX `KEY=VALUE` lines.
Whitespace around the `=` is accepted, so `KEY = value` and `KEY=value` are the same line; a value
may be double-quoted, in which case the quotes are stripped and the value runs to the next `"`
(a `#` inside it is part of the value); surrounding whitespace is **trimmed, never deleted**, so a
value containing a space survives intact; and `#` starts a comment only at the start of a line or
after whitespace — so `KEY=a#b` is the value `a#b` while `KEY=a #b` is the value `a`. The last
line for a key wins, and an **empty value unsets the key rather than setting it to nothing**: it
falls back to the default in the table below, which is why `KEY=` and `KEY= # commented out` and
deleting the line are three spellings of one thing. All nine
readers apply that one rule — both installers, the two shell session hooks, their two Node ports,
the two git guards and `memory-doctor` — which is the point: a guard that read a different
`MEMORY_DIR` than the hook it is guarding would go quiet on exactly the tree being written. The
file is parsed, never sourced, so it cannot run anything. Every consumer works with the file
absent using these defaults:

| Key | Default | Meaning |
|---|---|---|
| `MEMORY_DIR` | `claude-setup/memory` | The memory tree, relative to the memory repo. The SessionEnd commit stages **only** paths under it. |
| `MEMORY_FILE` | `claude-setup/memory/ABOUT-ME.md` | The one file injected into every session, relative to the memory repo. Falls back to `MEMORY.md` inside `MEMORY_DIR`. |
| `MEMORY_REPOS` | the memory repo's own name (below) | Space-separated repo names whose commits get the mixed-staging guard (`pre-commit`). |
| `GUARDED_REPOS` | `super-ai <that same name>` | Space-separated repo names whose pushes get the force-push / history-rewrite guard (`pre-push`). |
| `MEMORY_INDEX` | `claude-setup/memory/MEMORY.md` | The index `memory-doctor` checks: one line per memory file, no dangling links. |
| `MEMORY_META_FILES` | empty | Space-separated basenames inside `MEMORY_DIR` that are structure, not memories (a `TEMPLATE.md`, say). `memory-doctor` never flags them as unindexed and never counts them. The basenames of `MEMORY_INDEX` and `MEMORY_FILE`, and `README.md`, are always in this set. Read only by `memory-doctor`. |
| `PROJECT_ROOTS` | empty | Space-separated directories (`~` allowed) under which `memory-doctor` may look for `<project>/docs/ai-memory/` stores when a working-tier slug resolves to a project inside them. Empty keeps the slug resolution alone, with no extra scanning. Read only by `memory-doctor`. |

⚠️ The four list-valued keys — `MEMORY_REPOS`, `GUARDED_REPOS`, `MEMORY_META_FILES` and
`PROJECT_ROOTS` — are **space-separated**, so an entry that itself contains a space cannot be
expressed in them. That is inherent to the format, not a bug; a repo or directory whose name has a
space in it can only be reached by the derived default, which is compared whole and never split.

A repo's name, everywhere in this framework, is the basename of `git remote get-url origin` with a
trailing `.git` stripped — so `git@github.com:alice/my-memory.git` is the repo `my-memory`. The
remote is preferred over the folder because a clone whose remote was renamed keeps sitting in a
folder called by the old name, so folder names lie. A repo with **no `origin` at all** has no
renamed remote to be misled by, and there the basename of the worktree directory is used instead:
that is how the two defaults above are filled in, and it is also how `pre-commit` names the repo
it is about to guard, so a local-only memory repo is guarded rather than silently skipped. With
that, a config of

```sh
# super-ai.conf
MEMORY_REPOS="my-memory"
GUARDED_REPOS="super-ai my-memory team-notes"
```

guards commits in `my-memory` against mixed staging and refuses history rewrites on pushes to
`super-ai`, `my-memory` and `team-notes`. Repos not named are untouched by the guards.

## Carry your own skills, commands and hooks in the memory repo

The framework ships plumbing, not opinions: no skills, no slash commands, and a small set of
agents and config. Your own live in the memory repo, in the **same relative layout** as this
checkout, and `setup.sh` treats that repo as a second install root — an *overlay* — applied
**after** the framework root. Every install step runs the same loop: *for each root in
`<framework>` then `<memory repo>`: if the tree exists under that root, install it and print
`<step>: from <root>`, otherwise print `skipped`*. Identical semantics for both roots; a tree the
framework does not ship is simply contributed by the memory repo alone, and on a name clash across
roots yours is the copy that ends up on disk. It gets there by the framework's copy never being
installed at all, not by yours overwriting it a moment later: the framework step reports
`N overridden by the personal root` and writes nothing for those names, which is what keeps a
re-run from leaving a `.bak.<timestamp>` behind for every file both roots happen to ship.

| Tree under either root | Installed to |
|---|---|
| `skills/<name>/` | `~/.claude/skills/<name>`, `~/.codex/skills/<name>`, `~/.config/opencode/skills/<name>`. ⚠️ A skill is replaced **whole** (`rm -rf` then `cp -r`), never merged, so an older version cannot strand files the new one dropped. An existing `<name>/` that **differs** is backed up beside itself first — including a skill you wrote by hand under the same name. An identical one is left alone, so re-runs leave no clutter |
| `agents/AGENTS.md`, `agents/CLAUDE.md` | `~/AGENTS.md`, `~/CLAUDE.md` (an existing file is backed up first). `~/.claude/CLAUDE.md` comes from `claude-setup/config/CLAUDE.global.md` instead — `agents/CLAUDE.md` only reaches it on a pair of roots where neither ships a `CLAUDE.global.md`, and this framework always does |
| `config/codex-config.toml`, `config/codex-hooks.json`, `config/codex-AGENTS.md`, `config/codex-rules/` | the matching files under `~/.codex/` |
| `config/opencode-config.jsonc` | `~/.config/opencode/opencode.jsonc` |
| `plugins/*.js` | `~/.opencode/plugins/` |
| `claude-setup/commands/*.md` | `~/.claude/commands/` |
| `claude-setup/config/agents/*.md` | `~/.claude/agents/` |
| `claude-setup/config/hooks/*` | `~/.claude/hooks/`, made executable. **Copied, not registered**: a hook script from the memory repo runs only if the memory repo's `settings.json` (next row) registers it. |
| `claude-setup/config/settings.json` | merged into `~/.claude/settings.json` by the template merger (below); the memory repo's merge runs after the framework's. |
| `claude-setup/config/CLAUDE.global.md` | wherever the framework's `CLAUDE.global.md` is used; if the memory repo has one, it wins. |

`--skip-overlay` (`-SkipOverlay` on Windows) applies the framework root only. The summary at
the end of setup lists, per root, what was installed. The memory features do not depend on any of
this; a memory repo that holds nothing but `claude-setup/memory/` is complete.

A minimal overlay, on top of the memory tree shown above:

```
my-memory/
├── skills/
│   └── release-notes/
│       └── SKILL.md
└── claude-setup/
    ├── commands/
    │   └── standup.md                 # → ~/.claude/commands/standup.md
    ├── memory/ ...
    └── config/
        ├── super-ai.conf
        ├── hooks/
        │   └── chime.sh               # → ~/.claude/hooks/chime.sh (copied, +x)
        └── settings.json              # registers chime.sh under the event it belongs to
```

with a `settings.json` of

```json
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "bash ~/.claude/hooks/chime.sh" } ] } ] } }
```

**The template merger** is one script in two identical ports,
`claude-setup/config/merge-settings-template.py` and `merge-settings-template.mjs`, run as
`<port> <settings.json> <template.json>`. It is idempotent: for each event under the template's
`hooks` it appends each entry whose command's script basename is not already registered under
that event (the identity rule `merge-ai-memory-hook.py` uses, so `~/.claude/hooks/x.sh` and an
absolute path to the same `x.sh` are one hook); it copies `statusLine` and `env` keys only where
the target has none; it **never touches `permissions`**; it creates the file when it is missing;
and it exits 0 printing one line per change, or `no change`. Commands may use `~` and are
written as they are.

## What the hooks do

Every hook fails silently by design: no repo, no network, no `python3`, no `node` — the session
still starts and the commit or push still goes through. That is the right call for one session
and the wrong call for a month, which is what `memory-doctor` is for.

| Hook | Event | What it does | Why it exists |
|---|---|---|---|
| `ai-memory-sync.sh` | Claude Code **SessionStart** | Pulls the memory repo (`--ff-only` first, then `--rebase --autostash` if the branches diverged, aborting on conflict), pushes whatever the last session committed, then injects `MEMORY_FILE` as context. Every network call is time-bounded, and where neither `timeout` nor `gtimeout` exists (stock macOS, or a stripped `PATH`) the hook runs git in the background and kills it on time itself rather than letting it run unbounded. | Memory written on one machine must be present on the next before the session starts working; divergence is the normal case with more than one writer, and ff-only alone stops syncing forever without saying so. A remote that accepts the connection and then never answers would otherwise hang the start of the session for as long as you are willing to wait. |
| `ai-memory-commit.sh` | Claude Code **SessionEnd** | Commits anything changed under `MEMORY_DIR`, staged **by path** and nothing else, with `git commit --no-verify`. Never pushes. Refuses to run at all mid-merge, mid-cherry-pick or mid-rebase, and on a **detached HEAD**; and if the commit fails anyway it unstages the memory tree again. | An auto-commit is fine for a memory store and unacceptable for source, and the repo may hold both. Pushing is deferred to the next SessionStart so ending a session is never slower. `--no-verify` for the same reason: no `pre-commit` hook — the guard, a repo-local husky, a linter — may block or slow a session's end, and the commit is by-path inside `MEMORY_DIR`, which is exactly what the guard would accept anyway. It also means a personal message hook does not run on these commits; their message is fixed and carries no trailer. A commit on a detached HEAD would sit on no branch — the next checkout loses the session's memory and the sync hook has no branch to push it from — so refusing leaves the files on disk, where the next session picks them up. The same reasoning covers a failed commit: the usual causes (no committer identity, a signing key this non-interactive hook cannot unlock, a locked index) outlast the session, so leaving the tree staged would only feed it into your next unrelated commit. |
| `memory-doctor-notice.sh` | Claude Code **SessionStart** | Runs `memory-doctor --brief` from the framework checkout recorded in `~/.claude/super-ai-path` (the single-line file `setup.sh` writes with the directory it was run from) and injects at most one line, at most once per 20 hours, and nothing at all when the stores are clean or no `node` can be found (it looks past `PATH` at the usual nvm and Homebrew locations before giving up, because `node` is often an nvm shell function a hook never sees). Disable with `touch ~/.claude/.memory-doctor-off`. | A maintenance chore that depends on a human remembering it never happens; this one retires itself once there is nothing to say. |
| `pre-push` | git, via global `core.hooksPath` | In `GUARDED_REPOS`, refuses any push whose remote tip is not an ancestor of what is being sent, any branch deletion, and any push whose remote tip is not in the local object store at all (`git fetch` first — it cannot judge what it does not have). Chains to a repo-local `pre-push` everywhere, with stdin buffered so the chained hook still gets it. Override: `ALLOW_FORCE_PUSH=1 git push`. | Git does not tell a hook whether `--force` was passed, so the hook detects the effect. A rewrite in a repo several live sessions push to strands the commits the others already made. |
| `pre-commit` | git, via global `core.hooksPath` | In `MEMORY_REPOS`, refuses a commit that stages paths both inside and outside `MEMORY_DIR` (rename detection off, so a file moved out of the tree still counts as both). **Stands down entirely while git is mid-merge, mid-cherry-pick, mid-revert or mid-rebase** — the same markers the SessionEnd hook checks, so the two agree on what "git is busy" means. Chains to a repo-local `pre-commit` in every repo, guarded or not. Override: `ALLOW_MIXED_COMMIT=1 git commit`. | One session running `git add -A` sweeps another session's uncommitted edits into its own commit. That push fast-forwards cleanly, so nothing else ever catches it. A staged set that *git* composed is not that failure, though, and blocking one halfway through a conflict resolution would refuse a commit you did not compose, at the worst possible moment. |

Both hooks chain to the repo's own `.git/hooks/<hook>` in **every** repo, guarded or not, because
a global `core.hooksPath` means git no longer runs a repo's own hooks by itself. That matters
most for `pre-commit`, the hook real projects install (husky, lint-staged, pre-commit.com); the
header of `claude-setup/config/git-hooks/pre-commit` puts it this way:

> ⚠️ ALWAYS CHAINS, guarded repo or not. Setting a global core.hooksPath makes git ignore every
> repo's .git/hooks, and `pre-commit` is the hook real projects actually install (husky,
> lint-staged, commitlint, pre-commit.com). If the unguarded repos exited here without chaining,
> running setup.sh would silently switch off every one of those hooks on the machine. So every
> exit path below goes through chain_local, exactly as pre-push does — the memory guard is an
> extra check in front of the repo's own hook, never a replacement for it.

Read that header before changing either hook.

`claude-setup/config/git-hooks/` is an overlay tree like every other one, so **your memory repo
can ship git hooks of its own** — either new ones, or a file named `pre-commit`/`pre-push` that
replaces the guard shipped here. They install from the personal root, after this one, and win.

That is deliberately how anything opinionated about commit *content* is meant to travel. This
framework ships only the two conf-driven guards above, because a hook that rewrites every commit
message on a machine is a policy, and a framework other people install should not hold an opinion
about it. Put such a hook in your own repo and carrying the file **is** the opt-in — no flag is
needed, and nobody else inherits your policy by installing this.

### memory-doctor

```bash
node claude-setup/scripts/memory-doctor.js            # human report
node claude-setup/scripts/memory-doctor.js --verbose  # list every item
node claude-setup/scripts/memory-doctor.js --json     # machine-readable
node claude-setup/scripts/memory-doctor.js --brief    # a short notice, or nothing (what the notice hook uses)
```

Read-only. Exit code 1 when there is an ERROR, 0 otherwise, so it works as a CI or pre-push
gate. It checks the **wiring** (`ai-memory-path`, the installed copies of the two memory hooks,
their registration in `settings.json`, drift from the repo copy), **sync** state (no upstream, unpushed backlog,
uncommitted memory writes, a repo left mid-rebase), the **index** (`MEMORY_INDEX` links that
point nowhere, files with no index line, one file indexed twice), file **hygiene**, the
machine-local **working tier** described below, per-project **repo stores** never committed,
and **duplicates** across stores.

## Where a memory goes

Three homes; they are not interchangeable, and writing to the wrong one is how a fact ends up
stored twice or lost on the next machine.

| What it is | Where it goes |
|---|---|
| **About you, your machine, your tools, how you work** — true in every repo | `MEMORY_DIR` in your memory repo, indexed in `MEMORY_INDEX`. Synced to every machine by the hooks. |
| **The most compact "who I am"** — needed in literally every session | `MEMORY_FILE`. It is injected every session, so keep it short; detail goes in a topic file beside it. |
| **Facts about one codebase** — a bug it keeps having, its deploy, its conventions | `<that repo>/docs/ai-memory/*.md`, committed with the code. It travels with the project and any tool that opens the repo can read it. |

Claude Code's own auto-memory, `~/.claude/projects/<slug>/memory/`, is a **working tier, not a
home**. It is the only store that loads automatically, which makes it the tempting default, but
it is machine-local and syncs nowhere. Write there during a session if you like, then drain it:
promote each file to one of the two homes above and delete it. `memory-doctor` lists what is
sitting there and which store each file belongs in.

The test to apply: *would this still be true in a different repo?* Yes → memory repo. No → that
repo's `docs/ai-memory/`. Before writing a new memory, grep both homes for the topic.

## Updating

```bash
cd super-ai && git pull && ./setup.sh
```

**Pulling this repo does not update anything that is installed.** The hooks run from copies:
`~/.claude/hooks/` for the Claude Code hooks, `~/.git-hooks/` (and the clone-time template
`~/.git-templates/hooks/`) for the git hooks. A hook fixed in the repo is still the old hook on
disk until `setup.sh` runs again. `memory-doctor`'s wiring check reports the drift. `setup.sh`
is idempotent and backs up anything it overwrites — with the skills step, which replaces a whole
`<name>` tree without one, the single exception; the memory repo argument is remembered in
`~/.claude/ai-memory-path`, so a bare `./setup.sh` is enough on a machine that is already set up.

## Windows

`setup.ps1` is the PowerShell equivalent:

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1 -MemoryRepo git@github.com:alice/my-memory.git
```

`SUPER_AI_MEMORY_REPO` works there too. Windows has no `python3` by default, so the Claude Code
hooks are installed as their Node ports (`ai-memory-sync.js`, `ai-memory-commit.js`) and Node
is required, and the doctor notice is installed when `node` is present. The git hooks are POSIX
`sh` scripts; Git for Windows runs them through its bundled shell, so they need no extra install.
`ai-memory-path` is written with forward slashes.
The statusline is the one place the two installers differ in kind rather than in port:
`setup.ps1` installs `~/.claude/statusline-command.js` and points the `statusLine` key at that,
where `setup.sh` installs the shell script `~/.claude/statusline-command.sh` and its settings
template names that. Either way the key and the script it names are installed together, by the
same run. `-MemoryRepo`, `-CloneTo`, `-SkipMemory` and `-SkipOverlay` mirror the shell flags.

## Layout

```
super-ai/
├── README.md
├── setup.sh                       # Linux / macOS / WSL — the installer these docs describe
├── setup.ps1                      # Windows equivalent (Node hook ports + a statusline)
├── plugins/
│   └── graphify.js                # OpenCode plugin; the overlay step copies plugins/*.js to ~/.opencode/plugins/
└── claude-setup/
    ├── SETUP.md                   # the runbook: flags, what lands where, verifying, uninstall
    ├── install.sh                 # optional: re-applies the non-memory steps alone (see SETUP.md)
    ├── scripts/
    │   └── memory-doctor.js
    └── config/
        ├── hooks/
        │   ├── ai-memory-sync.sh / .js       # SessionStart (sh on POSIX, js on Windows)
        │   ├── ai-memory-commit.sh / .js     # SessionEnd
        │   ├── memory-doctor-notice.sh       # SessionStart notice
        │   └── context-mode-cache-heal.mjs   # unrelated to memory; install.sh copies it
        ├── git-hooks/
        │   ├── pre-commit                    # mixed-staging guard
        │   └── pre-push                      # force-push guard
        │                                     #   (a personal repo may add its own here — they
        │                                     #    install after these and override by filename)
        ├── merge-ai-memory-hook.py           # setup.sh: registers the memory hooks in settings.json
        ├── merge-claude-settings.mjs         # setup.ps1: same, plus the statusLine key
        ├── merge-settings-template.py / .mjs # the template merger (one tool, two ports) used for settings.json templates from either root
        ├── agents/                           # architect.md, verify.md subagent files → ~/.claude/agents/
        ├── settings.json                     # template merged into ~/.claude/settings.json
        ├── CLAUDE.global.md                  # → ~/.claude/CLAUDE.md (every setup.sh run); a memory-repo copy wins
        ├── statusline-command.sh             # → ~/.claude on every setup.sh run; needs jq
        └── statusline-command.js             # the Node port setup.ps1 installs instead
```

Two installers live here. **`setup.sh` / `setup.ps1` is the one every section above describes**:
the memory layer, the two git guards and the overlay. Its overlay steps already change files you
may already have. It **replaces `~/.claude/CLAUDE.md`** with the shipped `CLAUDE.global.md` on
every run, `--skip-overlay` included, keeping the previous file as `CLAUDE.md.bak.<timestamp>`;
it **installs `~/.claude/statusline-command.sh`** (marked executable, and it wants `jq` at
runtime — without `jq` the statusline renders empty); and it **merges the shipped `settings.json`
template** into `~/.claude/settings.json` through the template merger — which adds
`env.DISABLE_AUTOUPDATER=1`, a `statusLine` pointing at that same
`~/.claude/statusline-command.sh`, a `PreToolUse` hook that points Bash searches at a
`graphify-out/` graph when one exists, and a `SessionStart` entry for
`context-mode-cache-heal.mjs`, each only where you have nothing equivalent, and leaves
`permissions` alone.

The statusline script and the `statusLine` key are installed by the same run on purpose: whoever
merges that template has to put the script on disk too, or a plain run ends with the key naming a
file that is not there. The merger itself ships as two ports of one tool, so `python3` **or**
`node` is enough for the template merge; only registering the three memory hooks in
`settings.json` still needs `python3`, and without it setup prints the three lines to add by hand.

`claude-setup/install.sh` is separate and optional, and it exists to re-apply the extras alone. It
walks the same two roots and runs the same ten non-memory steps in the same order — the
statusline, `skills/`, `agents/{AGENTS,CLAUDE}.md`, the Codex tree, the OpenCode tree and its
`plugins/*.js`, `claude-setup/commands/*.md`, the subagent files in `claude-setup/config/agents/`,
the whole `claude-setup/config/hooks/` directory, the same template merge and the same
`CLAUDE.global.md` — so on a machine `setup.sh` has already run
it changes nothing.

The one step it does **not** run is `git-hooks`. `setup.sh` has eleven steps per root; this has
ten. Installing hook files without also setting `core.hooksPath` would put them on disk where
nothing runs them, and pointing global git config at a directory is a change to your machine
rather than an extra — which is the line this script does not cross. Run `setup.sh` for the
guards. Expect its output to look like a full install anyway: each step still prints
`<step>: from <root>`, because that line names the root the files came from rather than claiming
they were rewritten, and only the settings merge prints `no change` in so many words.

What it does not do is the memory layer. It **copies** the three memory hook scripts —
`ai-memory-sync.sh`, `ai-memory-commit.sh` and `memory-doctor-notice.sh` are simply part of the
hooks directory it ships, and its own step label says `(copied, not registered)` — but it never
registers them in `settings.json`, and it writes neither `~/.claude/ai-memory-path` nor
`~/.claude/super-ai-path`. Run on its own it therefore leaves the memory hooks on disk and inert,
which is precisely the "installed and dead" state `memory-doctor`'s wiring check exists to report.
Nothing in the memory layer needs this script; `setup.sh` is what installs that. Details in
[SETUP.md](claude-setup/SETUP.md#the-second-installer-installsh).

Full install details, verification steps, troubleshooting and uninstall are in
[claude-setup/SETUP.md](claude-setup/SETUP.md).
