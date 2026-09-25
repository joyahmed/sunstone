#!/usr/bin/env node
// agent-watch - the gauge for the agents, the way ctx-gauge is the gauge for the
// session. Pure Node.js, no shell dependency.
//
// Supermode is orchestration: the session reads, decides and DELEGATES, and the
// agents spend the context. That only works if the orchestrator can see how full
// each agent's window is - and until 2026-09-25 the standing belief (written into
// context-guard.mjs) was that it cannot: "no gauge file and no transcript record is
// written for a subagent". That is false. Claude Code writes every subagent's own
// transcript next to the session's:
//
//   ~/.claude/projects/<slug>/<session-id>/subagents/agent-<id>.jsonl
//   ~/.claude/projects/<slug>/<session-id>/subagents/agent-<id>.meta.json
//
// The .jsonl carries the agent's assistant turns with their `usage` (the same
// input + cache_read + cache_creation sum the session guard uses), and the
// .meta.json carries `agentType` and the one-line `description` the orchestrator
// gave it. So an agent's context usage IS readable, from the orchestrator, while
// the agent is still running.
//
// Two jobs:
//   1. Every PostToolUse, write ~/.claude/ctx/<sid>.agents.json - a four-field
//      summary the STATUS LINE reads, so the `sm` segment can show how many agents
//      are live and how full the fullest one is. Nothing parses transcripts on the
//      status line's hot path.
//   2. Nudge the orchestrator - as hook context it can see - when an agent crosses
//      a 10% band above the threshold (60% by default), and once with the final
//      figure when an Agent call returns. An agent at 70% will not finish a large
//      slice; the answer is to take its result back and respawn a narrower one,
//      which only happens if the orchestrator is told.
//
// Runs only while supermode is active (the flag file supermode-trigger.mjs writes,
// or SUPERMODE=1 from the launcher). Silent otherwise, silent on every failure: a
// gauge never blocks a tool call.
//
// Also a CLI, for when the orchestrator wants the picture between slices:
//   node ~/.claude/hooks/agent-watch.mjs --report [session-id]
//
// Tunables: SUPERMODE_AGENT_PCT (nudge threshold, default 60),
//           SUPERMODE_AGENT_WINDOW (override the per-agent window in tokens).
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync, openSync, readSync, closeSync, fstatSync } from "node:fs";
import { resolve, dirname, join, basename } from "node:path";
import { homedir } from "node:os";

const CLI = process.argv.slice(2).some((a) => a === "--report" || a === "-r");

function cfgDir() {
  const e = process.env.CLAUDE_CONFIG_DIR;
  if (e && e.trim() !== "") return e.startsWith("~") ? resolve(homedir(), e.replace(/^~[/\\]?/, "")) : resolve(e);
  return resolve(homedir(), ".claude");
}
const CTX = resolve(cfgDir(), "ctx");

// --- input -----------------------------------------------------------------
let input = {};
if (!CLI) {
  try { input = JSON.parse(readFileSync(0, "utf-8") || "{}"); } catch { input = {}; }
}
const clean = (s) => (typeof s === "string" ? s.replace(/[^A-Za-z0-9_-]/g, "") : "");
let sid = clean(input.session_id) || clean(process.argv.slice(2).find((a) => !a.startsWith("-")));

// Supermode only - except from the CLI, where asking IS the intent.
function supermodeOn(id) {
  if (process.env.SUPERMODE === "1") return true;
  try { return id ? existsSync(resolve(CTX, `${id}.sm`)) : false; } catch { return false; }
}
if (!CLI && !supermodeOn(sid)) process.exit(0);

// --- where the agents write ------------------------------------------------
// The session transcript is <dir>/<sid>.jsonl and the agents live in <dir>/<sid>/subagents.
// CLI-only: set when subagentsDir() had to resolve a session rather than being
// given one, so the report can say whose agents it printed instead of just
// printing them.
let inferredSid = null;
// CLI-only: set instead of guessing when more than one session on the box has
// delegated agents - a bare --report has no way to know which one the reader
// means, and guessing is how a report about session A gets printed while
// session B is the one on screen.
let ambiguousSids = null;
function subagentsDir() {
  const t = input.transcript_path;
  if (typeof t === "string" && t.endsWith(".jsonl")) {
    const d = join(t.slice(0, -".jsonl".length), "subagents");
    if (existsSync(d)) return d;
  }
  // No transcript path (CLI, or an older harness): find it under the projects tree.
  const projects = resolve(cfgDir(), "projects");
  if (CLI && !sid) {
    // No session id given on the CLI: collect every candidate instead of
    // picking the most recently written one by mtime.
    const found = [];
    try {
      for (const slug of readdirSync(projects)) {
        let entries = [];
        try { entries = readdirSync(join(projects, slug)); } catch { continue; }
        for (const e of entries) {
          const d = join(projects, slug, e, "subagents");
          try { found.push({ sid: e, dir: d, mtime: statSync(d).mtimeMs }); } catch { /* not a session dir */ }
        }
      }
    } catch { /* no projects tree */ }
    if (found.length === 0) return null;
    if (found.length > 1) { ambiguousSids = found.map((f) => f.sid); return null; }
    inferredSid = found[0].sid;
    return found[0].dir;
  }
  let best = null;
  try {
    for (const slug of readdirSync(projects)) {
      const d = sid ? join(projects, slug, sid, "subagents") : null;
      if (d && existsSync(d)) return d;
      if (sid) continue;
      // No session id either: the most recently written subagents dir on the box.
      let entries = [];
      try { entries = readdirSync(join(projects, slug)); } catch { continue; }
      for (const e of entries) {
        const d2 = join(projects, slug, e, "subagents");
        try {
          const m = statSync(d2).mtimeMs;
          if (!best || m > best.m) best = { m, d: d2 };
        } catch { /* not a session dir */ }
      }
    }
  } catch { /* no projects tree */ }
  return best ? best.d : null;
}

// --- reading one agent -----------------------------------------------------
// The last 512 KB is plenty: usage sits on every assistant turn, so the last one
// is always near the end, and an agent transcript can be tens of megabytes.
function readTail(path, bytes = 512 * 1024) {
  let fd;
  try {
    fd = openSync(path, "r");
    const size = fstatSync(fd).size;
    const len = Math.min(size, bytes);
    const buf = Buffer.alloc(len);
    readSync(fd, buf, 0, len, size - len);
    return buf.toString("utf-8");
  } catch { return ""; } finally { try { if (fd !== undefined) closeSync(fd); } catch { /* */ } }
}

// The window this agent has. Same rule as context-guard: the variant suffix is the
// only honest source, and "cannot know" must not become a number - an unknown model
// is reported without a percentage rather than measured against a guess.
function windowOf(lines) {
  const env = parseInt(process.env.SUPERMODE_AGENT_WINDOW || "", 10);
  if (Number.isFinite(env) && env > 0) return env;
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i];
    if (!line || !line.includes('"modelId"')) continue;
    let d; try { d = JSON.parse(line); } catch { continue; }
    const id = d && d.attachment && d.attachment.type === "model" && d.attachment.identity;
    if (!id) continue;
    const m = /\[(\d+)m\]/i.exec(String(id.modelId || "")) || /\b(\d+)M\b/.exec(String(id.marketingName || ""));
    if (m) return parseInt(m[1], 10) * 1000 * 1000;
    break;
  }
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i];
    if (!line || !line.includes('"model"')) continue;
    let d; try { d = JSON.parse(line); } catch { continue; }
    const model = d && d.message && d.message.model;
    if (!model) continue;
    if (/\[(\d+)m\]/i.test(model)) return parseInt(/\[(\d+)m\]/i.exec(model)[1], 10) * 1000 * 1000;
    if (/^claude-(opus|sonnet|haiku|fable)/.test(model)) return 200000;
    return null;
  }
  return null;
}

function agents(dir) {
  const out = [];
  let files = [];
  try { files = readdirSync(dir).filter((f) => f.endsWith(".jsonl")); } catch { return out; }
  for (const f of files) {
    const p = join(dir, f);
    let mtime = 0, size = 0;
    try { const s = statSync(p); mtime = s.mtimeMs; size = s.size; } catch { continue; }
    const id = f.replace(/^agent-/, "").replace(/\.jsonl$/, "");
    let meta = {};
    try { meta = JSON.parse(readFileSync(join(dir, `${f.slice(0, -6)}.meta.json`), "utf-8")); } catch { /* older run */ }
    const lines = readTail(p).split("\n");
    const window = windowOf(lines);
    let used = null, turns = 0;
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i];
      if (!line || !line.includes('"usage"')) continue;
      let d; try { d = JSON.parse(line); } catch { continue; }
      const u = d && d.type === "assistant" && d.message && d.message.usage;
      if (!u) continue;
      used = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
      break;
    }
    for (const line of lines) if (line.includes('"type":"assistant"')) turns++;
    out.push({
      id,
      type: meta.agentType || "?",
      what: meta.description || "",
      used,
      window,
      pct: used !== null && window ? Math.round((used / window) * 100) : null,
      mtime, size, turns,
      live: Date.now() - mtime < 120 * 1000,
    });
  }
  out.sort((a, b) => b.mtime - a.mtime);
  return out;
}

const dir = subagentsDir();
const list = dir ? agents(dir) : [];
const live = list.filter((a) => a.live);

// --- CLI -------------------------------------------------------------------
const fmt = (a) =>
  `${a.live ? "live" : "done"}  ${a.pct === null ? " ? " : String(a.pct).padStart(3) + "%"}  ` +
  `${a.used === null ? "" : (a.used / 1000).toFixed(0) + "k"}${a.window ? "/" + (a.window >= 1e6 ? a.window / 1e6 + "M" : a.window / 1000 + "k") : ""}  ` +
  `${a.type}  ${a.what || a.id}`;
if (CLI) {
  if (ambiguousSids) {
    console.log(`agent-watch: ${ambiguousSids.length} sessions on this box have delegated agents - no session id given, so refusing to guess which one. Pass one: node ~/.claude/hooks/agent-watch.mjs --report <session-id>`);
    for (const s of ambiguousSids) console.log("  " + s);
    process.exit(0);
  }
  if (!dir) { console.log("agent-watch: no subagents directory for this session - nothing has been delegated yet."); process.exit(0); }
  if (!list.length) { console.log(`agent-watch: ${dir} is empty - nothing has been delegated yet.`); process.exit(0); }
  const resolved = inferredSid ? `  [session ${inferredSid}, inferred - the only one on this box with delegated agents]` : "";
  console.log(`agent-watch: ${live.length} live / ${list.length} total  (${dir})${resolved}`);
  for (const a of list.slice(0, 20)) console.log("  " + fmt(a));
  process.exit(0);
}

// --- 1. the status line's summary -----------------------------------------
try {
  mkdirSync(CTX, { recursive: true });
  const top = live.reduce((m, a) => (a.pct !== null && (!m || a.pct > m.pct) ? a : m), null);
  writeFileSync(
    resolve(CTX, `${sid}.agents.json`),
    JSON.stringify({ ts: Date.now(), live: live.length, total: list.length, max: top ? top.pct : null, what: top ? top.what : "" }) + "\n",
  );
} catch { /* the summary is a courtesy */ }

// --- 2. the nudge ----------------------------------------------------------
const threshold = Math.max(1, Math.min(99, parseInt(process.env.SUPERMODE_AGENT_PCT || "60", 10) || 60));
const bandFile = resolve(CTX, `${sid}.agentbands.json`);
let bands = {};
try { bands = JSON.parse(readFileSync(bandFile, "utf-8")); } catch { bands = {}; }

const say = [];

// An Agent call has just returned: report what that slice cost, once, whatever the
// figure. This is how the orchestrator learns the size of its own slices.
if (input.tool_name === "Agent" && list.length) {
  const a = list[0];
  if (a.pct !== null && !bands[`${a.id}:final`]) {
    bands[`${a.id}:final`] = 1;
    say.push(`agent finished: "${a.what || a.id}" (${a.type}) ended at ${a.pct}% of its ${a.window >= 1e6 ? a.window / 1e6 + "M" : a.window / 1000 + "k"} window (${(a.used / 1000).toFixed(0)}k tokens, ${a.turns} turns).`);
  }
}

for (const a of live) {
  if (a.pct === null || a.pct < threshold) continue;
  const band = Math.floor(a.pct / 10) * 10;
  if ((bands[a.id] || 0) >= band) continue;
  bands[a.id] = band;
  say.push(`agent "${a.what || a.id}" (${a.type}) is at ${a.pct}% of its window and still running - it will not finish a large slice. Take its result back at the next checkpoint and respawn a narrower slice rather than letting it fill.`);
}

try { writeFileSync(bandFile, JSON.stringify(bands) + "\n"); } catch { /* nudge anyway */ }

// Housekeeping: band/summary files from sessions older than a week.
try {
  const cutoff = Date.now() - 7 * 24 * 60 * 60 * 1000;
  for (const f of readdirSync(CTX)) {
    if (!/\.(agents|agentbands)\.json$/.test(f)) continue;
    const p = resolve(CTX, f);
    try { if (statSync(p).mtimeMs < cutoff) writeFileSync(p, "{}\n"); } catch { /* skip */ }
  }
} catch { /* skip */ }

if (!say.length) process.exit(0);
process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext:
      "supermode agent watch - " + say.join(" ") +
      ` (${live.length} live of ${list.length} delegated; \`node ~/.claude/hooks/agent-watch.mjs --report\` for the full picture).`,
  },
}) + "\n");
