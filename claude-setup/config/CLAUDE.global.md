# Memory tiers — decide WHERE before writing a memory file

Durable memory lives in git, not in the tool. The SessionStart hook (`ai-memory-sync`) pulls the user's personal repo (its clone path is the one line in `~/.claude/ai-memory-path`, `~/.ai-memory` by default) and injects one file — `MEMORY_FILE`, default `claude-setup/memory/ABOUT-ME.md` — into every session. The SessionEnd hook (`ai-memory-commit`) commits anything written under the memory tree (`MEMORY_DIR`, default `claude-setup/memory`) and the next session start pushes it. `memory-doctor` checks that the index (`MEMORY_INDEX`, default `claude-setup/memory/MEMORY.md`) lists every memory file exactly once. All of these paths can be changed in `<personal-repo>/claude-setup/config/super-ai.conf`.

There are three homes and they are not interchangeable:

| What it is | Where it goes |
|---|---|
| **The user, their machine, their tools, how they code** — true in every repo | `<personal-repo>/<MEMORY_DIR>/*.md`, one line per file in `MEMORY.md` there. Git-synced to every machine. |
| **The most compact "who the user is"** — needed in literally every session | `MEMORY_FILE` (`ABOUT-ME.md`). It enters context every session, so keep it short; detail goes in a granular file beside it. |
| **Facts about one codebase** — a bug it keeps having, its deploy, its conventions | `<repo>/docs/ai-memory/*.md`, committed with the code. It travels with the project and any tool that opens the repo can read it. |

**`~/.claude/projects/<slug>/memory/` is a working tier, not a home.** It is the only store that auto-loads, which makes it the tempting default — but it is machine-local and syncs nowhere. Write there during a session if you like, then drain it: promote each file to one of the homes above and delete it. Its `MEMORY.md` should read as an index pointing at the real stores.

Test to apply: *would this still be true in a different repo?* Yes → personal repo. No → that repo's `docs/ai-memory/`.

**Before writing a new memory, grep both homes for the topic.** Writing to the auto-loaded tier without checking the synced one is how the same fact ends up stored twice.

## Writing a memory

When the user says "remember X" (or you learn a durable fact about them): edit the personal repo — a new topic file under `MEMORY_DIR` plus an index line in `MEMORY.md`, or a short addition to `ABOUT-ME.md`. **Do not commit or push memory edits by hand.** The SessionEnd hook commits the memory tree and the next session start pushes it; that is what makes the memory appear on every other machine. Hand commits in the personal repo are for its non-memory files (scripts, config, docs) — and `pre-commit` there refuses a commit that stages paths both inside and outside `MEMORY_DIR`, so keep the two kinds of change in separate commits.

`<repo>/docs/ai-memory/*.md` is ordinary source: commit it with the code it describes, as you would any other file in that repo.

## Session continuity

Skills, roles, and decisions persist for the entire session. Do not abandon them as the conversation grows. On resume, check what the previous session left (the memory files above, any session-history tool you have) before asking the user what you were working on.

# Optional tools

None of the following is installed by this framework. Apply a section only if the tool is actually present on this machine; otherwise ignore it.

## If you use context-mode (MCP)

The plugin routes bulky output through a sandbox so it does not flood the context window. When its tools (`ctx_*`) are available:

- Analyze/count/filter/compare/search/parse/transform data by **writing code** via `ctx_execute(language, code)` and printing only the answer. Do not read raw data into context. One script replaces ten tool calls.
- The plugin intercepts `curl`, `wget`, `WebFetch` and inline HTTP calls in code; use `ctx_fetch_and_index(url, source)` then `ctx_search(queries)` instead, and do not retry the blocked form.
- Bash output over ~20 lines, `Read` for analysis rather than editing, and broad `grep` go through `ctx_batch_execute`, `ctx_execute_file(path, language, code)` and `ctx_execute(language: "shell", ...)` respectively.
- Gather with `ctx_batch_execute(commands, queries)` (one call replaces many), follow up with `ctx_search(queries: [...])` as an array, index long-lived material with `ctx_index(content, source)` under a descriptive source label.
- For multi-URL fetches or multi-API calls pass `concurrency: N` (1-8): 4-8 for I/O-bound work, 1 for CPU-bound work or commands sharing state; cap `gh` calls at 4.
- Session history is searchable: `ctx_search(queries: ["summary"], source: "compaction", sort: "timeline")` for what you were working on, `source: "decision"`, `"rejected-approach"`, `"constraint"` for the rest. Search before asking; zero results means a fresh session.
- `ctx stats` / `ctx doctor` / `ctx upgrade` / `ctx purge` map to the MCP tools of the same name (`ctx purge` with `confirm: true`, and warn first — it wipes the knowledge base). The knowledge base survives `/clear` and `/compact`.

## If you use graphify

If a repo has `graphify-out/GRAPH_REPORT.md`, read it before searching raw files for architecture questions; after modifying code run `graphify update .` (AST-only, no API cost). If the graphify skill is installed and the user types `/graphify`, invoke it before doing anything else.

