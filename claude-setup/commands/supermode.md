---
description: Supermode — unattended work. Slice → gate → commit → handoff, and a fresh session instead of compaction when the context fills.
argument-hint: "[resume | <what to work on>]"
---

**Supermode** is the way of working for when the person has left the chair: the same
care as attended work, with the checkpoints that make it safe to keep going without them.
`$ARGUMENTS`, if present, says where to start — `resume` means *read the handoff and carry
on from it*.

You are in a supermode session if `SUPERMODE=1` is in the environment (the `supermode`
launcher sets it; a successor inherits it). If it is not, say so and run this procedure
anyway — only the automatic context guard is missing.

## The loop

Work the queue **one slice at a time**. A slice is one change small enough to land on its
own. For each:

1. **Change** — the slice, nothing else.
2. **Gate** — the repo's own gate: build, typecheck, tests, whatever it has. Green or it does
   not land. Two failures in a row on the same gate → stop and diagnose, do not try a third
   variation.
3. **Commit** — on green, in the person's own commit voice, one slice per commit.
4. **Handoff** — after EVERY slice, before the next: a session note (`docs/ai-memory/
   session-<date>.md` or wherever the repo keeps them) saying what landed, what is next,
   what is blocked, with the exact numbers a fresh session cannot re-derive (commit hashes,
   test counts, the failing case), and the work-queue row moved. You cannot see your own
   context gauge; the handoff is written every time so the last one is always current.

## The context rule — hand off, never compact

Compaction is the largest single request of a session and it returns a summary without the
numbers. Supermode turns auto-compaction off. When the context guard says the window is past
its threshold (70% by default, once per 5% band), **checkpoint**: finish the slice at a green
gate, commit, write the handoff, then start the successor from the repo root —

```
supermode --bg --permission-mode auto "supermode: resume"
```

— and stop. If that launch is refused by the permission layer, delegate the same
`supermode: resume` to a background subagent (the Agent tool) instead; a fresh context is
the point, and typing the next slices into this session is not supermode. Never `/clear`
from inside: it would erase the context the handoff is written from. The successor IS the
clear.

## What stays the person's

Queue these with the exact command, and carry on with everything else:

- anything irreversible or outward-facing — publishing, promoting a release, a force-push,
  money, a message to someone else;
- anything the permission layer refuses;
- a decision the request does not settle and a sensible default does not cover.

## Fan-out

Supermode is *unattended*; `/supercode` is *wide*. They compose: a supermode session fans
out at the minimum that gives assurance unless told `supercode max`, and states the agent
count in each checkpoint note.

## The morning report

The last thing a supermode run writes, in the handoff and in the session's final message:
commits landed (hashes, one line each), what is green, what is queued for the person and
why, risks noticed. Numbers, not adjectives.
