#!/usr/bin/env node
// memory-doctor-notice.js - SessionStart hook (Node port of
// memory-doctor-notice.sh; setup.ps1 installs and registers this one, since
// Windows has no bash or python3 for the shell version).
//
// Nobody runs memory-doctor by hand. A maintenance chore that depends on a
// person remembering it is a chore that never happens - so the system raises
// it instead. Runs the doctor in --brief mode and injects its few lines as
// context. Deliberately quiet:
//   - nothing when the stores are drained and the wiring is sound, so this
//     goes silent for good once the work is done rather than becoming
//     wallpaper;
//   - at most one notice per THROTTLE_HOURS;
//   - every failure mode is silent - no framework checkout, no doctor: the
//     session starts clean, just without the notice.
//
// Disable with:  touch ~/.claude/.memory-doctor-off
//
// The framework checkout is found the way the .sh does it: ~/.claude/
// sunstone-path first (setup writes it), then this file's own location with
// symlinks resolved (a checkout running the hook in place), then the memory
// repo from ai-memory-path (for the layout where the memory repo IS a
// framework checkout) and a sibling directory named sunstone beside it. Every
// candidate is verified by the presence of memory-doctor.js.

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const THROTTLE_HOURS = 20;
const DOCTOR_REL = path.join("claude-setup", "scripts", "memory-doctor.js");

const firstLine = (file) => {
  try { return fs.readFileSync(file, "utf8").split(/\r?\n/)[0].trim(); } catch { return ""; }
};

function main() {
  const home = os.homedir();
  const claudeDir = path.join(home, ".claude");
  if (fs.existsSync(path.join(claudeDir, ".memory-doctor-off"))) return;

  // --- throttle -----------------------------------------------------------
  const stamp = path.join(claudeDir, ".memory-doctor-last");
  const last = parseInt(firstLine(stamp), 10);
  const now = Math.floor(Date.now() / 1000);
  if (Number.isFinite(last) && now - last < THROTTLE_HOURS * 3600) return;

  // --- locate the framework checkout --------------------------------------
  const cands = [];
  const recorded = firstLine(path.join(claudeDir, "sunstone-path"));
  if (recorded) cands.push(recorded);
  try {
    cands.push(path.resolve(path.dirname(fs.realpathSync(__filename)), "..", "..", ".."));
  } catch { /* unresolvable */ }
  let repo = firstLine(path.join(claudeDir, "ai-memory-path"));
  if (!repo && fs.existsSync(path.join(home, ".ai-memory", ".git"))) repo = path.join(home, ".ai-memory");
  if (repo) cands.push(repo, path.join(path.dirname(repo), "sunstone"));
  const framework = cands.find((c) => c && fs.existsSync(path.join(c, DOCTOR_REL)));
  if (!framework) return;

  // --- ask the doctor for a few lines ---------------------------------------
  let out = "";
  try {
    out = execFileSync(process.execPath, [path.join(framework, DOCTOR_REL), "--brief"], {
      encoding: "utf8", timeout: 60000, stdio: ["ignore", "pipe", "ignore"], windowsHide: true,
    });
  } catch (e) {
    // Exit 1 means an ERROR was found - the notice is still what it printed.
    out = e && typeof e.stdout === "string" ? e.stdout : "";
  }
  out = out.trim();
  if (!out) return; // drained and healthy - say nothing, record nothing

  try { fs.writeFileSync(stamp, `${now}\n`); } catch { /* the notice repeats; harmless */ }

  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext:
        "Memory-system status (from memory-doctor, injected automatically so " +
        "nobody has to remember to run it):\n\n" + out,
    },
  }));
}

try { main(); } catch { /* never break session start */ }
