#!/usr/bin/env node
// supercode-trigger.mjs - UserPromptSubmit hook.
//
// The requirement: the fan-out word has to work when it is TYPED in an ordinary
// prompt, not only as `/supercode`. A command is only reachable by its slash
// form and a skill description is only a hint; this hook makes the typed word
// the switch, exactly as supermode-trigger.mjs does for its own word.
//
// Width, matching claude-setup/commands/supercode.md:
//   max        - every agent the work splits into, refuters on every finding.
//   min | bare - the minimum that gives assurance: 2-3 disjoint lenses, one
//                refuter per finding, writers only on disjoint files.
// `min` is an explicit synonym for the command's "plain"; it does not change it.
//
// This hook is about FAN-OUT only. It deliberately says nothing about the
// launched-session word, which is a different command with a different hook -
// one word must never invoke the other's procedure.
//
// Silent when the word is absent, when the prompt IS the command already
// (`/supercode ...` - the command loads itself), when stdin is not JSON, and on
// every failure - a prompt is never blocked.
//
// Contract: Claude Code pipes {"prompt": "..."} on stdin; plain stdout on
// exit 0 is appended to the model's context for that turn.

import fs from "node:fs";

let prompt = "";
try {
  prompt = String(JSON.parse(fs.readFileSync(0, "utf8")).prompt ?? "");
} catch {
  process.exit(0);
}

if (/^\s*\/supercode\b/i.test(prompt)) process.exit(0);
if (!/\bsupercode\b/i.test(prompt)) process.exit(0);

const m = /\bsupercode\b[\s:,-]*(min|max)?\b/i.exec(prompt);
const wide = m && m[1] && m[1].toLowerCase() === "max";

const width = wide
  ? "WIDTH = max: the user is in a hurry - every agent the work splits into, " +
    "refuters on every finding, speed over tokens."
  : "WIDTH = the minimum that gives assurance - 2-3 disjoint lenses, one refuter " +
    "per finding, writers only on disjoint files, about a tenth of the cost of max. " +
    "Where the work does not genuinely separate, one agent sequentially is the " +
    "right answer and no workflow is better than a split that buys nothing.";

process.stdout.write(
  "The user typed \"supercode\". Run the `supercode` procedure now: do not " +
    "serialise work that separates by file - author and run a Workflow of " +
    "concurrent agents. Their time is the constraint, not tokens. Ask once if " +
    "the request is ambiguous, then go. " +
    width +
    " Say the expected agent count BEFORE launching so it can be vetoed. Give " +
    "each agent exclusive ownership of the files it edits, hand it the facts " +
    "already verified rather than making it rediscover them, name the shared " +
    "resources nobody may touch, and gate centrally once over the combined tree. " +
    "See `claude-setup/commands/supercode.md` for the full procedure.\n",
);
