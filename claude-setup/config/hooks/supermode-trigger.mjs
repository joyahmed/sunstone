#!/usr/bin/env node
// supermode-trigger.mjs - UserPromptSubmit hook.
//
// The requirement: if the user types `supermode`, the session starts supermode -
// every session must understand the word. A skill is only a suggestion the model
// may or may not take; this hook makes the word itself the switch. When the
// prompt contains the standalone word `supermode` (any case), one line of
// context is injected telling the session to invoke the `supermode` skill now
// and keep its procedure for the rest of the session.
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

if (/^\s*\/supermode\b/i.test(typed)) process.exit(0);
if (!/\bsupermode\b/i.test(typed)) process.exit(0);

process.stdout.write(
  "The user said \"supermode\". Invoke the `supermode` skill now (Skill tool, name " +
    "`supermode`; pass the rest of the prompt as its argument - `resume` if that " +
    "is what was said) and run its procedure - slice, gate, commit, handoff, say " +
    "it - for the rest of this session. If SUPERMODE is not set in the " +
    "environment, say so in one line and proceed anyway.\n",
);
