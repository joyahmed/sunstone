#!/usr/bin/env node
// supercode-trigger.mjs - UserPromptSubmit hook.
//
// The requirement: `supercode` is the user's word for fan-out, and it takes a
// degree - `supercode min` and `supercode max`. A skill description is only a
// hint the model may or may not take; this hook makes the word itself the
// switch, the same way supermode-trigger.mjs does for `supermode`.
//
//   supercode max  - maximum fan-out; thoroughness over cost.
//   supercode min  - the fewest agents that still split the work.
//   supercode      - unchanged: the minimum with assurance (same as `min`).
//
// `supercode` and `supermode` are DIFFERENT words and neither implies the
// other. This hook never mentions supermode; supermode-trigger.mjs owns that.
//
// Silent when the word is absent, when the prompt IS the command already
// (`/supercode ...`), when stdin is not JSON, and on every failure - a prompt
// is never blocked.
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

// The degree is the first word after `supercode`, when it is min or max.
const m = /\bsupercode\b[\s:,-]*(min|max)?\b/i.exec(prompt);
const degree = (m && m[1] ? m[1] : "min").toLowerCase();

const common =
  "Fan out with concurrent subagents (Agent tool, several in ONE message so they " +
  "run in parallel). Give each agent EXCLUSIVE ownership of the files it edits - " +
  "two agents in one file is the one thing that does not work. Hand each the facts " +
  "already established rather than making it rediscover them, name the shared " +
  "resources nobody may touch, and gate centrally once over the combined result. " +
  "Do not split a change to a single shared file, work that must land as one " +
  "commit, or an ambiguous task - more agents on ambiguity produce more confident " +
  "output that is wrong in more places at once. State the agent count in your " +
  "first message.";

const byDegree =
  degree === "max"
    ? "The user said \"supercode max\": they are in a hurry and want MAXIMUM fan-out - " +
      "every agent the work separates into, thoroughness over cost. Prefer more " +
      "agents than feels necessary wherever the work genuinely separates by file."
    : "The user said \"supercode" + (m && m[1] ? " min" : "") + "\": use the MINIMUM " +
      "fan-out that still splits the work - the fewest agents that cover it, with " +
      "assurance. Where the work does not cleanly separate, prefer ONE agent doing " +
      "it sequentially over a split that buys nothing.";

// The Workflow tool is deliberately NOT authorised here: it is gated on the
// harness keyword `ultracode` or an explicit request, and it raises a
// permission dialog. Concurrent Agent-tool subagents need neither.
const tool =
  "Use the Agent tool for this, not the Workflow tool - Workflow requires the " +
  "user's explicit opt-in and raises a permission dialog, which concurrent " +
  "subagents do not.";

process.stdout.write(`${byDegree} ${common} ${tool}\n`);
