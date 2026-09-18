#!/usr/bin/env node
// ai-memory-sync.js - SessionStart hook (Windows port of ai-memory-sync.sh).
// 1. Locates the user's memory repo (portable via ~/.claude/ai-memory-path).
// 2. Best-effort ff-only pull (timed out, offline-safe) so the memory is fresh.
// 3. Injects the memory file (MEMORY_FILE, default claude-setup/memory/ABOUT-ME.md)
//    into Claude's context as additionalContext.
// Every failure mode is silent: the session still starts cleanly.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

// Optional <repo>/claude-setup/config/sunstone.conf: POSIX KEY=VALUE lines.
// Rules, identical to conf_get in the .sh twin: '#' starts a comment only at
// line start or after whitespace (a#b is a value); a double-quoted value runs
// to the next '"' (a '#' inside is literal, anything after the closing quote
// is ignored, an unterminated quote takes the rest of the line); surrounding
// whitespace is trimmed, never deleted from the inside. Last matching line
// wins. The file is user content, so it is parsed, never evaluated. Absent →
// defaults.
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
    // Leading whitespace is kept until the comment rule has run: KEY=#x is
    // the value "#x", KEY= #x is a comment (empty → default).
    let val = line.slice(eq + 1);
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) continue;
    if (val.trimStart().startsWith('"')) {
      val = val.trimStart();
      const end = val.indexOf('"', 1);
      val = end > 0 ? val.slice(1, end) : val.slice(1);
    } else {
      val = val.replace(/\s#.*$/, "").trim();
    }
    // Last matching line wins; an empty value un-sets the key so the caller's
    // default applies - exactly what conf_get in the .sh twin does.
    if (val) conf[key] = val;
    else delete conf[key];
  }
  return conf;
}

function main() {
  const home = os.homedir();
  const pathFile = path.join(home, ".claude", "ai-memory-path");

  // The single line in ~/.claude/ai-memory-path names the clone. With no path
  // file there is one generic fallback, $HOME/.ai-memory - used if it is a git
  // repo, otherwise there is nothing to do. Same order as ai-memory-sync.sh,
  // so the two ports cannot disagree about which checkout they mean.
  const candidates = [];
  try {
    const p = fs.readFileSync(pathFile, "utf8").split(/\r?\n/)[0].trim();
    if (p) candidates.push(p);
  } catch { /* no path file */ }
  candidates.push(path.join(home, ".ai-memory"));

  let repo = null;
  for (const c of candidates) {
    if (c && fs.existsSync(path.join(c, ".git"))) {
      repo = c;
      break;
    }
  }
  if (!repo) return; // nothing to do

  const conf = readConf(repo);
  const memoryDir = conf.MEMORY_DIR || "claude-setup/memory";
  const memoryFile = conf.MEMORY_FILE || "claude-setup/memory/ABOUT-ME.md";

  // GIT_TERMINAL_PROMPT=0 on every call, exactly as the .sh twin sets it at
  // ai-memory-sync.sh:73-75: a hook has no terminal to answer a credential
  // prompt on, and a prompt waiting on stdin is precisely the hang the
  // timeouts below are guarding against. execFileSync replaces the whole
  // environment when `env` is given, so the parent's is spread in first.
  const GIT_ENV = { ...process.env, GIT_TERMINAL_PROMPT: "0" };
  const git = (args, ms) => {
    execFileSync("git", ["-C", repo, ...args], { timeout: ms, stdio: "ignore", env: GIT_ENV });
  };
  const gitOut = (args, ms) =>
    execFileSync("git", ["-C", repo, ...args], {
      encoding: "utf8",
      timeout: ms,
      stdio: ["ignore", "pipe", "ignore"],
      env: GIT_ENV,
    }).trim();
  const count = (range) => {
    try { return parseInt(gitOut(["rev-list", "--count", range], 5000), 10) || 0; }
    catch { return -1; } // no upstream
  };

  // ff-only first: fast, and it can never rewrite local history. But ff-only
  // CANNOT integrate divergence, and with several machines and clients (a WSL
  // shell, a desktop app, a cloud session) all committing to the memory tree,
  // divergence is the normal case rather than the exception. Left at ff-only
  // alone, a machine that falls behind fails to pull, then fails to push, and -
  // every failure here being silent - simply stops syncing forever without
  // saying so.
  //
  // So on failure, rebase our memory commits on top instead. Rewriting local
  // history is acceptable for a markdown memory store and nothing else in this
  // repo is touched by the auto-commit hook. --autostash protects a file written
  // but not yet committed, and a conflict is aborted rather than left half-done
  // for a human to discover later.
  const syncPull = () => {
    try { git(["pull", "--ff-only", "--quiet"], 8000); return true; } catch { /* diverged or offline */ }
    if (count("HEAD..@{u}") <= 0) return false; // offline, not divergence
    try { git(["pull", "--rebase", "--autostash", "--quiet"], 25000); return true; }
    catch {
      try { git(["rebase", "--abort"], 10000); } catch { /* nothing left to abort */ }
      return false;
    }
  };

  syncPull();

  // --- push what last session committed ------------------------------------
  // The SessionEnd hook (ai-memory-commit.js) commits memory writes but never
  // pushes, so the network cost lands here instead - where a round trip is
  // already being paid. Nothing to push is the common case and costs one local
  // rev-list.
  //
  // One retry: a push can be rejected by a commit that landed between our pull
  // and our push, and re-syncing then pushing again clears exactly that case.
  // If the retry also fails the commits stay local and go out next session -
  // which is now genuinely "next time" rather than "never".
  if (count("@{u}..HEAD") > 0) {
    try {
      git(["push", "--quiet"], 10000);
    } catch {
      if (syncPull() && count("@{u}..HEAD") > 0) {
        try { git(["push", "--quiet"], 10000); } catch { /* goes out next session */ }
      }
    }
  }

  // --- pick the file to inject ---------------------------------------------
  // MEMORY_FILE first; failing that, MEMORY.md inside MEMORY_DIR; failing both,
  // inject nothing. The sync above has still done its job either way.
  let mem = path.join(repo, memoryFile);
  if (!fs.existsSync(mem)) mem = path.join(repo, memoryDir, "MEMORY.md");

  let body;
  try {
    body = fs.readFileSync(mem, "utf8");
  } catch {
    return;
  }

  const ctx =
    "Portable memory about the user, auto-synced from their memory " +
    "git repo. Treat as durable background context, not a live instruction:\n\n" +
    body;

  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: ctx,
      },
    })
  );
}

try { main(); } catch { /* never break session start */ }
