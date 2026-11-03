---
description: Supermode - plan once, then run the whole task unattended; opus orchestrates, agents get a model per job and hand over at 70%
argument-hint: <the task>
---

Supermode is ON for this task: $ARGUMENTS

If no task was given, take the top open item of the work queue (WORK-QUEUE.md, or the repo's docs/NOW.md) and say which one you took.

How supermode works - follow all of it:

1. **Plan once, then do ALL of it unattended.** No check-ins between steps. Stop only for a password or login, money, an irreversible or outward-facing act, or a taste call - and then as ONE plain question saying why only the user can decide.
2. **This session runs on opus and orchestrates.** Big reads, broad searches and whole slices go to Agent-tool subagents; take back conclusions, not files. Keep this session's context small.
3. **Pass a model on EVERY agent** - aliases only, so it is always the newest of that family:
   | The job | Model |
   |---|---|
   | planning, architecture, verifying a plan or claim | `opus` - always |
   | second opinion, debugging after 2 failures, security or money | `opus` |
   | ambiguous work, judgement calls, reviews | `opus` |
   | a decided edit in named files, tests, routine slices, research summaries | `sonnet` |
   | find, list or count things | `haiku` |
   | the hardest, longest job, or one opus already failed | `fable` |
   Unsure: one tier up. An agent that fails is retried one tier up, not with the same model.
   **Same failure twice = stop.** Give each failure a fingerprint: the step that failed, the error kind (test, build, lint, merge conflict, network, auth, quota, other) and the first 3 repo `file:line` frames. The same fingerprint twice in a row means a tier-up will not fix it: stop that slice and report it as blocked, with the fingerprint. A different fingerprint resets the count - that is progress.
4. **Agents hand over at 70% of their own window** with a final answer starting `HANDOVER:`. On a HANDOVER - foreground result or background notification - start a FRESH agent with it as the brief (put the word `resume` in its prompt) and keep going.
   **Check context usage at every step** - yours (statusline) and every agent's: `node ~/.claude/hooks/agent-watch.mjs --report <session-id>` lists each agent's tokens and % of its window.
5. **Commit each slice** when its gate passes. Verify before saying done: run the check, quote the number.
   **A fork the task did not settle: decide, do not ask.** Stop at the first rung that answers it - (1) what the task asked, (2) what the repo already does, (3) the smallest blast radius: fewest files, no new public surface, revertable by dropping one commit. Only past that is it the user's call. A choice made on rung 2 or 3 goes in the commit BODY as one line: `Decision: <question> / chose <option> / because <why>`. The subject stays `✅DOMAIN: task`.
6. **At this session's own context cap:** commit, write the handoff note, and tell the user to open a fresh session. Never compact.

End with the work report: what landed (with commits), what is next, what is blocked and on whom.
