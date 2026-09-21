#!/usr/bin/env node
// supermode-trigger.mjs - UserPromptSubmit hook.
//
// Joy, 2026-09-21: "if i say supermode you start supermode. every session must
// understand it." A skill is only a suggestion the model may or may not take;
// this hook makes the word itself the switch. When the prompt contains the
// standalone word `supermode` (any case), one line of context is injected
// telling the session to invoke the `supermode` skill now and keep its
// procedure for the rest of the session.
//
// Silent when the word is absent, when the prompt IS the command already
// (`/supermode ...` - the command loads the procedure itself), when stdin is
// not JSON, and on every failure - a prompt is never blocked.
//
// Contract: Claude Code pipes {"prompt": "..."} on stdin; plain stdout on
// exit 0 is appended to the model's context for that turn.

import fs from "node:fs";

let prompt = "";
try {
  const raw = fs.readFileSync(0, "utf8");
  prompt = String(JSON.parse(raw).prompt ?? "");
} catch {
  process.exit(0);
}

if (/^\s*\/supermode\b/i.test(prompt)) process.exit(0);
if (!/\bsupermode\b/i.test(prompt)) process.exit(0);

process.stdout.write(
  "Joy said \"supermode\". Invoke the `supermode` skill now (Skill tool, name " +
    "`supermode`; pass the rest of the prompt as its argument - `resume` if that " +
    "is what was said) and run its procedure - slice, gate, commit, handoff, say " +
    "it - for the rest of this session. If SUPERMODE is not set in the " +
    "environment, say so in one line and proceed anyway.\n",
);
