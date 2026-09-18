#!/usr/bin/env node
// ctx-gauge — the context gauge for supermode. Pure Node.js, no shell dependency.
//
// Claude Code tells the STATUS LINE how full the context window is
// (`context_window.used_percentage`) and tells HOOKS nothing of the kind. The model
// cannot read its own gauge either. So this script sits in front of your status line:
// it reads the status-line JSON from stdin, writes the percentage to
// ~/.claude/ctx/<session_id>.pct, then hands the same JSON to your real status line
// and prints whatever that prints. context-guard.mjs reads the file after every tool
// call. Nothing about your status line changes except that the number now exists on
// disk.
//
// Registered only by supermode.settings.json (statusLine → this script), so it runs
// only in supermode sessions. Your own status line is found in this order:
//   $SUPERMODE_STATUSLINE                 an explicit command, run through the shell
//   ~/.claude/statusline-command.sh       (bash)
//   ~/.claude/statusline-command.js/.mjs  (node)
// and when none exists a one-line fallback is printed instead.
import { existsSync, mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { resolve, basename } from "node:path";
import { homedir } from "node:os";
import { spawnSync } from "node:child_process";

function cfgDir() {
  const e = process.env.CLAUDE_CONFIG_DIR;
  if (e && e.trim() !== "") return e.startsWith("~") ? resolve(homedir(), e.replace(/^~[/\\]?/, "")) : resolve(e);
  return resolve(homedir(), ".claude");
}

let raw = "";
try { raw = readFileSync(0, "utf-8"); } catch { raw = ""; }
let data = {};
try { data = JSON.parse(raw || "{}"); } catch { data = {}; }

// The percentage: what Claude Code computed, else our own division, else nothing.
const cw = data.context_window || {};
let pct = typeof cw.used_percentage === "number" ? cw.used_percentage : null;
if (pct === null && cw.current_usage && cw.context_window_size) {
  const u = cw.current_usage;
  const used = (u.input_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.cache_read_input_tokens || 0);
  pct = (used / cw.context_window_size) * 100;
}
const sid = typeof data.session_id === "string" ? data.session_id.replace(/[^A-Za-z0-9_-]/g, "") : "";
if (pct !== null && sid) {
  try {
    const dir = resolve(cfgDir(), "ctx");
    mkdirSync(dir, { recursive: true });
    // One integer, one line. The guard also reads the file's mtime, so a stale
    // gauge from a finished session is never mistaken for a live one.
    writeFileSync(resolve(dir, `${sid}.pct`), `${Math.round(pct)}\n`);
  } catch { /* the gauge is a courtesy; the status line must still render */ }
}

// Delegate to the real status line.
const home = cfgDir();
const custom = process.env.SUPERMODE_STATUSLINE;
let cmd = null, args = [], shell = false;
if (custom && custom.trim() !== "") { cmd = custom; shell = true; }
else if (existsSync(resolve(home, "statusline-command.sh"))) { cmd = "bash"; args = [resolve(home, "statusline-command.sh")]; }
else if (existsSync(resolve(home, "statusline-command.js"))) { cmd = process.execPath; args = [resolve(home, "statusline-command.js")]; }
else if (existsSync(resolve(home, "statusline-command.mjs"))) { cmd = process.execPath; args = [resolve(home, "statusline-command.mjs")]; }

if (cmd) {
  const r = spawnSync(cmd, args, { input: raw, encoding: "utf-8", shell, windowsHide: true });
  if (r.status === 0 && typeof r.stdout === "string" && r.stdout.trim() !== "") {
    process.stdout.write(r.stdout);
    process.exit(0);
  }
}
// No status line of your own, or it failed: say the one thing supermode needs seen.
const model = (data.model && data.model.display_name) || "";
const dir = (data.workspace && data.workspace.current_dir) || (data.cwd || "");
const parts = ["supermode"];
if (pct !== null) parts.push(`ctx ${Math.round(pct)}%`);
if (model) parts.push(model);
if (dir) parts.push(basename(dir));
process.stdout.write(parts.join(" · ") + "\n");
