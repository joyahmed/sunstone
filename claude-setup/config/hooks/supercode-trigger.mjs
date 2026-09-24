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


// Only what the USER TYPED counts. A message relayed from another Claude
// session arrives as an ordinary user turn wrapped in a
// <cross-session-message ...> envelope, so a peer that merely MENTIONS this
// word would otherwise flip this machine into the mode - nobody asked for it.
// Found 2026-09-22, when one session quoted the word to another and the
// receiving hook fired. The same goes for <system-reminder> blocks and for
// slash-command output, which can quote anything. Strip those blocks and match
// only on the remainder. An UNTERMINATED envelope truncates to the end of the
// prompt, so a partial or malformed relay cannot smuggle the word in either.
// Plain string scanning, deliberately: no regex escaping to get wrong.
function stripBlock(s, open, close) {
  for (;;) {
    const i = s.toLowerCase().indexOf(open);
    if (i < 0) return s;
    const j = s.toLowerCase().indexOf(close, i + open.length);
    s = j < 0 ? s.slice(0, i) : s.slice(0, i) + " " + s.slice(j + close.length);
  }
}
function typedOnly(p) {
  let s = String(p);
  for (const [o, c] of [
    ["<cross-session-message", "</cross-session-message>"],
    ["<system-reminder", "</system-reminder>"],
    ["<local-command-stdout", "</local-command-stdout>"],
    ["<command-name", "</command-name>"],
    ["<command-message", "</command-message>"],
    ["<command-args", "</command-args>"],
  ]) s = stripBlock(s, o, c);
  return s;
}

const typed = typedOnly(prompt);

if (/^\s*\/supercode\b/i.test(typed)) process.exit(0);
if (!/\bsupercode\b/i.test(typed)) process.exit(0);

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
    "⚠ Do not spend THIS session's context doing the work: reading large " +
    "files, running broad searches or writing the code here is what exhausts the " +
    "one context that has to survive to finish the run. Give agents the paths and " +
    "take back conclusions, not file dumps. You cannot observe an agent's context " +
    "usage - no such channel exists - so keep each slice small and require every " +
    "agent to say so when its own budget runs short. " +
    "See `claude-setup/commands/supercode.md` for the full procedure.\n",
);
