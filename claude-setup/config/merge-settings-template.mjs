#!/usr/bin/env node
// merge-settings-template.mjs - idempotently merge a settings.json *template*
// into a Claude Code settings.json. Node port of merge-settings-template.py;
// the two apply exactly the same rules.
//
// Usage: node merge-settings-template.mjs <settings.json> <template.json>
//
// - "hooks": for each event in the template, append every entry whose command
//   is not already registered under that event. "Already registered" means an
//   entry there runs the same command string, or the same script judged by the
//   script file's basename - `node ~/.claude/hooks/x.js` and
//   `node C:/dotfiles/hooks/x.js` count as one hook (the rule
//   merge-ai-memory-hook.py / merge-claude-settings.mjs use). A template
//   group's "matcher" (and any other keys on the group) is kept on the group
//   that gets appended.
// - "statusLine": copied only if the target has none.
// - "env": each variable copied only if the target does not define it.
// - Any other top-level key whose template value is a scalar (true/false, a
//   number, a string) - autoCompactEnabled, say - is copied only if the target
//   does not have that key. Objects and arrays other than the three above are
//   not copied. "permissions" is never touched; "$comment" is never copied.
// - "permissions" is never read or written. No other template key is copied.
// - Commands are written exactly as the template spells them ('~' included).
// - The file (and parent dirs) is created if missing. Writes are atomic.
// Prints one line per change, or "no change". Exit 0 on success (including a
// no-op); non-zero only when a file cannot be parsed or written.

import fs from "node:fs";
import path from "node:path";

const [settingsPath, tplPath] = process.argv.slice(2);
if (!settingsPath || !tplPath || process.argv.length !== 4) {
  console.error("usage: merge-settings-template.mjs <settings.json> <template.json>");
  process.exit(2);
}

// Script paths inside a hook command: bare (`bash ~/.claude/hooks/x.sh`,
// `node C:/u/x.js`) or double/single-quoted (`node "C:/my dots/x.js"`).
const SCRIPT_RE = /"([^"]*?\.(?:sh|mjs|js|py))"|'([^']*?\.(?:sh|mjs|js|py))'|([\w./~\\:-]+\.(?:sh|mjs|js|py))\b/g;
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

const scripts = (cmd) => {
  const out = new Set();
  for (const m of String(cmd || "").matchAll(SCRIPT_RE)) {
    const p = m[1] ?? m[2] ?? m[3];
    out.add(p.replace(/\\/g, "/").split("/").pop());
  }
  return out;
};

const registered = (arr, command) => {
  const want = scripts(command);
  for (const group of arr) {
    if (!isObj(group)) continue;
    for (const h of Array.isArray(group.hooks) ? group.hooks : []) {
      if (!isObj(h)) continue;
      const have = h.command;
      if (have === command) return true;
      if (want.size) for (const s of scripts(have)) if (want.has(s)) return true;
    }
  }
  return false;
};

const load = (p, required) => {
  if (!fs.existsSync(p)) {
    if (required) {
      console.error(`  ! template not found: ${p}`);
      process.exit(1);
    }
    return {};
  }
  let data;
  try {
    data = JSON.parse(fs.readFileSync(p, "utf8")) || {};
  } catch (e) {
    console.error(`  ! could not parse ${p} (${e.message}); leaving it untouched`);
    process.exit(1);
  }
  if (!isObj(data)) {
    console.error(`  ! ${p} is not a JSON object; leaving it untouched`);
    process.exit(1);
  }
  return data;
};

const data = load(settingsPath, false);
const tpl = load(tplPath, true);
const changes = [];

// hooks
if (isObj(tpl.hooks)) {
  const hooks = isObj(data.hooks) ? data.hooks : {};
  for (const [event, groups] of Object.entries(tpl.hooks)) {
    if (!Array.isArray(groups)) continue;
    const arr = Array.isArray(hooks[event]) ? hooks[event] : [];
    for (const group of groups) {
      if (!isObj(group)) continue;
      const missing = [];
      for (const h of Array.isArray(group.hooks) ? group.hooks : []) {
        if (!isObj(h) || !h.command) continue;
        if (!registered(arr, h.command) && !registered([{ hooks: missing }], h.command)) missing.push(h);
      }
      if (!missing.length) continue;
      const { hooks: _drop, ...rest } = group;
      arr.push({ ...rest, hooks: missing });
      for (const h of missing) {
        changes.push(`registered ${event} hook: ${h.command.slice(0, 60)}${h.command.length > 60 ? "..." : ""}`);
      }
    }
    if (arr.length) hooks[event] = arr;
  }
  if (Object.keys(hooks).length) data.hooks = hooks;
}

// statusLine
if ("statusLine" in tpl && !("statusLine" in data)) {
  data.statusLine = tpl.statusLine;
  changes.push("set statusLine");
}

// env
if (isObj(tpl.env)) {
  const env = isObj(data.env) ? data.env : {};
  for (const [k, v] of Object.entries(tpl.env)) {
    if (!(k in env)) {
      env[k] = v;
      changes.push(`set env.${k}`);
    }
  }
  if (Object.keys(env).length) data.env = env;
}

// Scalar preferences: copied only when the target does not have the key, so a
// value the user set by hand on this machine is never overridden.
for (const [k, v] of Object.entries(tpl)) {
  if (["hooks", "statusLine", "env", "permissions", "$comment"].includes(k)) continue;
  if ((typeof v === "boolean" || typeof v === "number" || typeof v === "string") && !(k in data)) {
    data[k] = v;
    changes.push(`set ${k}`);
  }
}

if (!changes.length) {
  console.log("  no change");
  process.exit(0);
}
for (const c of changes) console.log("  " + c);
fs.mkdirSync(path.dirname(settingsPath) || ".", { recursive: true });
const tmp = settingsPath + ".tmp";
fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + "\n");
fs.renameSync(tmp, settingsPath);
