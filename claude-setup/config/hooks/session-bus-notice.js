#!/usr/bin/env node
// session-bus-notice.js - SessionStart hook. It does three things, all of them
// about ONE question: how do the user's sessions address each other.
//
//   1. IDENTITY (always). Injects this session's own address, `<box>/<repo>`,
//      and the rule that every cross-session message opens with `FROM <box>/<repo>`.
//   2. BUS NOTICES (when BUS_DIR is set). One line per other side's outbox that
//      changed since the last announcement.
//   3. REGISTRY (when BUS_DIR is set). Records this session in
//      BUS_DIR/sessions-<side>.md so the OTHER boxes can see it exists.
//
// ⛔ WHY ALL THREE LIVE IN THIS ONE HOOK, rather than in a new one beside it.
// A session listing is the only surface a peer reads before choosing a
// recipient, and it titles each row with the session's display name - derived,
// when nothing sets it, from the session's first task. A session whose first
// task was "contact the other box" gets listed under a title naming that other
// box, i.e. the listing asserts the opposite of the truth; messages went to the
// wrong box for a whole day on exactly that. The launcher (bin/supermode) fixes
// the name at launch; this hook tells the session the same address so its own
// `FROM` line is not guesswork, and writes the registry so a box that appears
// in NO listing is still discoverable. That is one concern, so it is one hook:
// every SessionStart hook is a process spawned before the first prompt, and the
// framework does not add a fourth of them to say a second sentence.
//
// ⛔ THIS HOOK RUNS NO SUBPROCESS AND NEVER COMMITS OR PUSHES. It writes one
// file under BUS_DIR and stops; the SessionEnd memory hook already commits
// BUS_DIR by path. A hook that committed would publish whatever else happened
// to be half-written in that tree.
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
 * the same defect from the other end - a second Windows machine detected as "windows", the same
 * side as the first, so it wrote its messages into outbox-windows.md, which every Windows box
 * skips as "my own file". Its entries were invisible to the machine they were addressed to, and
 * nothing reported a failure: the write succeeded, the push succeeded, and the reader silently
 * filtered them out. A human noticed, not the tooling.
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

// --- this session's own address: <box>/<repo> --------------------------------

/**
 * The first NON-EMPTY line of a file, CR and surrounding whitespace stripped, or "".
 *
 * ⛔ The first line, never the file joined. A name file that grew a second line -
 * a note, a trailing value, an editor's stray line - welded into one word yields
 * a name no peer can retype, and that exact defect has already had to be fixed
 * once in the status line.
 */
function firstLine(file) {
  try {
    for (const raw of fs.readFileSync(file, "utf8").split(/\r?\n/).slice(0, 20)) {
      const t = raw.trim();
      if (t) return t;
    }
  } catch { /* absent or unreadable: no name from here */ }
  return "";
}

// Keep names to what a person can retype out of a listing. Also turns "/" and a
// stray newline into "", which the address assembly then drops.
const clean = (s) => String(s == null ? "" : s).replace(/[^A-Za-z0-9._-]/g, "");

/**
 * This machine's name: the box name file, else the bus side file, else the short
 * hostname. All three are machine-local by construction.
 *
 * ⛔ It is per-BOX, not per-session. One box runs several sessions at once and
 * every one of them reads the same file, so the box name ALONE cannot route a
 * message - which is why the address below pairs it with the repo.
 */
function boxName(home) {
  const raw = String(process.env.CLAUDE_CONFIG_DIR || "").trim();
  const cfg = raw ? raw.replace(/^~/, home) : path.join(home, ".claude");
  let box = clean(firstLine(path.join(cfg, "hooks", "claude-name.txt")));
  if (!box) box = clean(firstLine(path.join(cfg, "bus-side")));
  if (!box) { try { box = clean(os.hostname().split(".")[0]); } catch { /* no hostname */ } }
  return box;
}

/**
 * The repo this session works in: the basename of the nearest work tree at or
 * above cwd, else the basename of cwd itself when the launch is outside a repo.
 * A directory walk rather than `git rev-parse` - this hook spawns no subprocess.
 */
function repoName(cwd) {
  let dir = cwd;
  for (let i = 0; i < 40; i++) {
    try { if (fs.existsSync(path.join(dir, ".git"))) return clean(path.basename(dir)); } catch { /* keep walking */ }
    const up = path.dirname(dir);
    if (!up || up === dir) break;
    dir = up;
  }
  return clean(path.basename(cwd));
}

// Either part may be empty; the address drops it rather than shipping an empty
// segment, so an address never begins or ends with "/".
const addressOf = (box, repo) => [box, repo].filter(Boolean).join("/");

/**
 * SessionStart payload, or {}. ⛔ Never read a terminal: fd 0 on a tty blocks
 * forever, and a SessionStart hook that blocks hangs every session on the box.
 */
function readPayload() {
  try {
    if (process.stdin.isTTY) return {};
    return JSON.parse(fs.readFileSync(0, "utf8") || "{}") || {};
  } catch { return {}; }
}

// --- the registry: which sessions exist, readable from every box -------------
//
// ⛔ WHY IT EXISTS. Naming a session only helps a session that APPEARS in a
// listing at all, and one box appeared in no peer listing for a whole day while
// it was demonstrably working. A file in the bus is the one route that reaches a
// box nobody can see: it arrives by git, at the next session start.
//
// ONE FILE PER SIDE, `sessions-<side>.md`, exactly like the outboxes. A single
// shared file would be rewritten near its top by every box at every session
// start, which is a merge conflict on every pull - the memory sync would then
// report a broken pull on every box forever. Per-side files never touch.
//
// A row means "this session started", not "this session is alive": there is no
// SessionEnd half to this, deliberately, because a hook that deleted rows could
// delete another box's. Liveness comes from the pruning rule instead.
const REG_CAP = 100;        // hard ceiling, so a row with an unreadable date cannot pile up
const REG_DAYS_DEFAULT = 3; // rows older than this are dropped on the next write

const regFile = (busDir, side) => path.join(busDir, `sessions-${side}.md`);

// Table rows of the file we wrote before. A line that is not 5 cells is dropped:
// the file is machine-written, and keeping unparseable rows is how a ceiling gets
// filled with junk nobody can prune by date.
function parseRows(text) {
  const rows = [];
  for (const raw of String(text || "").split(/\r?\n/)) {
    const line = raw.trim();
    if (!line.startsWith("|")) continue;
    const cells = line.replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => c.trim());
    if (cells.length !== 5) continue;
    if (/^-+$/.test(cells[0]) || /^started/i.test(cells[0])) continue; // header, separator
    if (!cells[3]) continue;                                           // no session id: not a row
    rows.push({ at: cells[0], box: cells[1], repo: cells[2], sid: cells[3], name: cells[4] });
  }
  return rows;
}

const stamp = (s) => { const t = Date.parse(s); return Number.isFinite(t) ? t : 0; };

function renderRegistry(side, days, rows) {
  return [
    `<!-- Sessions started on the "${side}" side of the session bus. Written by`,
    "     session-bus-notice.js at every SessionStart: one row per session id -",
    "     an existing id is UPDATED IN PLACE, keeping its original start time, so",
    `     running twice changes nothing. Rows older than ${days} day(s) are dropped on`,
    `     the next write and at most ${REG_CAP} are kept, which is the whole pruning rule.`,
    "     One file per side, like the outboxes, because two boxes rewriting one",
    "     shared file conflict on every pull. This file is committed by the",
    "     SessionEnd memory hook, never by the SessionStart hook that writes it. -->",
    "",
    "| started (UTC) | box | repo | session id | display name |",
    "| --- | --- | --- | --- | --- |",
    ...rows.map((r) => `| ${r.at} | ${r.box || "-"} | ${r.repo || "-"} | ${r.sid} | ${r.name || "-"} |`),
    "",
  ].join("\n");
}

/**
 * Record `row` in BUS_DIR/sessions-<side>.md. Idempotent per session id, and a
 * no-op write when the rendered file would be identical - so a re-run leaves the
 * tree clean rather than dirtying it again. Returns nothing and throws nothing
 * worth acting on: a registry that cannot be written must not cost a session.
 */
function writeRegistry(busDir, side, row, days) {
  const file = regFile(busDir, side);
  let before = "";
  try { before = fs.readFileSync(file, "utf8"); } catch { /* absent: this creates it */ }
  const rows = parseRows(before);
  const prior = rows.find((r) => r.sid === row.sid);
  if (prior && stamp(prior.at)) row = { ...row, at: prior.at }; // keep the real start time
  const cutoff = Date.now() - days * 86400000;
  const kept = rows
    .filter((r) => r.sid !== row.sid)
    .filter((r) => stamp(r.at) >= cutoff);
  kept.push(row);
  kept.sort((a, b) => stamp(b.at) - stamp(a.at));
  const after = renderRegistry(side, days, kept.slice(0, REG_CAP));
  if (after === before) return;
  // tmp + rename so a reader never sees a half-written table. ⚠️ Two sessions
  // starting on the SAME box in the same instant can still lose one row (read,
  // modify, write); the next start of either re-adds it, and cross-box safety is
  // what the per-side file buys.
  const tmp = `${file}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(tmp, after);
    fs.renameSync(tmp, file);
  } catch {
    try { fs.unlinkSync(tmp); } catch { /* nothing to clean */ }
  }
}

/**
 * One SessionStart block, or nothing at all.
 *
 * ⛔ Nothing here scolds a session about its identity. The address line is a
 * fact, printed the same way every time; the only warning shape in this hook is
 * the "cannot verify" note, which fires when a DECLARED memory repo path cannot
 * be opened - a real defect, not a healthy session being told about itself.
 */
function emit(head, notes, bus) {
  const blocks = [head.join("\n"), bus, notes.join("\n")].filter((b) => b && b.trim());
  if (!blocks.length) return;
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: blocks.join("\n\n") },
  }));
}

function main() {
  const home = os.homedir();
  const payload = readPayload();
  const sid = clean(payload.session_id).slice(0, 64);
  const cwd = typeof payload.cwd === "string" && payload.cwd ? payload.cwd : process.cwd();
  const box = boxName(home);
  const addr = addressOf(box, repoName(cwd));
  // The display name the harness gave this session, IF it hands it over at all.
  // ⚠️ unverified: no SessionStart payload field has been seen carrying it, and
  // nothing on disk records it either, so this is usually "". The registry column
  // then says "-" rather than repeating the address and pretending it was
  // observed - the row's box and repo are the INTENDED address, which is the
  // identity that survives whatever a listing does to a title.
  // ⛔ The status line is not a second source for it: its payload carries only the
  // model's display name and the session id, so the address it paints is built
  // from the same box-name file and repo as this line. The two surfaces agree by
  // construction, not by sharing a value - do not wire them together.
  // ⚠️ Not clean(): a display name legitimately contains the "/" of <box>/<repo>,
  // and stripping it here would make an agreeing name look like a mismatch. Only
  // what would break the table row - a pipe, a newline - is removed.
  const shown = String(payload.session_name || payload.display_name || process.env.CLAUDE_SESSION_NAME || "")
    .replace(/[|\r\n]+/g, " ").trim().slice(0, 80);

  const head = [];
  const notes = [];
  if (addr) {
    head.push(
      `This session's address is ${addr} — box/repo. Open every message to another session with ` +
      `\`FROM ${addr}\`: a session's title is not an address, and one box runs several sessions at once.`,
    );
  }
  // If the name IS visible and disagrees with the address, that disagreement is
  // the finding: it means a listing shows this session under something a sender
  // cannot route to. Printed only then - never when the two agree, and never when
  // the name could not be seen at all.
  if (shown && addr && shown !== addr) {
    notes.push(
      `ℹ️ this session is listed as "${shown}" but its address is ${addr}; peers routing by the ` +
      `listing will be addressing the wrong thing, so state the address in the message body.`,
    );
  }

  const pathFile = path.join(home, ".claude", "ai-memory-path");

  // Same resolution as the memory hooks: the path file, else ~/.ai-memory.
  const candidates = [];
  let declared = "";
  try {
    const p = fs.readFileSync(pathFile, "utf8").split(/\r?\n/)[0].trim();
    if (p) { declared = p; candidates.push(p); }
  } catch { /* no path file */ }
  candidates.push(path.join(home, ".ai-memory"));
  let repo = null;
  for (const c of candidates) {
    if (c && fs.existsSync(path.join(c, ".git"))) { repo = c; break; }
  }
  if (!repo) {
    // ⚠️ "Cannot verify", not "missing". The path file can name a path this
    // process cannot open at all - a path belonging to the other OS on the same
    // physical box is the case that happens - and a session that says nothing
    // there is a box that silently appears in no listing, which is the failure
    // this registry exists to end. Said once, short, only when a path was
    // DECLARED: no path file at all means the memory layer is simply not set up.
    if (declared) {
      notes.push(
        `ℹ️ cannot verify the session registry: the memory repo named in ~/.claude/ai-memory-path ` +
        `("${declared}") is not readable from this process, so this session could not record itself ` +
        `for the other boxes. Nothing else is affected.`,
      );
    }
    return emit(head, notes);
  }

  const conf = readConf(repo);
  const busRel = String(conf.BUS_DIR || "").replace(/^\.\//, "").replace(/\/+$/, "");
  if (!busRel) return emit(head, notes); // bus off: identity still stands
  const busDir = path.join(repo, ...busRel.split("/"));
  const side = resolveSide(conf, home);

  // The registry first: it must happen even if there is nothing to announce.
  let days = parseInt(String(conf.SESSION_REGISTRY_DAYS || ""), 10);
  if (!Number.isFinite(days) || days < 1) days = REG_DAYS_DEFAULT;
  if (sid) {
    try {
      if (fs.existsSync(busDir)) {
        writeRegistry(busDir, side, {
          at: new Date().toISOString().replace(/\.\d+Z$/, "Z"),
          box, repo: repoName(cwd), sid, name: shown,
        }, days);
        head.push(
          `Sessions on the user's other boxes register themselves in ${busRel}/sessions-*.md of the ` +
          `memory repo; this one is now in sessions-${side}.md.`,
        );
      }
    } catch { /* a registry is never worth a session */ }
  }

  let names;
  try { names = fs.readdirSync(busDir); } catch { return emit(head, notes); } // no bus directory: silent

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
  const bus = lines.length
    ? `Messages from the user's other machine(s), left in ${busRel}/ of the memory repo ` +
      `(this side is "${side}"; read the file for the entry, and answer in outbox-${side}.md if it asks for one):\n` +
      lines.join("\n")
    : "";
  return emit(head, notes, bus);
}

try { main(); } catch { /* never break session start */ }
