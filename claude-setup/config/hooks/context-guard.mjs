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
// returns a summary without the numbers. The answer is a fresh session reading a
// handoff note; this is the part that tells the model when.
//
// The gauge, in order of preference:
//   1. ~/.claude/ctx/<session_id>.pct - written by ctx-gauge.mjs from the status line's
//      own figure, exact, when that gauge fronts the status line. Used when it is less
//      than 10 minutes old.
//   2. The transcript: the last assistant turn's `usage` (input + cache read + cache
//      creation tokens) over the session's window - CTX_CAP_WINDOW, else ctx/<sid>.win
//      (the harness's context_window_size, written by the status line), else a [1m]
//      marker; never a guessed 200k. An estimate, and the nudge says so.
//
// Registered in the BASE settings, so it runs in every main session (never in a
// subagent - see agent_id below). One advice text for everyone: delegate big reads to
// a subagent; near the cap, finish the task, commit, write a handoff, and tell the user to
// start a fresh session. (Supermode, which had its own advice here, was retired on
// 2026-09-29.)
//
// Tunables (new name first, the old SUPERMODE_* name still read as a fallback):
//   CTX_CAP_PCT    (SUPERMODE_CTX_PCT)    nudge threshold, % of the cap/window, default 70
//   CTX_CAP_WINDOW (SUPERMODE_CTX_WINDOW) window override in tokens
//   CTX_CAP_TOKENS (SUPERMODE_CTX_TOKENS) absolute cap on growth, default 80000, 0 = off
//
// ⛔ A percentage alone is not a cap. 70% of a 1M window is 700k tokens, so a 1M
// session never heard this guard until it was far past the point where every turn
// costs a fortune (measured 2026-09-29: sessions past 150k spent half the week's
// quota). The absolute cap fixes that. It counts GROWTH since the session's first
// turn, not the total: the injected context alone (memory, beliefs, skill lists)
// measured 64.5k on turn 1 on 2026-09-29, so an 80k total would leave 15k to work
// with - the chosen budget is "80k on top of the start". The nudge starts at the threshold %
// OF THE CAP (56k grown) whatever the window, and at the cap itself context-cap.mjs
// refuses new reads and agent spawns. The fuller of the two measures wins.
// "<grown> <total> <start>" is written to ctx/<session_id>.tok for context-cap.mjs.
import { existsSync, mkdirSync, readFileSync, writeFileSync, statSync, readdirSync, unlinkSync } from "node:fs";
import { resolve } from "node:path";
import { homedir } from "node:os";

let input = {};
try { input = JSON.parse(readFileSync(0, "utf-8") || "{}"); } catch { input = {}; }
const sid = typeof input.session_id === "string" ? input.session_id.replace(/[^A-Za-z0-9_-]/g, "") : "";
if (!sid) process.exit(0);
// Inside a subagent the payload carries agent_id but the PARENT's transcript_path,
// so every figure below would be the orchestrator's - wrong advice to the wrong session.
if (typeof input.agent_id === "string" && input.agent_id !== "") process.exit(0);

// A subagent that hit its handover point (context-cap.mjs, SUBAGENT_CTX_PCT) ends with
// "HANDOVER:". The main session must carry the work on in a FRESH agent, not absorb the
// rest itself and not stop to ask the user - that is the whole point of handing over.
// Only a FINISHED agent's own answer counts: an async launch echoes the prompt back (which
// itself tells the agent about HANDOVER:), so the whole response must not be searched. Measured
// 2026-10-02: a background launch whose prompt mentioned HANDOVER fired this notice.
function agentAnswer(r) {
  if (!r || typeof r !== "object") return typeof r === "string" ? r : "";
  if (r.isAsync === true || r.status === "async_launched") return "";
  const c = Array.isArray(r.content) ? r.content : Array.isArray(r) ? r : null;
  if (c) return c.filter((x) => x && x.type === "text").map((x) => String(x.text || "")).join("\n");
  return typeof r.result === "string" ? r.result : "";
}
if (input.tool_name === "Agent" && /^\s*HANDOVER:/.test(agentAnswer(input.tool_response))) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext:
        "context guard: that agent reached its context handover point and returned a HANDOVER. Start a FRESH agent " +
        "now with the HANDOVER as its brief (put the word resume in its prompt), and keep going - do not finish the " +
        "work in this session and do not ask the user whether to continue.",
    },
  }) + "\n");
  process.exit(0);
}

function envInt(name, legacy) {
  for (const k of [name, legacy]) {
    const n = parseInt(process.env[k] ?? "", 10);
    if (Number.isFinite(n)) return n;
  }
  return NaN;
}

function cfgDir() {
  const e = process.env.CLAUDE_CONFIG_DIR;
  if (e && e.trim() !== "") return e.startsWith("~") ? resolve(homedir(), e.replace(/^~[/\\]?/, "")) : resolve(e);
  return resolve(homedir(), ".claude");
}

const threshold = Math.max(1, Math.min(99, envInt("CTX_CAP_PCT", "SUPERMODE_CTX_PCT") || 70));
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

/**
 * The window this session actually has, from the transcript's own model record.
 *
 * ⛔ `"model"` on an assistant record is NOT enough: it drops the variant suffix,
 * so a 1M session reports plain `claude-opus-5` there, 243 times in one
 * transcript. The authoritative record is the model-identity attachment -
 * `attachment.type === "model"` with `identity.modelId` = `claude-opus-5[1m]`
 * and `marketingName` = `Opus 5 (1M context)`. Last one wins: the model can
 * change mid-session.
 *
 * Order: CTX_CAP_WINDOW (an explicit override), then ctx/<sid>.win - the
 * harness's own `context_window.context_window_size`, written by the status line
 * (the same JSON that draws the true % on screen) - then a window marker in the
 * transcript (`[1m]`, "1M context"). Nothing else.
 *
 * Returns null when none of those says how big the window is. Null means "cannot
 * know", and the caller must not turn that into a number. ⛔ The old fallback -
 * "a claude-* id with no marker is 200k" - is what told 1M main sessions they were
 * at 117% (2026-10-15) and 163% (2026-10-23) while the
 * status line said 23% and 41%: Opus 5.5 runs 1M under the plain id
 * `claude-opus-5-5`. With no window, the absolute growth cap still measures.
 */
function windowFromTranscript(lines) {
  const env = envInt("CTX_CAP_WINDOW", "SUPERMODE_CTX_WINDOW");
  if (Number.isFinite(env) && env > 0) return env;
  try {
    const n = parseInt(readFileSync(resolve(ctxDir, `${sid}.win`), "utf-8").trim(), 10);
    if (Number.isFinite(n) && n > 0) return n;
  } catch { /* no status-line figure: try the transcript */ }
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i];
    if (!line || !line.includes('"modelId"')) continue;
    let d; try { d = JSON.parse(line); } catch { continue; }
    const id = d && d.attachment && d.attachment.type === "model" && d.attachment.identity;
    if (!id) continue;
    const modelId = String(id.modelId || "");
    const marketing = String(id.marketingName || "");
    const m = /\[(\d+)m\]/i.exec(modelId) || /\b(\d+)M\b/.exec(marketing);
    if (m) return parseInt(m[1], 10) * 1000 * 1000;
    return null;   // no marker: the plain id does NOT tell 200k from 1M, so do not guess
  }
  return null;
}

// 2. The tokens in use, from the transcript's last assistant turn - always read,
// because the absolute cap needs them whatever the gauge says - and, when the gauge
// is missing, the percentage estimated from them.
const capEnv = envInt("CTX_CAP_TOKENS", "SUPERMODE_CTX_TOKENS");
const cap = Number.isFinite(capEnv) && capEnv >= 0 ? capEnv : 80000;
let tokens = null, start = null;
function usedAt(line) {
  if (!line || !line.includes('"usage"')) return null;
  let d; try { d = JSON.parse(line); } catch { return null; }
  const u = d && d.type === "assistant" && d.message && d.message.usage;
  return u ? (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0) : null;
}
if (typeof input.transcript_path === "string" && existsSync(input.transcript_path)) {
  try {
    const lines = readFileSync(input.transcript_path, "utf-8").split("\n");
    for (let i = lines.length - 1; i >= 0 && tokens === null; i--) tokens = usedAt(lines[i]);
    for (let i = 0; i < lines.length && start === null; i++) start = usedAt(lines[i]);
    // No window, no percentage. "I could not find out" and "I found out you are
    // at 110%" are different answers, and only one of them is honest here.
    const window = pct === null && tokens !== null ? windowFromTranscript(lines) : null;
    if (window) { pct = Math.round((tokens / window) * 100); estimated = window; }
  } catch { /* no transcript figure: the gauge alone decides */ }
}
const grown = tokens !== null ? Math.max(0, tokens - (start || 0)) : null;
if (grown !== null) {
  try { writeFileSync(resolve(ctxDir, `${sid}.tok`), `${grown} ${tokens} ${start || 0}\n`); } catch { /* context-cap.mjs then stays silent */ }
}
// The fuller measure wins: % of the window, or % of the absolute cap on growth.
const capPct = cap > 0 && grown !== null ? Math.round((grown / cap) * 100) : null;
const byCap = capPct !== null && (pct === null || capPct > pct);
const eff = byCap ? capPct : pct;
if (eff === null || eff < threshold) process.exit(0);

// Once per 5% band.
const band = Math.floor(eff / 5) * 5;
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
  ? ` (estimated from the transcript against this session's own ${estimated >= 1e6 ? `${estimated / 1e6}M` : `${estimated / 1000}k`}-token window` +
    ` - let ctx-gauge.mjs front your status line for the exact figure, or set CTX_CAP_WINDOW to override)`
  : "";
const where = byCap
  ? `${Math.round(tokens / 1000)}k tokens - ${Math.round(grown / 1000)}k grown since its ${Math.round((start || 0) / 1000)}k start, ` +
    `${capPct}% of the ${Math.round(cap / 1000)}k growth cap (CTX_CAP_TOKENS)` +
    ` - at 100% context-cap.mjs refuses new reads and agent spawns`
  : `${pct}% of its context window${how}`;
const msg =
  `context guard: this session is at ${where}; the nudge threshold is ${threshold}%. ` +
  `Hand big reads, broad searches and self-contained slices to an Agent-tool subagent - it spends ITS context, ` +
  `not this one; take back the conclusion, not the file. ` +
  `If you are near the cap: finish the current task, commit it, write a short handoff note (done / next / blocked, ` +
  `with the exact numbers a fresh session cannot re-derive), and tell the user to start a fresh session. ` +
  `Do NOT compact: its summary drops the numbers a successor needs. This notice repeats once per 5% band.`;

process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: msg },
}) + "\n");
