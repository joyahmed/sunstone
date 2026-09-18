#!/usr/bin/env node
// merge-claude-settings.mjs — idempotently merge the Windows statusline + memory
// hook into ~/.claude/settings.json without clobbering existing keys.
// Usage: node merge-claude-settings.mjs <settingsPath> <statuslineJs> <hookJs> [commitJs]
// Windows counterpart of the Linux merge-ai-memory-hook.py.

import fs from "node:fs";

const [settingsPath, statuslineJs, hookJs, commitJs] = process.argv.slice(2);
if (!settingsPath || !statuslineJs || !hookJs) {
  console.error("usage: merge-claude-settings.mjs <settingsPath> <statuslineJs> <hookJs> [commitJs]");
  process.exit(2);
}

// node accepts forward slashes on Windows; normalize so JSON stays clean. The
// path is always double-quoted so a user profile with a space in it works.
const fwd = (p) => p.replace(/\\/g, "/");
const cmd = (p) => `node "${fwd(p)}"`;
const statuslineCmd = cmd(statuslineJs);
const hookCmd = cmd(hookJs);
const commitCmd = commitJs ? cmd(commitJs) : null;

let settings = {};
if (fs.existsSync(settingsPath)) {
  try {
    settings = JSON.parse(fs.readFileSync(settingsPath, "utf8")) || {};
  } catch (e) {
    console.error(`existing settings.json is not valid JSON, leaving untouched: ${e.message}`);
    process.exit(1);
  }
}

// statusLine — set/replace ours
settings.statusLine = { type: "command", command: statuslineCmd };

// Append a hook command under an event only if no entry there already runs the
// same command or the same script. "Same script" is judged by basename, so
// `node ~/.claude/hooks/x.js`, `node C:/dotfiles/hooks/x.js` and
// `node "C:/my dots/hooks/x.js"` count as one hook — the same rule
// merge-ai-memory-hook.py and merge-settings-template.mjs use.
const SCRIPT_RE = /"([^"]*?\.(?:sh|mjs|js|py))"|'([^']*?\.(?:sh|mjs|js|py))'|([\w./~\\:-]+\.(?:sh|mjs|js|py))\b/g;
const scripts = (c) => {
  const out = new Set();
  for (const m of String(c || "").matchAll(SCRIPT_RE)) out.add(fwd(m[1] ?? m[2] ?? m[3]).split("/").pop());
  return out;
};
settings.hooks = settings.hooks || {};
const register = (event, command, extra) => {
  const arr = Array.isArray(settings.hooks[event]) ? settings.hooks[event] : [];
  const want = scripts(command);
  const already = arr.some((group) =>
    Array.isArray(group?.hooks) && group.hooks.some((h) => {
      if (h?.command === command) return true;
      for (const s of scripts(h?.command)) if (want.has(s)) return true;
      return false;
    })
  );
  if (!already) arr.push({ hooks: [{ type: "command", command, ...(extra || {}) }] });
  settings.hooks[event] = arr;
  return !already;
};

register("SessionStart", hookCmd);

// SessionEnd: commit whatever the session wrote under the memory tree
// (MEMORY_DIR, default claude-setup/memory). Deliberately a separate hook from
// the SessionStart one — this half never touches the network, so ending a
// session stays instant. The commit is pushed by ai-memory-sync.js on the next
// start, where a round trip is already being paid and the user is present if a
// rebase conflicts.
if (commitCmd) register("SessionEnd", commitCmd, { async: true });

// Any other hook entries already in settings (Notification, Stop, ...) are left
// untouched: only the two memory hooks and the statusLine are managed here.

fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
console.log(
  `merged statusLine + SessionStart${commitCmd ? " + SessionEnd" : ""} memory hooks into ${settingsPath}`
);
