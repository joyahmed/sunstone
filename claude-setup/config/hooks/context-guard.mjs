#!/usr/bin/env node
// context-guard - the checkpoint nudge. Pure Node.js, no shell dependency.
//
// A PostToolUse hook. After every tool call it reads the context gauge and, once the
// session is past the threshold (70% by default), tells the model - as hook context it
// can see - to checkpoint: finish the slice, commit, write the handoff, start the
// successor, stop. It says so ONCE per 5% band (70, 75, 80 ...), so a session that is
// mid-slice hears it again as the window fills, and never on every call.
//
// Why a hook: the model cannot see its own context percentage, and compaction - the
// harness's answer to a full window - is the largest single request of a session and
// returns a summary without the numbers. Supermode turns auto-compaction off
// (supermode.settings.json) and hands off to a fresh session instead; this is the part
// that tells the model when.
//
// The gauge, in order of preference:
//   1. ~/.claude/ctx/<session_id>.pct - written by ctx-gauge.mjs from the status line's
//      own figure, exact. Used when it is less than 10 minutes old.
//   2. The transcript: the last assistant turn's `usage` (input + cache read + cache
//      creation tokens) over SUPERMODE_CTX_WINDOW (default 200000). An estimate - a
//      model with a 1M window reads five times too high unless you set the variable -
//      and the nudge says so.
//
// Registered in the BASE settings, so it runs in every session - NOT only under
// supermode. It was supermode-only until 2026-09-22, and migration 03 then retired
// the legacy .sh/.js pair that had covered ordinary sessions, leaving them with no
// guard at all. Ordinary sessions are where it matters most: they are the ones
// auto-compaction is still enabled for.
//
// SUPERMODE selects the ADVICE, not whether the guard runs. Under supermode the
// nudge is about delegation (reaching the threshold means work was done here that
// an agent should have done) and ends at the successor launch. Otherwise it is
// about handing slices to subagents and, failing that, checkpointing and starting
// a fresh session by hand. Both refuse compaction.
//
// ⛔ Do NOT also register it in supermode.settings.json - that layers ON TOP of the
// base settings, so it would fire twice per tool call.
// Tunables: SUPERMODE_CTX_PCT (threshold, default 70), SUPERMODE_CTX_WINDOW.
import { existsSync, mkdirSync, readFileSync, writeFileSync, statSync, readdirSync, unlinkSync } from "node:fs";
import { resolve } from "node:path";
import { homedir } from "node:os";

// Runs in EVERY session. It used to exit unless SUPERMODE=1, which left ordinary
// sessions with no guard at all once migration 03 retired the legacy .sh/.js pair
// that had covered them - and ordinary sessions are exactly where the "do not
// compact, start a new session" rule needs enforcing, because they are the ones
// auto-compaction is still on for. The mode now selects the ADVICE, not whether
// the guard runs.
const SUPERMODE = process.env.SUPERMODE === "1";

function cfgDir() {
  const e = process.env.CLAUDE_CONFIG_DIR;
  if (e && e.trim() !== "") return e.startsWith("~") ? resolve(homedir(), e.replace(/^~[/\\]?/, "")) : resolve(e);
  return resolve(homedir(), ".claude");
}

let input = {};
try { input = JSON.parse(readFileSync(0, "utf-8") || "{}"); } catch { input = {}; }
const sid = typeof input.session_id === "string" ? input.session_id.replace(/[^A-Za-z0-9_-]/g, "") : "";
if (!sid) process.exit(0);

const threshold = Math.max(1, Math.min(99, parseInt(process.env.SUPERMODE_CTX_PCT || "70", 10) || 70));
const ctxDir = resolve(cfgDir(), "ctx");
try { mkdirSync(ctxDir, { recursive: true }); } catch { /* read-only home: still try the transcript */ }

// 1. The exact gauge.
let pct = null, estimated = false;
const gaugeFile = resolve(ctxDir, `${sid}.pct`);
try {
  if (existsSync(gaugeFile) && Date.now() - statSync(gaugeFile).mtimeMs < 10 * 60 * 1000) {
    const n = parseInt(readFileSync(gaugeFile, "utf-8").trim(), 10);
    if (Number.isFinite(n)) pct = n;
  }
} catch { pct = null; }

// 2. The estimate from the transcript.
if (pct === null && typeof input.transcript_path === "string" && existsSync(input.transcript_path)) {
  try {
    const lines = readFileSync(input.transcript_path, "utf-8").split("\n");
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i];
      if (!line || !line.includes('"usage"')) continue;
      let d; try { d = JSON.parse(line); } catch { continue; }
      const u = d && d.type === "assistant" && d.message && d.message.usage;
      if (!u) continue;
      const used = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
      const window = parseInt(process.env.SUPERMODE_CTX_WINDOW || "200000", 10) || 200000;
      pct = Math.round((used / window) * 100);
      estimated = true;
      break;
    }
  } catch { pct = null; }
}
if (pct === null || pct < threshold) process.exit(0);

// Once per 5% band.
const band = Math.floor(pct / 5) * 5;
const bandFile = resolve(ctxDir, `${sid}.band`);
try {
  if (existsSync(bandFile) && parseInt(readFileSync(bandFile, "utf-8").trim(), 10) >= band) process.exit(0);
  writeFileSync(bandFile, `${band}\n`);
} catch { /* cannot record the band: nudge anyway rather than never */ }

// Housekeeping: gauge files from sessions older than a week.
try {
  const cutoff = Date.now() - 7 * 24 * 60 * 60 * 1000;
  for (const f of readdirSync(ctxDir)) {
    const p = resolve(ctxDir, f);
    try { if (statSync(p).mtimeMs < cutoff) unlinkSync(p); } catch { /* skip */ }
  }
} catch { /* skip */ }

const how = estimated
  ? ` (estimated from the transcript against a ${process.env.SUPERMODE_CTX_WINDOW || "200000"}-token window - set SUPERMODE_CTX_WINDOW, or let ctx-gauge.mjs front your status line, for the exact figure)`
  : "";
const checkpoint =
  `checkpoint - do not start new work. Bring the current slice to a green gate, commit it, write the handoff note ` +
  `(what is done, what is next, what is blocked, with the exact numbers a fresh session cannot re-derive), move the queue row, `;

const msg = SUPERMODE
  ? `supermode context guard: this session is at ${pct}% of its context window${how}; the handoff threshold is ${threshold}%. ` +
    `Under supermode you orchestrate: read, decide, and DELEGATE each slice to an agent so the agents spend ` +
    `context and this session does not. Reaching ${threshold}% is therefore a SYMPTOM - it means work was done ` +
    `here that an agent should have done. First ask what is still being done in-session that could be delegated. ` +
    `Note you CANNOT read an agent's context usage - no gauge file and no transcript record is written for a ` +
    `subagent - so keep slices small and require each agent to report when its own budget runs short. ` +
    `If delegation can no longer save this session: ` + checkpoint +
    `then start the successor from the repo root: \`supermode --bg --permission-mode auto \"supermode: resume\"\` ` +
    `(if that launch is refused, delegate the same resume to an Agent-tool subagent instead), and stop. ` +
    `Do NOT compact: compaction is the biggest request of the session and its summary drops the numbers the successor needs. ` +
    `This notice repeats once per 5% band.`
  : `context guard: this session is at ${pct}% of its context window${how}; the threshold is ${threshold}%. ` +
    `Anything you can hand to an Agent-tool subagent - a broad search, reading a large file, a self-contained slice - ` +
    `spends ITS context instead of this one; take back the conclusion, not the file. ` +
    `If that will not be enough: ` + checkpoint +
    `then tell the user this session is near its limit and start a fresh one. ` +
    `Do NOT compact: compaction is the biggest request of the session and its summary drops the numbers a successor needs - ` +
    `a fresh session reading the handoff note beats a compacted one every time. ` +
    `This notice repeats once per 5% band.`;

process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: msg },
}) + "\n");
