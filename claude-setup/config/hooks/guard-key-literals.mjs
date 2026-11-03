#!/usr/bin/env node
// guard-key-literals - stops a live credential getting INTO a file. guard-secrets
// stops secrets getting out (reading .env); this one stops a key pasted into
// source, config or a script. Commit-message hooks check the MESSAGE; nothing
// checked file CONTENTS for keys before this.
//
// Wired on two events:
//   PreToolUse  Write|Edit|MultiEdit|NotebookEdit|Bash -> deny before it hits disk
//   PostToolUse Write|Edit|MultiEdit|NotebookEdit      -> re-read the saved file,
//                                                         tell the session to fix it
//
// It NEVER prints the matched value - that would put the key in the transcript,
// the thing both guards exist to prevent. Line numbers only.
//
// Skipped on purpose: a line that reads from the environment (process.env,
// $VAR ...), an obvious stand-in (your_, example, xxxx, placeholder ...), and
// .env.example/.sample/.template files. A line ending in `guard-key-literals:
// allow` is skipped too, for a test fixture that must look real.
//
// Ported from EricTechPro/super-board hooks/guard-key-literals.py (MIT), in Node
// because python3 on a Windows box can be the Microsoft Store stub.
//
// MODE: GUARD_KEY_LITERALS=off in the environment switches it off for one shell.
//
// FAILS SAFE. Bad JSON, unreadable file, anything unexpected: silence.

import { readFileSync } from "node:fs";

const Q = "[\"']";
const KEY_RE = new RegExp([
  "sk-ant-[A-Za-z0-9_-]{20,}",
  "sk-proj-[A-Za-z0-9_-]{20,}",
  "sk-[A-Za-z0-9]{24,}",
  "AKIA[0-9A-Z]{16}",
  "ASIA[0-9A-Z]{16}",
  "gh[pousr]_[A-Za-z0-9]{30,}",
  "github_pat_[A-Za-z0-9_]{30,}",
  "xox[baprs]-[A-Za-z0-9-]{12,}",
  "AIza[A-Za-z0-9_-]{35}",
  "sbp_[a-f0-9]{40}",
  "r8_[A-Za-z0-9]{35,}",
  "hf_[A-Za-z0-9]{30,}",
  "-----BEGIN [A-Z ]*PRIVATE KEY-----",
  "(?:api[_-]?key|secret|token|password|passwd|bearer)[A-Za-z_]*" + Q + "?\\s*[:=]\\s*" + Q +
    "[A-Za-z0-9_/+=.-]{24,}" + Q,
].join("|"), "i");

const SAFE_RE = /process\.env|import\.meta\.env|Deno\.env|os\.environ|getenv|ENV\[|System\.getenv|secrets\.|vars\.|\$\{?[A-Z][A-Z0-9_]*\}?|%[A-Z][A-Z0-9_]*%|guard-key-literals:\s*allow/;
const FAKE_RE = /your[-_]|my[-_]key|xxxx|<[A-Za-z_]|\.\.\.|placeholder|example|sample|template|changeme|change[-_]me|dummy|fake|redacted|REPLACE|TODO|\*\*\*\*/i;
const TEMPLATE_FILES = [".env.example", ".env.sample", ".env.template"];

function visibleText(input) {
  const ev = String(input.hook_event_name || "");
  const t = String(input.tool_name || "");
  const a = input.tool_input || {};
  if (ev === "PreToolUse") {
    if (t === "Write") return String(a.content || "");
    if (t === "Edit" || t === "MultiEdit") {
      return [a.new_string, ...((a.edits || []).map((e) => e && e.new_string))]
        .map((v) => String(v || "")).join("\n");
    }
    if (t === "NotebookEdit") return String(a.new_source || "");
    if (t === "Bash") return String(a.command || ""); // heredocs, echo >> file, sed -i
    return "";
  }
  if (ev === "PostToolUse") {
    const p = String(a.file_path || a.notebook_path || "");
    if (!p || TEMPLATE_FILES.some((s) => p.endsWith(s))) return "";
    try { return readFileSync(p, "utf8"); } catch { return ""; }
  }
  return "";
}

function hitLines(text) {
  const hits = [];
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length && hits.length < 5; i++) {
    const l = lines[i];
    if (KEY_RE.test(l) && !SAFE_RE.test(l) && !FAKE_RE.test(l)) hits.push(i + 1);
  }
  return hits;
}

function main() {
  if (String(process.env.GUARD_KEY_LITERALS || "").toLowerCase() === "off") return;
  let input = {};
  try { input = JSON.parse(readFileSync(0, "utf8") || "{}"); } catch { return; }
  const hits = hitLines(visibleText(input));
  if (!hits.length) return;
  const reason =
    `Possible live credential in this change, at line(s) ${hits.join(",")}. Do not print or repeat the value. ` +
    "Move it to the local .env, read it from the environment at the call site, and add only the key NAME " +
    "to .env.example. If it is a placeholder or test fixture, make it obviously fake (YOUR_..., example_...) " +
    "or end the line with `guard-key-literals: allow`. Checked by guard-key-literals.";
  const out = input.hook_event_name === "PreToolUse"
    ? { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason }
    : { hookEventName: "PostToolUse", additionalContext: reason };
  process.stdout.write(JSON.stringify({ hookSpecificOutput: out }));
}

try { main(); } catch { /* fail open */ }
