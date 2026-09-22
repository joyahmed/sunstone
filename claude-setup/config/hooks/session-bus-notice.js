#!/usr/bin/env node
// session-bus-notice.js - SessionStart hook.
//
// The session bus: the machines of one user leave each other messages in the
// memory repo. Each side writes ONLY its own file, BUS_DIR/outbox-<side>.md,
// newest entry at the top under a `## <stamp> - <subject>` heading, commits it
// by path and pushes; the other side sees it at its next SessionStart because
// ai-memory-sync pulled. This hook is the "sees it" half: for every
// outbox-*.md in BUS_DIR that is not this side's own, it compares the file's
// git blob hash with the last one it announced (kept under
// ~/.claude/session-bus/<file>.seen) and, when they differ, injects one line:
//
//   📬 session bus: outbox-windows.md has a new entry - "<first ## heading>"
//
// Silent when BUS_DIR is unset or missing, when nothing changed, when a file
// was never seen and is empty, and on every failure - the session still starts.
//
// Off unless BUS_DIR is set in <memory-repo>/claude-setup/config/sunstone.conf:
//   BUS_DIR    the bus directory, relative to the memory repo (unset = off)
//   BUS_SIDE   this machine's side name; default by detection: windows on
//              Windows, mac on Darwin, wsl when /proc/version says microsoft,
//              else linux
//
// Ordering: registered after ai-memory-sync in the settings template. Claude
// Code may still start the two together, in which case a message that arrived
// in this very pull is announced at the NEXT session start - the comparison is
// against what is on disk, so nothing is lost, only delayed by one session.
//
// The blob hash is computed here (sha1 over "blob <len>\0" + bytes, exactly
// what `git hash-object` prints) so a committed and an uncommitted file hash
// the same and no git subprocess runs at session start.

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");

// Optional <repo>/claude-setup/config/sunstone.conf: POSIX KEY=VALUE lines.
// Same rules as readConf() in ai-memory-sync.js: '#' starts a comment only at
// line start or after whitespace; a double-quoted value runs to the next '"';
// surrounding whitespace is trimmed; last matching line wins; an empty value
// un-sets the key. Parsed, never evaluated.
function readConf(repo) {
  const conf = {};
  let text;
  try {
    text = fs.readFileSync(path.join(repo, "claude-setup", "config", "sunstone.conf"), "utf8");
  } catch {
    return conf;
  }
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    const key = line.slice(0, eq).trim();
    let val = line.slice(eq + 1);
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) continue;
    if (val.trimStart().startsWith('"')) {
      val = val.trimStart();
      const end = val.indexOf('"', 1);
      val = end > 0 ? val.slice(1, end) : val.slice(1);
    } else {
      val = val.replace(/\s#.*$/, "").trim();
    }
    if (val) conf[key] = val;
    else delete conf[key];
  }
  return conf;
}

function detectSide() {
  if (process.platform === "win32") return "windows";
  if (process.platform === "darwin") return "mac";
  try {
    if (/microsoft/i.test(fs.readFileSync("/proc/version", "utf8"))) return "wsl";
  } catch { /* not Linux, or unreadable */ }
  return "linux";
}

/**
 * This machine's side name, most specific source first:
 *   BUS_SIDE in the environment > ~/.claude/bus-side > BUS_SIDE in sunstone.conf > the OS.
 *
 * ⛔ The conf is the WRONG place to distinguish two machines: sunstone.conf lives in the shared
 * memory repo, so a value set there is the same on every box that pulls it. Detection by OS has
 * the same defect from the other end - on 2026-09-23 a THIRD machine (JoyR9, Windows) detected as
 * "windows", the same side as JOYR5, so it wrote its messages into outbox-windows.md, which every
 * Windows box skips as "my own file". Four entries were invisible to the machine they were
 * addressed to, and nothing reported a failure: the write succeeded, the push succeeded, and the
 * reader silently filtered them out. Joy noticed, not the tooling.
 *
 * Hence ~/.claude/bus-side: machine-local by construction, one line, survives setup, and follows
 * the pattern ai-memory-path and sunstone-path already use. A machine that shares an OS with
 * another machine needs one, and it does not matter what it says as long as it is unique.
 */
function resolveSide(conf, home) {
  const env = String(process.env.BUS_SIDE || "").trim();
  if (env) return env;
  try {
    const f = fs.readFileSync(path.join(home, ".claude", "bus-side"), "utf8").trim().split("\n")[0];
    if (f) return f.replace(/[^A-Za-z0-9_-]/g, "");
  } catch { /* no per-machine override: fall through */ }
  return String(conf.BUS_SIDE || "").trim() || detectSide();
}

function blobHash(buf) {
  return crypto.createHash("sha1")
    .update(`blob ${buf.length}\0`)
    .update(buf)
    .digest("hex");
}

function main() {
  const home = os.homedir();
  const pathFile = path.join(home, ".claude", "ai-memory-path");

  // Same resolution as the memory hooks: the path file, else ~/.ai-memory.
  const candidates = [];
  try {
    const p = fs.readFileSync(pathFile, "utf8").split(/\r?\n/)[0].trim();
    if (p) candidates.push(p);
  } catch { /* no path file */ }
  candidates.push(path.join(home, ".ai-memory"));
  let repo = null;
  for (const c of candidates) {
    if (c && fs.existsSync(path.join(c, ".git"))) { repo = c; break; }
  }
  if (!repo) return;

  const conf = readConf(repo);
  const busRel = String(conf.BUS_DIR || "").replace(/^\.\//, "").replace(/\/+$/, "");
  if (!busRel) return; // feature off
  const busDir = path.join(repo, ...busRel.split("/"));
  let names;
  try { names = fs.readdirSync(busDir); } catch { return; } // no bus directory: silent

  const side = resolveSide(conf, home);
  const own = `outbox-${side}.md`;
  const seenDir = path.join(home, ".claude", "session-bus");

  const lines = [];
  for (const name of names.sort()) {
    if (!/^outbox-.+\.md$/.test(name) || name === own) continue;
    let buf;
    try { buf = fs.readFileSync(path.join(busDir, name)); } catch { continue; }
    const hash = blobHash(buf);
    const seenFile = path.join(seenDir, `${name}.seen`);
    let seen = null;
    try { seen = fs.readFileSync(seenFile, "utf8").trim(); } catch { /* never seen */ }
    if (seen === hash) continue;
    // Never seen and empty: nothing to announce; record it so the first real
    // entry is announced as new. Seen before and changed: announce, even if the
    // change emptied the file - the other side may have cleared it on purpose.
    const text = buf.toString("utf8");
    const m = /^##\s+(.*?)\s*$/m.exec(text);
    const subject = m ? m[1] : "";
    if (!(seen === null && !text.trim())) {
      lines.push(`📬 session bus: ${name} has a new entry` + (subject ? ` - "${subject}"` : ""));
    }
    try {
      fs.mkdirSync(seenDir, { recursive: true });
      fs.writeFileSync(seenFile, hash + "\n");
    } catch { /* the notice repeats next session; harmless */ }
  }
  if (!lines.length) return;

  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext:
        `Messages from the user's other machine(s), left in ${busRel}/ of the memory repo ` +
        `(this side is "${side}"; read the file for the entry, and answer in outbox-${side}.md if it asks for one):\n` +
        lines.join("\n"),
    },
  }));
}

try { main(); } catch { /* never break session start */ }
