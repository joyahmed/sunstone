#!/usr/bin/env node
// require-agent-model - a PreToolUse hook matched to the Agent tool. The
// rule: the top-tier model plans, orchestrates, and decides models -
// delegating means orchestrating, fanning out, AND choosing the model per
// task. Measured baseline: of ~20 agents spawned in one session, the first
// six inherited Opus with no decision made at all.
//
// THE CHECK IS AN UNAMBIGUOUS BINARY FACT: does this Agent call carry a
// `model` parameter or not. No inference about whether the choice was RIGHT -
// only whether one was made. That is what makes it safe to default to warn
// without ever second-guessing a model name.
//
// ONE SOFT EXCEPTION (2026-10-25): when a model IS named, a second, warn-only
// check asks whether a lookup brief went one tier too high (scout not on
// haiku, or a find/list/count brief on sonnet/opus/fable). It never blocks,
// not even under REQUIRE_AGENT_MODEL=block - see tierHint() at the bottom.
//
// ⛔ `subagent_type: "fork"` IGNORES a model override (a fork always inherits
// the caller's model) - so a fork call with no `model` is not a missed
// decision, it is a parameter that would do nothing. Never nagged.
//
// MODE, resolved env > sunstone.conf > default, same house pattern as
// VISUAL_GATE:
//   REQUIRE_AGENT_MODEL=block ...              one shell, this session
//   REQUIRE_AGENT_MODEL=warn  in sunstone.conf  the fleet, one line
// warn (default) = additionalContext + systemMessage, the call proceeds.
// block           = permissionDecision:"deny" - the call is refused, with the
//                    reason spelled out so the orchestrator picks a model and
//                    retries.
//
// FAILS SAFE. Bad JSON on stdin, an unreadable conf file, anything
// unexpected: caught, and answered with silence - allow the call. A hook that
// crashes must never be why an Agent call cannot be made.

import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { homedir } from "node:os";

function main() {
  let input = {};
  try { input = JSON.parse(readFileSync(0, "utf8") || "{}"); } catch { return; }

  if (String(input.tool_name || "") !== "Agent") return;
  const args = input.tool_input || {};

  if (args.subagent_type === "fork") return; // a model override does nothing here
  const hasModel = typeof args.model === "string" && args.model.trim() !== "";

  function cfgDir() {
    const e = process.env.CLAUDE_CONFIG_DIR;
    if (e && e.trim() !== "") return e.startsWith("~") ? resolve(homedir(), e.replace(/^~[/\\]?/, "")) : resolve(e);
    return resolve(homedir(), ".claude");
  }

  const normalize = (v) => {
    switch (String(v || "").toLowerCase()) {
      case "off": case "none": case "0": return "off";
      case "block": case "blocking": return "block";
      case "warn": case "warning": return "warn";
      default: return "";
    }
  };
  let mode = normalize(process.env.REQUIRE_AGENT_MODEL);
  if (!mode) {
    let personal = "";
    try { personal = readFileSync(resolve(cfgDir(), "ai-memory-path"), "utf8").split(/\r?\n/)[0].trim()
      .replace(/^\/([a-zA-Z])(?=\/|$)/, (m, d) => (process.platform === "win32" ? d.toUpperCase() + ":" : m)); } catch { personal = ""; } // Git Bash /c/ -> C:
    if (!personal) {
      try { if (existsSync(resolve(homedir(), ".ai-memory", ".git"))) personal = resolve(homedir(), ".ai-memory"); } catch { /* ignore */ }
    }
    if (personal) {
      try {
        const conf = readFileSync(resolve(personal, "claude-setup", "config", "sunstone.conf"), "utf8");
        const line = conf.split(/\r?\n/).reverse().find((l) => /^\s*REQUIRE_AGENT_MODEL\s*=/.test(l));
        if (line) {
          let v = line.replace(/^\s*REQUIRE_AGENT_MODEL\s*=/, "");
          const t = v.trim();
          v = t.startsWith('"') ? t.slice(1, t.indexOf('"', 1) === -1 ? undefined : t.indexOf('"', 1)) : t.replace(/\s+#.*$/, "").trim();
          mode = normalize(v);
        }
      } catch { /* optional file */ }
    }
  }
  if (!mode) mode = "warn";
  if (mode === "off") return;

  const desc = typeof args.description === "string" && args.description ? ` ("${args.description}")` : "";

  if (hasModel) {
    // TIER CHECK - a model WAS chosen; is it one tier too high for a lookup?
    // Always a warning, never a deny, even in block mode: this is inference
    // about a brief, not the binary fact the missing-model check rests on.
    const tierMsg = tierHint(args, desc);
    if (!tierMsg) return;
    try {
      process.stdout.write(JSON.stringify({
        systemMessage: tierMsg,
        hookSpecificOutput: { hookEventName: "PreToolUse", additionalContext: tierMsg },
      }));
    } catch { /* nothing to be done */ }
    return;
  }

  const scoutHint = String(args.subagent_type || "").toLowerCase() === "scout" ? ` A scout runs on haiku: model "haiku".` : "";
  const msg =
    `Agent call${desc} has no model parameter. Opus plans, orchestrates and decides ` +
    `models - delegating means choosing the model per task, not inheriting whatever the ` +
    `harness defaults to. Name one explicitly (sonnet/opus/haiku/fable) before spawning.` + scoutHint;

  const out = { systemMessage: msg };
  if (mode === "block") {
    out.hookSpecificOutput = {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: msg,
    };
  } else {
    out.hookSpecificOutput = { hookEventName: "PreToolUse", additionalContext: msg };
  }
  try { process.stdout.write(JSON.stringify(out)); } catch { /* nothing to be done */ }
}

// HAIKU TIER (2026-10-25: the haiku tier was not being used at all). An
// 11-agent run used 8 sonnet + 3 opus + 0 haiku: every find/list/count brief
// went one tier too high. Two cases warn, neither ever blocks:
//   1. subagent_type "scout" with a model that is not haiku - scout exists to
//      be the cheap tier.
//   2. a brief that is lookup-shaped (find/list/count/locate/inventory/...)
//      sent to sonnet/opus/fable, AND carries no edit or judgement verb.
// CONSERVATIVE BY DESIGN: one edit/judgement word anywhere in description or
// prompt ("fix", "write", "review", "plan", ...) and it stays silent, so a
// mixed "find X and fix it" brief never warns. A missed nudge costs a little;
// a nagging false one teaches everyone to ignore the hook.
const LOOKUP_RE = /\b(find|finds|finding|list|lists|listing|count|counts|counting|locate|locates|locating|inventor(y|ies)|enumerate|enumerating|grep|tally|where\s+(is|are|does|do))\b/i;
const ACT_RE = new RegExp("\\b(" + [
  "edit", "edits", "edited", "editing", "fix", "fixes", "fixed", "fixing",
  "commit", "commits", "committed", "committing", "push", "write", "writes", "writing", "wrote", "written",
  "implement", "implements", "implementing", "build", "builds", "building", "built",
  "create", "creates", "creating", "add", "adds", "adding", "update", "updates", "updating",
  "delete", "deleting", "remove", "removing", "modify", "modifying", "change", "changes", "changing",
  "refactor", "refactoring", "rename", "renaming", "patch", "migrate", "migrating", "rewrite", "replace",
  "install", "deploy", "run the tests",
  "plan", "planning", "design", "designing", "review", "reviewing", "verify", "verifying", "audit", "auditing",
  "decide", "decision", "debug", "debugging", "diagnose", "investigate", "analy[sz]e", "analysis",
  "assess", "evaluate", "judge", "explain", "summari[sz]e", "summary", "research", "recommend", "propose",
].join("|") + ")\\b", "i");

function tierHint(args, desc) {
  const model = String(args.model || "").trim().toLowerCase();
  if (model === "haiku" || model.includes("haiku")) return "";
  const type = String(args.subagent_type || "").trim().toLowerCase();
  const fix = `Lookups are haiku work: subagent_type "scout" + model "haiku". ` +
    `Ignore this if the brief also edits or needs judgement.`;
  if (type === "scout") {
    return `Agent call${desc} is a scout on model "${args.model}". A scout exists to be the ` +
      `cheap tier - pass model "haiku". ` + fix;
  }
  const isTop = /^(sonnet|opus|fable)\b/.test(model) || /claude-(sonnet|opus|fable)/.test(model);
  if (!isTop) return "";
  const text = `${args.description || ""}\n${args.prompt || ""}`;
  if (!LOOKUP_RE.test(text) || ACT_RE.test(text)) return "";
  return `Agent call${desc} reads as a find/list/count brief but runs on ${args.model}. ` + fix;
}

try { main(); } catch { /* fail safe: allow the call, say nothing */ }
