---
description: Supercode - fan the work out over concurrent agents. Plain = the minimum that gives assurance; `max` = as wide as the work splits.
argument-hint: "[max] [what to do]"
---

**Supercode** means: do not serialise work that separates by file. Author and run a
workflow of concurrent agents; the person's time is the constraint, not tokens. Ask once
if the request is ambiguous, then go - they should not have to ask twice for work that
obviously splits.

`$ARGUMENTS` sets the width:

- **plain** - the *minimum that gives assurance*: 2-3 disjoint lenses, one refuter per
  finding, writers only on disjoint files. About a tenth of the cost of max.
- **`max`** - the person is in a hurry: every agent the work splits into, refuters on every
  finding, speed over tokens.

Either way, **say the expected agent count before launching** so it can be vetoed. No word
= no workflow: one agent, or a single verifier for one question.

## What makes a fan-out pay

1. **Exclusive file ownership.** Name the exact files each agent owns and tell it others are
   editing the same tree. Overlap makes two agents fix each other's work.
2. **Hand over the verified facts** - findings, `file:line`, the traps already known. An
   agent that re-derives what was already measured spends its budget rediscovering yesterday.
3. **Name the shared resources nobody may touch** - the port in use, generated files (a
   codegen script run by two agents stomps itself), a shared build directory, the database.
4. **Gate centrally, once.** Agents typecheck only; the orchestrator runs tests, lint, build
   and the smoke suite over the COMBINED tree. Every agent running the full suite pays for it
   N times and proves nothing about the merge.

**No two agents do the same task, and writers never share a file.** Finders own a
*question* each - disjoint by what they are asked, not just by label; reading the same file
for a different question is fine. The one deliberate overlap is refuters: several agents
attacking the same finding is the assurance.

## What it cannot do

A change to one shared file; anything that must land as a single commit; ambiguous work -
more agents on ambiguity produce more confident output that is wrong in more places at
once. Resolve the ambiguity first, then fan out.

## Cost, said plainly

A build fan-out reads each file about once. A *review* fan-out re-reads the same files N
times by design and costs what it costs - whole-tree review passes are one-offs, re-earned
only by a big new surface. If the host offers a stronger orchestration mode under its own
keyword, that keyword is the one that flips the host's flag; this command only directs the
model.
