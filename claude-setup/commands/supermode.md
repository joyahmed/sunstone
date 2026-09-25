---
description: Supermode - unattended work, orchestrated. You spawn agents, watch their context, gate, commit, hand off - you do not do the work yourself.
argument-hint: "[resume | <what to work on>]"
---

**Supermode** is the way of working for when the person has left the chair: the same
care as attended work, with the checkpoints that make it safe to keep going without them.
`$ARGUMENTS`, if present, says where to start - `resume` means *read the handoff and carry
on from it*.

## You are the orchestrator, not the worker

This is the rule the whole mode rests on, and the one that slips first. **Your own hands
do only these six things:**

1. read the queue and the last handoff, 2. decide the next slice, 3. **spawn an agent for
it**, 4. run the gate, 5. commit, 6. write the handoff and say it out loud.

Everything else - the searching, the reading, the editing, the debugging - goes to an
**Agent tool** subagent. Not because you cannot do it, but because an agent's context is
spent instead of yours, and a session that keeps its own window small runs all night. A
session that does the work itself fills up in two hours and hands off a summary instead
of a result.

The guard enforces it: while supermode is on, `Edit`, `Write` and the Bash forms that are
really edits (`sed -i`, `tee`, a `>` redirect) are **denied** unless the path is the
handoff, the queue or a note. That deny is not a wall - `touch ~/.claude/ctx/<session-id>.hands`
takes the wheel back deliberately when an agent genuinely cannot do it - but taking the
wheel is a decision you state in one line, never a drift.

You are in a supermode session if `SUPERMODE=1` is in the environment (the `supermode`
launcher sets it), or if `~/.claude/ctx/<session-id>.sm` exists (the word `supermode`,
typed in any prompt, writes it). The status line shows **`sm`** while it is on, with
`2a·63%` next to it when two agents are live and the fullest is at 63% of its window.
`stop supermode` ends it.

⛔ Before delegating any slice that launches `claude` inside a captured pty (testing
launcher behaviour, terminal titling, shell integration), make sure nothing is
uncommitted under `MEMORY_DIR` or `BUS_DIR` in the memory repo first - the SessionEnd
hook fires on that nested process's exit too, and will commit and push whatever it
finds there under a message nobody wrote.

## The loop

Work the queue **one slice at a time**. A slice is one change small enough to land on its
own, and - now that it is an agent doing it - small enough that the agent finishes under
about 60% of its own window. For each:

1. **Delegate** - spawn the agent with the slice, nothing else. Hand it the facts you
   already hold (exact paths, the gate command, what "done" looks like, what it must not
   touch) so it does not spend its window rediscovering them. Independent slices that
   own different files go out in one message, concurrently; anything that touches the
   same file, or must land as one commit, is one agent.
2. **Watch** - `node ~/.claude/hooks/agent-watch.mjs --report` prints every agent's
   context usage, live or finished, with what it was given. The watch hook also tells you
   unprompted when an agent passes 60% and again every 10% after that. An agent that is
   filling will not finish: take its result back at the next checkpoint and respawn a
   narrower slice rather than letting it run to the wall.
3. **Gate** - yours, centrally, once over the combined tree: build, typecheck, tests,
   whatever the repo has. Green or it does not land. Two failures in a row on the same
   gate → stop and diagnose (delegate the diagnosis), do not try a third variation.
4. **Commit** - on green, in the person's own commit voice, one slice per commit.
5. **Handoff** - after EVERY slice, before the next: a session note saying what landed, what
   is next, what is blocked, with the exact numbers a fresh session cannot re-derive (commit
   hashes, test counts, the failing case, how many agents and what each cost), and the
   work-queue row moved.
   ⛔ **Where it goes depends on whether the repo is public.** A private repo: `docs/ai-memory/
   session-<date>.md`, or wherever it keeps them. A repo that is PUBLIC or headed there: the
   private memory store instead, under a folder named for the repo - never `docs/ai-memory/`
   in the repo itself. A session note names other projects, machine paths and working habits;
   that is what makes it useful and what makes it unpublishable. The privacy guard enforces
   this at commit time, so a run that writes the handoff to `docs/ai-memory/` in a public repo
   writes it and then fails its own commit, every slice, until someone notices. You cannot see your own context gauge; the handoff is written every time so
   the last one is always current.
6. **Say it** - the person is not watching the terminal, so tell them out loud, once per
   slice, right after the handoff: `bash ~/.claude/hooks/say.sh "<what landed> is done.
   Taking up <what is next>."` One sentence, plain words, under twenty of them - a name
   for the slice, not a diff. Also once when something needs them (`"Stopping: <why>."`)
   and once at the end (`"Supermode is done. <n> commits. <what is queued for you>."`).
   The script is silent when the machine cannot speak; never wait on it, never skip a
   slice because it is missing.

## The context rule - hand off, never compact

Compaction is the largest single request of a session and it returns a summary without the
numbers. Supermode turns auto-compaction off. When the context guard says the window is past
its threshold (70% by default, once per 5% band), that is a **symptom**: work was done here
that an agent should have done. First ask what is still being done in-session that could be
delegated. If delegation can no longer save it, **checkpoint**: finish the slice at a green
gate, commit, write the handoff, then start the successor from the repo root:

```
supermode --bg --permission-mode auto "supermode: resume"
```

and stop. If that launch is refused by the permission layer, delegate the same
`supermode: resume` to a background subagent (the Agent tool) instead; a fresh context is
the point, and typing the next slices into this session is not supermode. Never `/clear`
from inside: it would erase the context the handoff is written from. The successor IS the
clear.

## What stays the person's

Queue these with the exact command, and carry on with everything else:

- anything irreversible or outward-facing - publishing, promoting a release, a force-push,
  money, a message to someone else;
- anything the permission layer refuses;
- a decision the request does not settle and a sensible default does not cover.

**A decision with a sensible default is not a stop.** Proceed on the default, write
"assumed X - confirm or say otherwise" in the handoff, and keep working. Working under a
placeholder name is fine; a rename is one command later.

## Fan-out

Supermode is *unattended*; `/supercode` is *wide*. They compose: a supermode session fans
out at the minimum that gives assurance unless told `supercode max`, and states the agent
count and each agent's final context cost in every checkpoint note.

## The morning report

The last thing a supermode run writes, in the handoff and in the session's final message:
commits landed (hashes, one line each), what is green, what was delegated and what it cost,
what is queued for the person and why, risks noticed. Numbers, not adjectives. Then say the
one-sentence version out loud (step 6).
