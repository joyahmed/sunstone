#!/usr/bin/env node
// context-cap - the hard stop behind context-guard's nudge. Pure Node.js.
//
// A PreToolUse hook. context-guard.mjs NUDGES; a nudge is advice, and on
// 2026-09-29 sessions were measured running past 150k with it firing, which
// spent half a week's quota. This hook is the part that does not ask: once a
// session has grown CTX_CAP_TOKENS (default 80000) past its first turn, it
// refuses the calls that START new work - reading, searching, spawning an agent -
// and leaves the ones that FINISH it: Bash (the gate, git), Edit/Write (the
// handoff note), and an Agent whose prompt contains "resume" (a successor that
// picks the work up from the handoff).
//
// Scope, on purpose:
//   - EVERY main session. It was supermode-only until supermode was retired on
//     2026-09-29; the cap is now the same for everyone.
//   - a SUBAGENT gets its own rule (added 2026-10-02): it has its own window, so it
//     is measured from its OWN transcript (<session dir>/subagents/agent-<id>.jsonl),
//     against its own window, and at SUBAGENT_CTX_PCT (default 70%) it is refused new
//     reads/searches/agents and told to end with a "HANDOVER:" answer. context-guard
//     sees that answer in the main session and has it start a fresh agent from it.
//     The requirement: past 70%, no agent - main or spawned, foreground or background -
//     keeps spending context; it hands over to a fresh one. Before this a subagent ran to
//     the harness's auto-compaction, whose summary drops the numbers a successor needs.
//     The rule (2026-10-05): wrap up at 70%, hand over by 75% at the latest - this hook
//     is the 70% line; 75% is the hard ceiling nothing may cross.
//     Hard ceiling (2026-10-06: no agent may cross 70-75% at any cost): at
//     SUBAGENT_CTX_HARD_PCT (default 75, never below SUBAGENT_CTX_PCT) EVERY tool is refused,
//     Edit and Write included - except the ones that deliver the final report
//     (SubagentHandback, SendMessage, StructuredOutput), or the work would be lost.
//     Workflow-tool agents are covered too: their transcript is one level down,
//     <session dir>/subagents/workflows/<run>/agent-<id>.jsonl.
//
// The figure is ctx/<session_id>.tok, "<grown> <total> <start>", written by
// context-guard.mjs after every tool call. No file, or one older than 10 minutes:
// silence. CTX_CAP_TOKENS=0 turns the cap off (the old name SUPERMODE_CTX_TOKENS
// is still read as a fallback).
//
// FAILS OPEN. Anything unexpected is answered with silence - a crashing hook must
// never be why a session cannot work.
import { existsSync, readFileSync, readdirSync, statSync, openSync, readSync, closeSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { homedir } from "node:os";

function cfgDir() {
  const e = process.env.CLAUDE_CONFIG_DIR;
  if (e && e.trim() !== "") return e.startsWith("~") ? resolve(homedir(), e.replace(/^~[/\\]?/, "")) : resolve(e);
  return resolve(homedir(), ".claude");
}
function envInt(name, legacy) {
  for (const k of [name, legacy]) {
    const n = parseInt(process.env[k] ?? "", 10);
    if (Number.isFinite(n)) return n;
  }
  return NaN;
}

// The last assistant turn's usage (input + cache read + cache creation), and the
// window from the model identity line - the same reading context-guard.mjs does.
function readAgent(file) {
  const st = statSync(file);
  const take = (pos, len) => {
    const fd = openSync(file, "r");
    const b = Buffer.alloc(len);
    readSync(fd, b, 0, len, pos);
    closeSync(fd);
    return b.toString("utf-8").split("\n");
  };
  const tail = take(Math.max(0, st.size - 512 * 1024), Math.min(st.size, 512 * 1024));
  let tokens = null;
  for (let i = tail.length - 1; i >= 0 && tokens === null; i--) {
    const l = tail[i];
    if (!l.includes('"usage"')) continue;
    let d; try { d = JSON.parse(l); } catch { continue; }
    const u = d && d.type === "assistant" && d.message && d.message.usage;
    if (u) tokens = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
  }
  let win = null;
  const envWin = parseInt(process.env.SUBAGENT_CTX_WINDOW ?? "", 10);
  if (Number.isFinite(envWin) && envWin > 0) win = envWin;
  for (const l of win ? [] : take(0, Math.min(st.size, 512 * 1024)).concat(tail)) {
    if (!l.includes('"modelId"') && !l.includes('"model"')) continue;
    let d; try { d = JSON.parse(l); } catch { continue; }
    const id = String((d.attachment && d.attachment.identity && d.attachment.identity.modelId) || (d.message && d.message.model) || "");
    const m = /\[(\d+)m\]/i.exec(id);
    if (m) { win = parseInt(m[1], 10) * 1e6; break; }
  }
  return { tokens, win: win || 200000 };   // no [1m] marker anywhere: the standard window
}

function subagent(input, sid) {
  const pctEnv = parseInt(process.env.SUBAGENT_CTX_PCT ?? "", 10);
  const pct = Number.isFinite(pctEnv) && pctEnv >= 0 ? pctEnv : 70;
  if (pct === 0 || typeof input.transcript_path !== "string") return;
  const aid = String(input.agent_id).replace(/[^A-Za-z0-9_-]/g, "");
  const sub = resolve(dirname(input.transcript_path), sid, "subagents");
  let file = resolve(sub, `agent-${aid}.jsonl`);
  if (!existsSync(file)) {
    // Workflow-tool agents write one level down: subagents/workflows/<run>/agent-<id>.jsonl
    // (verified 2026-10-05; before this the 70% rule never reached them).
    file = "";
    try {
      for (const run of readdirSync(resolve(sub, "workflows"))) {
        const f = resolve(sub, "workflows", run, `agent-${aid}.jsonl`);
        if (existsSync(f)) { file = f; break; }
      }
    } catch { /* no workflows dir: fail open */ }
    if (!file) return;
  }
  const { tokens, win } = readAgent(file);
  if (tokens === null || tokens < (win * pct) / 100) return;
  const tool = String(input.tool_name || "");
  // The tools that deliver the final report are never blocked: refusing them loses the work.
  if (/^(SubagentHandback|SendMessage|StructuredOutput)$/.test(tool)) return;
  const hardEnv = parseInt(process.env.SUBAGENT_CTX_HARD_PCT ?? "", 10);
  const hard = Math.max(Number.isFinite(hardEnv) && hardEnv > 0 ? hardEnv : 75, pct);
  const atHard = tokens >= (win * hard) / 100;
  // Bash is blocked too (2026-10-05): with Bash open, an agent past the line could keep
  // reading through `cat` and `sed -n` and pass 75%. Between the two lines Edit and Write stay
  // open - their results are a line, so the agent can still save the step it is on.
  if (!atHard && !(tool === "Agent" || /^(Read|Grep|Glob|WebFetch|WebSearch|Bash)$/.test(tool) || /ctx_[a-z_]+$/.test(tool))) return;
  const k = (n) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : `${Math.round(n / 1000)}k`);
  const now = `Your context is at ${k(tokens)} of ${k(win)} (${Math.round((tokens / win) * 100)}%)`;
  const tail = ` make your final answer start with "HANDOVER:" - what is done (commits, paths), what is left, the exact ` +
    `next steps, and every number or fact a fresh agent could not re-derive. The main session starts a fresh agent from it.`;
  const reason = atHard
    ? `${now}, at the ${hard}% hard ceiling. Every tool is blocked now, ${tool} included. Stop and` + tail
    : `${now}, past the ${pct}% handover point (${hard}% is the hard ceiling). ` +
      `Start nothing new (${tool} is blocked; only Edit and Write still work). Finish the step you are on, then` + tail;
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
  }) + "\n");
}

try {
  let input = {};
  try { input = JSON.parse(readFileSync(0, "utf-8") || "{}"); } catch { process.exit(0); }
  const sid = typeof input.session_id === "string" ? input.session_id.replace(/[^A-Za-z0-9_-]/g, "") : "";
  if (!sid) process.exit(0);
  if (typeof input.agent_id === "string" && input.agent_id !== "") { subagent(input, sid); process.exit(0); }

  const capEnv = envInt("CTX_CAP_TOKENS", "SUPERMODE_CTX_TOKENS");
  const cap = Number.isFinite(capEnv) && capEnv >= 0 ? capEnv : 80000;
  if (cap === 0) process.exit(0);

  const tokFile = resolve(cfgDir(), "ctx", `${sid}.tok`);
  if (!existsSync(tokFile) || Date.now() - statSync(tokFile).mtimeMs > 10 * 60 * 1000) process.exit(0);
  const [grown] = readFileSync(tokFile, "utf-8").trim().split(/\s+/).map((n) => parseInt(n, 10));
  if (!Number.isFinite(grown) || grown < cap) process.exit(0);

  const tool = String(input.tool_name || "");
  const args = input.tool_input || {};
  if (tool === "Agent" && /resume/i.test(String(args.prompt || ""))) process.exit(0);
  const starts = tool === "Agent" || /^(Read|Grep|Glob|WebFetch|WebSearch)$/.test(tool) || /ctx_[a-z_]+$/.test(tool);
  if (!starts) process.exit(0);

  const k = (n) => `${Math.round((n || 0) / 1000)}k`;
  const reason =
    `This chat is full (${k(grown)} grown since start, cap ${k(cap)}). Finish the current task, commit, ` +
    `write a short handoff note, and tell the user to open a fresh session. (${tool} is blocked; Bash, Edit and Write still work.)`;
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
  }) + "\n");
  process.exit(0);
} catch {
  process.exit(0);
}
