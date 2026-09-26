#!/usr/bin/env node
// supermode-trigger.mjs - UserPromptSubmit hook. The word IS the switch.
//
// The requirement: if the user types `supermode`, the session starts supermode -
// every session must understand the word. A skill is only a suggestion the model
// may or may not take; this hook makes the word itself the switch.
//
// It does three things, and the second is the one that was missing until
// 2026-09-25: repetition. A directive injected ONCE, on the turn the word was
// typed, is a thing a session drifts away from twenty turns later - nothing
// repeats it and nothing records that the mode was ever entered, so by the time
// anyone notices, the mode has been off for hours without ever being turned off.
//
//   1. STATE. The mode is written down: ~/.claude/ctx/<session-id>.sm, one JSON
//      line. The status line reads it and paints `sm`; agent-watch.mjs and
//      supermode-hands.mjs read it to know they are live. The launcher's
//      SUPERMODE=1 says the same thing for a session started as supermode; this
//      file is how a session that was told the word mid-flight says it too.
//   2. REPETITION. While that file exists, EVERY prompt gets a two-line standing
//      reminder of the contract - orchestrate, do not work. That is what keeps
//      turn 40 in the mode the user set on turn 1.
//   3. THE OFF SWITCH. "supermode off" / "stop supermode" / "exit supermode"
//      removes the file and says so. A mode you cannot leave is a trap.
//
// Silent when the word is absent and the mode is off, when stdin is not JSON, and
// on every failure - a prompt is never blocked.
//
// Contract: Claude Code pipes {"prompt": "...", "session_id": "..."} on stdin;
// plain stdout on exit 0 is appended to the model's context for that turn.

import { existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { resolve } from "node:path";
import { homedir } from "node:os";

let input = {};
try { input = JSON.parse(readFileSync(0, "utf8") || "{}"); } catch { process.exit(0); }
const prompt = String(input.prompt ?? "");
const sid = typeof input.session_id === "string" ? input.session_id.replace(/[^A-Za-z0-9_-]/g, "") : "";

function cfgDir() {
  const e = process.env.CLAUDE_CONFIG_DIR;
  if (e && e.trim() !== "") return e.startsWith("~") ? resolve(homedir(), e.replace(/^~[/\\]?/, "")) : resolve(e);
  return resolve(homedir(), ".claude");
}
const flag = sid ? resolve(cfgDir(), "ctx", `${sid}.sm`) : null;
const isOn = () => { try { return flag ? existsSync(flag) : false; } catch { return false; } };
function turnOn(by) {
  if (!flag) return;
  try {
    mkdirSync(resolve(cfgDir(), "ctx"), { recursive: true });
    writeFileSync(flag, JSON.stringify({ since: new Date().toISOString(), by }) + "\n");
  } catch { /* the mode still runs; only the status line loses its `sm` */ }
}
function turnOff() { try { if (flag) unlinkSync(flag); } catch { /* already gone */ } }

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
const saidWord = /\bsupermode\b/i.test(typed);
const saidCommand = /^\s*\/supermode\b/i.test(typed);
const saidOff = /\b(?:stop|end|exit|leave|quit|off)\s+supermode\b/i.test(typed) ||
                /\bsupermode\s*[:=-]?\s*(?:off|stop|end|done)\b/i.test(typed);

const CONTRACT =
  "SUPERMODE IS ON. You are the ORCHESTRATOR, not the worker. Your own hands do only: " +
  "read the last handoff for this box and repo FIRST (the newest session-<date>.md note), " +
  "and the queue only to confirm placement or when that handoff is missing or stale - the " +
  "handoff is compact and current, the queue is a cross-machine board that spends your window " +
  "on other boxes' work. Then: decide the slice, SPAWN an Agent for it, run the gate, commit, " +
  "write the handoff, say it out loud. Every unit of real work - the searching, the reading, " +
  "the editing - goes to an Agent tool subagent, because their context is spent instead of " +
  "yours and that is the whole point of the mode. Watch them: " +
  "`node ~/.claude/hooks/agent-watch.mjs --report` prints each live agent's context usage, and " +
  "the watch hook tells you when one passes 60%. A decision with a sensible default is NOT a " +
  "stop - proceed on the default, note it in the handoff, keep going.";

// The off switch first: "stop supermode" also contains the word.
if (saidOff) {
  const was = isOn();
  turnOff();
  process.stdout.write(
    was
      ? "Supermode is OFF - the flag file is removed, the status line drops `sm`, and the " +
        "orchestrator-only guard on Edit/Write no longer applies. Work normally from here, and " +
        "finish the current slice cleanly (gate, commit, handoff) before changing gear.\n"
      : "Supermode was not on; nothing to stop.\n",
  );
  process.exit(0);
}

if (saidCommand) {
  // The command loads its own procedure - do not restate it, just record the mode
  // so the status line, the watch and the guard all know.
  turnOn("command");
  process.exit(0);
}

if (saidWord) {
  const first = !isOn();
  turnOn("prompt");
  process.stdout.write(
    (first
      ? "The user said \"supermode\". Invoke the `supermode` skill now (Skill tool, name " +
        "`supermode`; pass the rest of the prompt as its argument - `resume` if that is what " +
        "was said) and run its procedure - orchestrate, slice, gate, commit, handoff, say it - " +
        "for the rest of this session. If SUPERMODE is not set in the environment, say so in " +
        "one line and proceed anyway. "
      : "The user said \"supermode\" again - the mode is already on, so do not restart it; the " +
        "repetition means the contract slipped. Re-read it and get back to it. ") + CONTRACT + "\n",
  );
  process.exit(0);
}

// The word was not said this turn - but the mode is a STATE, not a turn. While it
// is on, every prompt carries the contract. Two lines, every turn, is what a mode
// costs; drifting out of it silently is what it used to cost.
if (isOn()) {
  let since = "";
  try { since = JSON.parse(readFileSync(flag, "utf8")).since || ""; } catch { /* no timestamp */ }
  process.stdout.write(
    CONTRACT + (since ? ` (on since ${since}; "stop supermode" ends it.)` : " (\"stop supermode\" ends it.)") + "\n",
  );
}
