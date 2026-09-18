#!/usr/bin/env node
// ai-memory-commit.js — SessionEnd hook (Windows port of ai-memory-commit.sh).
// The write half of memory sync.
//
// Commits anything written under the memory tree (MEMORY_DIR, default
// claude-setup/memory/) during the session.
// It does NOT push: no network call happens here, so ending a session is never
// slower for it. The commit goes out on the next SessionStart, where
// ai-memory-sync.js already talks to the remote — one round trip, in a session
// the user started, so a rebase conflict surfaces while they are present.
//
// Scope is deliberately narrow: this stages ONE directory by path and nothing
// else. An auto-commit is fine for a memory store and unacceptable for source,
// and the memory repo may hold both.
//
// The commit runs with --no-verify, on purpose. This hook stages the memory
// tree by path and commits only that pathspec, so a mixed-staging guard (the
// framework's pre-commit, which refuses a commit that mixes memory and source)
// is satisfied by construction and there is nothing left for it to check. The
// consequence is that repo-local hooks in the memory repo (pre-commit,
// commit-msg, prepare-commit-msg — husky, lint-staged, and the like) are
// bypassed for THIS ONE COMMIT only; every commit a person makes in that repo
// still runs them.
//
// Every failure mode is silent. A memory file that fails to commit is still on
// disk and will be picked up next time.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

// Optional <repo>/claude-setup/config/super-ai.conf: POSIX KEY=VALUE lines.
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
    text = fs.readFileSync(path.join(repo, "claude-setup", "config", "super-ai.conf"), "utf8");
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
    // default applies — exactly what conf_get in the .sh twin does.
    if (val) conf[key] = val;
    else delete conf[key];
  }
  return conf;
}

function git(repo, args, opts = {}) {
  return execFileSync("git", ["-C", repo, ...args], {
    encoding: "utf8",
    timeout: 10000,
    stdio: ["ignore", "pipe", "ignore"],
    // GIT_TERMINAL_PROMPT=0 for the same reason the .sh twin sets it: a hook
    // has no terminal to answer a credential prompt on, and a prompt waiting
    // on stdin is the hang the timeout above is guarding against. Spread the
    // parent env first — passing `env` replaces it wholesale.
    env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
    ...opts,
  });
}

function main() {
  const home = os.homedir();

  // --- locate the repo (same resolution order as ai-memory-sync.js) --------
  // ~/.claude/ai-memory-path first; with no path file the one generic fallback
  // is $HOME/.ai-memory, used if it is a git repo. Same order as
  // ai-memory-commit.sh, so the two ports cannot disagree about which checkout
  // they mean.
  const candidates = [];
  try {
    const p = fs
      .readFileSync(path.join(home, ".claude", "ai-memory-path"), "utf8")
      .split(/\r?\n/)[0]
      .trim();
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
  if (!repo) return;

  const conf = readConf(repo);
  // Kept as a forward-slash relative path: it is a git pathspec, not an OS path.
  const MEM_DIR = conf.MEMORY_DIR || "claude-setup/memory";
  if (!fs.existsSync(path.join(repo, MEM_DIR))) return;

  // --- anything to commit? ------------------------------------------------
  // Cheap: a clean tree exits here having touched no index and no network.
  let dirty;
  try {
    dirty = git(repo, ["status", "--porcelain", "--", MEM_DIR]).trim();
  } catch {
    return;
  }
  if (!dirty) return;

  // Refuse to run mid-rebase/merge — committing into that state makes a mess a
  // human then has to unpick.
  let gitDir;
  try {
    gitDir = git(repo, ["rev-parse", "--git-dir"]).trim();
  } catch {
    return;
  }
  if (!path.isAbsolute(gitDir)) gitDir = path.join(repo, gitDir);
  for (const marker of [
    "MERGE_HEAD",
    "REBASE_HEAD",
    "CHERRY_PICK_HEAD",
    "rebase-merge",
    "rebase-apply",
  ]) {
    if (fs.existsSync(path.join(gitDir, marker))) return;
  }

  // Refuse on a detached HEAD too. A commit made there is on no branch: the
  // moment the user checks a branch back out the session's memory is gone from
  // the tree, and — the sync hook having no branch to push either — nothing
  // ever recovers it. Refusing leaves the files on disk, where the next session
  // picks them up. (An unborn branch is fine: symbolic-ref resolves before the
  // first commit.)
  try {
    git(repo, ["symbolic-ref", "-q", "HEAD"]);
  } catch {
    return;
  }

  // --- stage only the memory directory ------------------------------------
  try {
    git(repo, ["add", "--", MEM_DIR]);
  } catch {
    return;
  }

  // `add` can still leave nothing staged (e.g. ignored files only).
  let staged;
  try {
    // core.quotePath=false because git's default is to octal-escape and
    // double-quote any path that is not pure ASCII, which would put
    // `r\303\251sum\303\251.md"` in the subject line — and the stray closing quote
    // also defeats the `.md` strip.
    staged = git(repo, ["-c", "core.quotePath=false", "diff", "--cached", "--name-only", "--", MEM_DIR])
      .split(/\r?\n/)
      .filter(Boolean);
  } catch {
    return;
  }
  if (staged.length === 0) return;

  // Name what changed so the log stays readable without opening the diff.
  const files = staged
    .map((f) => path.basename(f).replace(/\.md$/, ""))
    .join(", ")
    .slice(0, 90);

  // A failed commit must not leave the memory tree staged. The usual causes are
  // environmental and outlast the session — no committer identity yet, a signing
  // key this non-interactive hook cannot unlock, a locked index — so the staging
  // would still be there on the user's next commit in that repo, where it is
  // either swept into an unrelated commit or refused outright by the framework's
  // own mixed-staging guard. Put the index back and stay silent: the files are
  // on disk and the next session commits them.
  try {
    git(repo, [
      "commit",
      "--quiet",
      "--no-verify",
      "-m",
      `memory: ${staged.length} file(s) from a session — ${files}`,
      "--",
      MEM_DIR,
    ]);
  } catch {
    try { git(repo, ["reset", "--quiet", "--", MEM_DIR]); } catch { /* nothing left to try */ }
  }
}

try { main(); } catch { /* never break session end */ }
