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
const saidWord = /\bsupermode\b/i.test(typed);
const saidCommand = /^\s*\/supermode\b/i.test(typed);
const saidOff = /\b(?:stop|end|exit|leave|quit|off)\s+supermode\b/i.test(typed) ||
                /\bsupermode\s*[:=-]?\s*(?:off|stop|end|done)\b/i.test(typed);

const CONTRACT =
  "SUPERMODE IS ON. You are the ORCHESTRATOR, not the worker. Your own hands do only: " +
  "read the queue/handoff, decide the slice, SPAWN an Agent for it, run the gate, commit, " +
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
