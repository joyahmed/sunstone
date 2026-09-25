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
// Contract: Claude Code pipes {"prompt": "...", "session_id": "..."} on stdin;
// plain stdout on exit 0 is appended to the model's context for that turn.
//
// One piece of STATE, and only one: when the word fires, ~/.claude/ctx/<id>.sc is
// written, mirroring supermode-trigger.mjs's `.sm` idiom exactly (same session-id
// sanitising, same CLAUDE_CONFIG_DIR-aware root, same one-JSON-line payload).
// It is NOT "supercode is on forever" - supercode is an ACT, not a mode: one
// prompt fans out and it is over. The file only records that THIS session issued
// a supercode prompt, and the status line treats it as meaningful only while
// agent-watch.mjs still reports live agents, so a stale marker paints nothing and
// there is deliberately no cleanup scheme. Writing it can never fail the hook.

import fs from "node:fs";
import { resolve } from "node:path";
import { homedir } from "node:os";

let input = {};
try { input = JSON.parse(fs.readFileSync(0, "utf8") || "{}"); } catch { process.exit(0); }
const prompt = String(input.prompt ?? "");
const sid = typeof input.session_id === "string" ? input.session_id.replace(/[^A-Za-z0-9_-]/g, "") : "";

function cfgDir() {
  const e = process.env.CLAUDE_CONFIG_DIR;
  if (e && e.trim() !== "") return e.startsWith("~") ? resolve(homedir(), e.replace(/^~[/\\]?/, "")) : resolve(e);
  return resolve(homedir(), ".claude");
}
const flag = sid ? resolve(cfgDir(), "ctx", `${sid}.sc`) : null;
function markFanOut(by) {
  if (!flag) return;
  try {
    fs.mkdirSync(resolve(cfgDir(), "ctx"), { recursive: true });
    fs.writeFileSync(flag, JSON.stringify({ since: new Date().toISOString(), by }) + "\n");
  } catch { /* the fan-out still runs; only the status line loses its marker */ }
}


// ─────────────────────────────────────────────────────────────────────────────
// TYPED-TEXT EXTRACTION - this block is duplicated BYTE-FOR-BYTE in the other
// trigger hook beside it (supermode-trigger.mjs <-> supercode-trigger.mjs). It
// is deliberately written without naming either word so the two copies stay
// literally identical and a plain `diff` of them proves it. Change one, change
// the other: both hooks must answer "did the user type this?" the same way or
// the bug below comes back on one side only. There is no shared-module
// convention in this hooks directory - every hook is a standalone file the
// harness runs directly - so the block is copied, not imported.
//
// Only what the USER TYPED counts. Most of what reaches a UserPromptSubmit turn
// was typed by nobody: a peer session's relay, a SUBAGENT'S HAND-BACK REPORT, a
// background task notification, a system reminder, slash-command output. Every
// one of them can QUOTE the trigger word - reports *about* these modes are
// exactly the kind of thing agents write - and a hook that matched the raw
// prompt let an agent switch the mode on.
//   Found 2026-09-22 (a peer relay quoting the word flipped the receiver), and
//   again 2026-09-25 on two machines at once: a subagent hand-back that merely
//   discussed these hooks wrote this session's flag file and told the
//   orchestrator "the user typed <word>" after every single hand-back. A
//   session that obeyed would fan out a workflow nobody asked for - real
//   agents, real tokens.
//
// So: strip every envelope, then match only on the remainder. Envelopes nest and
// repeat, so each pair is stripped in a loop and the passes repeat until a whole
// pass changes nothing. An UNTERMINATED envelope truncates to the end of the
// prompt - text after an open tag that never closes is untrusted - while
// anything the user typed BEFORE it survives, so a malformed relay can neither
// smuggle the word in nor swallow a real prompt. Bracketed frames like
// `[Subagent hand-back]` introduce a report that runs to the end of whatever
// contains it and have no closing form of their own, so they cut to the end too;
// users do not type them.
// Plain string scanning, deliberately: no regex escaping to get wrong.
//
// TWO passes, because a named list FAILS OPEN - the harness gains envelopes over
// time (<task-notification> was unstripped for months and nobody noticed until
// the night this was written), and every new one silently reopens the hole:
//
//   1. KNOWN envelopes, by name, stripped aggressively: an unclosed one
//      truncates to the end of the prompt, because we know the harness's shape
//      and know nothing the user typed follows an open envelope of ours.
//   2. GENERIC: any BALANCED block whose tag sits at column zero and is
//      lowercase KEBAB-CASE (it contains a hyphen). Every harness envelope is
//      hyphenated - agent-message, cross-session-message, task-notification,
//      system-reminder, local-command-*, command-* - and in a survey of real
//      transcripts every line-initial tag that came from a USER's paste instead
//      (html, div, p, li, svg, table, script, ...) is a plain HTML element with
//      no hyphen. So the shape distinguishes them without another list, and a
//      future envelope is caught the day it appears.
//      This pass is deliberately CONSERVATIVE where the first is not: an
//      unclosed generic tag only drops the tag itself, never the text after it.
//      A pasted Vue/Angular/web-component fragment with a stray <mat-icon> is a
//      normal prompt and must not swallow the word the user actually typed.
//
// Neither pass can tell MENTION from INVOCATION: "I didn't enable this mode"
// is typed text and still fires. That is a separate problem and sentiment or
// negation heuristics would misfire worse - it is left alone on purpose.
const ENVELOPES = [
  ["<agent-message", "</agent-message>"],                 // subagent hand-back / teammate relay
  ["<cross-session-message", "</cross-session-message>"], // peer session relay
  ["<task-notification", "</task-notification>"],         // a background agent finished
  ["<system-reminder", "</system-reminder>"],
  ["<local-command-stdout", "</local-command-stdout>"],
  ["<command-name", "</command-name>"],
  ["<command-message", "</command-message>"],
  ["<command-args", "</command-args>"],
];
const FRAMES = ["[subagent hand-back]", "[cross-session "];
const KEBAB_OPEN = /(^|\n)<([a-z][a-z0-9]*(?:-[a-z0-9]+)+)(?:\s[^<>]*)?>/;

function stripBlock(s, open, close) {
  for (;;) {
    const i = s.toLowerCase().indexOf(open);
    if (i < 0) return s;
    const j = s.toLowerCase().indexOf(close, i + open.length);
    s = j < 0 ? s.slice(0, i) : s.slice(0, i) + " " + s.slice(j + close.length);
  }
}
function stripKebabBlocks(s) {
  for (let guard = 0; guard < 64; guard++) {
    const m = KEBAB_OPEN.exec(s);
    if (!m) break;
    const tag = m[2];
    const openAt = m.index + m[1].length;
    const afterOpen = m.index + m[0].length;
    const close = s.toLowerCase().indexOf(`</${tag}>`, afterOpen);
    s = close < 0
      ? s.slice(0, openAt) + " " + s.slice(afterOpen)            // unclosed: drop the tag only
      : s.slice(0, openAt) + " " + s.slice(close + tag.length + 3);
  }
  return s;
}
function typedOnly(p) {
  let s = String(p);
  for (let pass = 0; pass < 8; pass++) {
    const before = s;
    for (const [o, c] of ENVELOPES) s = stripBlock(s, o, c);
    s = stripKebabBlocks(s);
    if (s === before) break;
  }
  for (const f of FRAMES) {
    const i = s.toLowerCase().indexOf(f);
    if (i >= 0) s = s.slice(0, i);
  }
  // The harness's own lead-in for a relayed message is not typed text either.
  return s.replace(/^.*\bsent a message(?: while you were working)?\s*:?\s*$/gim, " ");
}
// ─────────────────────────────────────────────────────────────────────────────

const typed = typedOnly(prompt);

if (/^\s*\/supercode\b/i.test(typed)) {
  // The command loads its own procedure - do not restate it, just record that a
  // fan-out was requested so the status line has something real to read.
  markFanOut("command");
  process.exit(0);
}
if (!/\bsupercode\b/i.test(typed)) process.exit(0);

markFanOut("word");

// `typed`, not `prompt`: the gate already ignores relayed text, but this width
// parse used to read the RAW prompt, so a hand-back that said "supercode max"
// could WIDEN a fan-out the user started narrowly in the same turn.
const m = /\bsupercode\b[\s:,-]*(min|max)?\b/i.exec(typed);
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
