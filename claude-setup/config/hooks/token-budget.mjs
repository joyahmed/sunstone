#!/usr/bin/env node
// token-budget - a spend ceiling per main session, agents included. Pure Node.js.
//
// A PreToolUse hook, decided on 2026-10-06. context-cap.mjs limits how FULL
// one window gets; it says nothing about how much a session SPENDS. A session that
// delegates spends mostly through its agents, each with a fresh window, so a main
// session can sit comfortably under its own cap while its fan-out burns millions of
// tokens. This hook adds up the session and all its agents and, per main session:
//   - under TOKEN_BUDGET_WARN_PCT of the budget (default 67% = 2M of 3M): silent;
//   - from there to the budget: the Agent/Workflow call goes ahead, with a warning
//     printed ONCE per session ("this session and its agents have used X of 3M");
//   - at or over TOKEN_BUDGET_TOKENS (default 0 = off; e.g. 3000000): NEW Agent and Workflow calls
//     are denied. The main session itself keeps working - every other tool passes,
//     so it can finish, commit and hand off.
//
// "Tokens spent", the definition this hook uses: for each transcript, the sum over
// its assistant messages of
//     usage.input_tokens + usage.cache_creation_input_tokens + usage.output_tokens
// NOT cache_read_input_tokens: a cache read is the same context read again on every
// turn, so counting it would charge the whole window once per turn and make any long
// session look like tens of millions. Assistant messages are deduped by message.id
// (Claude Code writes one message over several lines, one per content block, each
// carrying the usage); for a repeated id the largest value of each field is kept.
//
// Transcripts summed (the same layout context-cap.mjs and agent-watch.mjs read):
//   main:      input.transcript_path
//   agents:    <dir of transcript_path>/<session_id>/subagents/agent-*.jsonl
//   workflows: <dir of transcript_path>/<session_id>/subagents/workflows/<run>/agent-*.jsonl
// Each file's sum is cached in ~/.claude/ctx/<sid>.budget.json by size + mtime, so an
// unchanged agent transcript is not re-read on every spawn. The once-per-session
// warning marker is ~/.claude/ctx/<sid>.budget-warned (same ctx dir as the others).
//
// Scope: ONLY tool_name "Agent" or "Workflow", ONLY from the main session (no
// agent_id in the input). A subagent spawning is the main session's decision already
// made; it is never touched here.
//
// Env: TOKEN_BUDGET_TOKENS (default 0 = off), TOKEN_BUDGET_WARN_PCT (default 67).
// OFF by default (2026-10-06): a 3M budget is not a
// problem if a single agent doesn't use up the safe limit of context and carry on. The limit that
// matters is each agent's own context - context-cap.mjs (wrap up at 70%, hard stop at 75%). Set
// TOKEN_BUDGET_TOKENS on a box to turn the session total back on.
//
// FAILS OPEN. Anything unexpected - bad stdin, no transcript, unreadable file - is
// answered with silence. A crashing hook must never be why a session cannot work.
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { homedir } from "node:os";

function cfgDir() {
  const e = process.env.CLAUDE_CONFIG_DIR;
  if (e && e.trim() !== "") return e.startsWith("~") ? resolve(homedir(), e.replace(/^~[/\\]?/, "")) : resolve(e);
  return resolve(homedir(), ".claude");
}
function envInt(name, dflt) {
  const n = parseInt(process.env[name] ?? "", 10);
  return Number.isFinite(n) && n >= 0 ? n : dflt;
}

// Spent tokens in one transcript, per the definition in the header.
function spentIn(file) {
  const byId = new Map();   // message.id -> [input, cache_creation, output], max per field
  let anon = 0;             // assistant lines with usage but no id: counted as they come
  for (const l of readFileSync(file, "utf-8").split("\n")) {
    if (!l.includes('"usage"')) continue;
    let d; try { d = JSON.parse(l); } catch { continue; }
    const m = d && d.type === "assistant" && d.message;
    const u = m && m.usage;
    if (!u) continue;
    const v = [u.input_tokens || 0, u.cache_creation_input_tokens || 0, u.output_tokens || 0];
    if (typeof m.id !== "string" || m.id === "") { anon += v[0] + v[1] + v[2]; continue; }
    const p = byId.get(m.id);
    byId.set(m.id, p ? p.map((x, i) => Math.max(x, v[i])) : v);
  }
  let sum = anon;
  for (const v of byId.values()) sum += v[0] + v[1] + v[2];
  return sum;
}

function agentFiles(transcript, sid) {
  const sub = resolve(dirname(transcript), sid, "subagents");
  const out = [];
  const take = (dir) => {
    try { for (const f of readdirSync(dir)) if (/^agent-.*\.jsonl$/.test(f)) out.push(resolve(dir, f)); } catch { /* none */ }
  };
  take(sub);
  try { for (const run of readdirSync(resolve(sub, "workflows"))) take(resolve(sub, "workflows", run)); } catch { /* none */ }
  return out;
}

try {
  let input = {};
  try { input = JSON.parse(readFileSync(0, "utf-8") || "{}"); } catch { process.exit(0); }
  if (!input || typeof input !== "object") process.exit(0);
  const tool = String(input.tool_name || "");
  if (tool !== "Agent" && tool !== "Workflow") process.exit(0);
  if (typeof input.agent_id === "string" && input.agent_id !== "") process.exit(0);   // a subagent: not ours
  const sid = typeof input.session_id === "string" ? input.session_id.replace(/[^A-Za-z0-9_-]/g, "") : "";
  if (!sid || typeof input.transcript_path !== "string" || !existsSync(input.transcript_path)) process.exit(0);

  const budget = envInt("TOKEN_BUDGET_TOKENS", 0);   // OFF by default since 2026-10-06 (see header)
  if (budget === 0) process.exit(0);
  const warnPct = envInt("TOKEN_BUDGET_WARN_PCT", 67);

  const ctx = resolve(cfgDir(), "ctx");
  try { mkdirSync(ctx, { recursive: true }); } catch { /* read-only home: no cache, no marker */ }
  const cacheFile = resolve(ctx, `${sid}.budget.json`);
  let cache = {};
  try { cache = JSON.parse(readFileSync(cacheFile, "utf-8")) || {}; } catch { cache = {}; }
  const fresh = {};
  let total = 0;
  for (const f of [input.transcript_path, ...agentFiles(input.transcript_path, sid)]) {
    let st; try { st = statSync(f); } catch { continue; }
    const c = cache[f];
    const n = c && c.size === st.size && c.mtime === st.mtimeMs ? c.sum : spentIn(f);
    fresh[f] = { size: st.size, mtime: st.mtimeMs, sum: n };
    total += n;
  }
  try { writeFileSync(cacheFile, JSON.stringify(fresh)); } catch { /* cache is an optimisation */ }

  const k = (n) => (n >= 1e6 ? `${(n / 1e6).toFixed(2)}M` : `${Math.round(n / 1000)}k`);
  if (total >= budget) {
    const reason =
      `Token budget reached: this session and its agents have used ${k(total)} tokens, budget ${k(budget)}. ` +
      `No new ${tool} calls - the main session can keep working (Read, Edit, Bash and the rest still go through), ` +
      `so finish here, commit and hand off. To raise the budget set TOKEN_BUDGET_TOKENS (0 turns it off).`;
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
    }) + "\n");
    process.exit(0);
  }
  if (total < (budget * warnPct) / 100) process.exit(0);

  const marker = resolve(ctx, `${sid}.budget-warned`);
  if (existsSync(marker)) process.exit(0);
  try { writeFileSync(marker, `${total}\n`); } catch { process.exit(0); }   // no marker = no once-only guarantee: stay quiet
  const msg =
    `Token budget: this session and its agents have used ${k(total)} of the ${k(budget)} budget. ` +
    `At ${k(budget)} new agents are blocked (the main session keeps working) - spend the rest on what matters.`;
  process.stdout.write(JSON.stringify({
    systemMessage: msg,
    hookSpecificOutput: { hookEventName: "PreToolUse", additionalContext: msg },
  }) + "\n");
  process.exit(0);
} catch {
  process.exit(0);
}
