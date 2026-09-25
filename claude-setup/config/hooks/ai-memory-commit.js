#!/usr/bin/env node
// ai-memory-commit.js - SessionEnd hook (Windows port of ai-memory-commit.sh).
// The write half of memory sync.
//
// Commits anything written under the memory tree (MEMORY_DIR, default
// claude-setup/memory/) during the session, and - as a SECOND, SEPARATE commit -
// anything written to the session bus (BUS_DIR, default
// claude-setup/session-bus/).
// It does NOT push: no network call happens here, so ending a session is never
// slower for it. The commit goes out on the next SessionStart, where
// ai-memory-sync.js already talks to the remote - one round trip, in a session
// the user started, so a rebase conflict surfaces while they are present.
//
// ⛔ Why the bus needs its own line here at all: it is MEMORY_DIR's SIBLING, not
// its child. Staging the memory tree by path therefore never touched it, so a
// session's closing summary to the other machines was committed nowhere and was
// still untracked at the next pull - invisible to every other machine, with no
// error and no warning. Worse, the "nothing to commit" fast path below keyed on
// the memory tree alone, so a session whose only dirty file was its outbox
// exited before staging anything at all.
//
// ⛔ And why they must be TWO commits, never one `add` of both paths: the
// framework's own pre-commit guard refuses any commit that stages paths both
// inside and outside MEMORY_DIR. A single mixed commit would be rejected by that
// guard and the whole hook would silently do nothing - the failure it is here to
// end.
//
// Scope is deliberately narrow: this stages those two directories by path, one
// per commit, and nothing else. An auto-commit is fine for a memory store and
// unacceptable for source, and the memory repo may hold both.
//
// The commit runs with --no-verify, on purpose. This hook stages one directory
// by path and commits only that pathspec, so a mixed-staging guard (the
// framework's pre-commit, which refuses a commit that mixes memory and source)
// is satisfied by construction and there is nothing left for it to check. The
// consequence is that repo-local hooks in the memory repo (pre-commit,
// commit-msg, prepare-commit-msg - husky, lint-staged, and the like) are
// bypassed for THIS ONE COMMIT only; every commit a person makes in that repo
// still runs them.
//
// Every failure mode is silent. A memory file that fails to commit is still on
// disk and will be picked up next time.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync, spawn } = require("child_process");

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

function git(repo, args, opts = {}) {
  return execFileSync("git", ["-C", repo, ...args], {
    encoding: "utf8",
    timeout: 10000,
    stdio: ["ignore", "pipe", "ignore"],
    // GIT_TERMINAL_PROMPT=0 for the same reason the .sh twin sets it: a hook
    // has no terminal to answer a credential prompt on, and a prompt waiting
    // on stdin is the hang the timeout above is guarding against. Spread the
    // parent env first - passing `env` replaces it wholesale.
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
  // Kept as forward-slash relative paths: these are git pathspecs, not OS paths.
  const MEM_DIR = conf.MEMORY_DIR || "claude-setup/memory";
  // BUS_DIR is the key the session-bus notice hook already reads, deliberately:
  // one name for one directory. A second key meaning the same thing is how two
  // readers of this file end up disagreeing and a guard goes quiet.
  const BUS_DIR = conf.BUS_DIR || "claude-setup/session-bus";

  // Each directory stands on its own: either may be absent from a given repo,
  // and either may be clean. A directory that drops out here is skipped in
  // silence by every later step.
  //
  // Both are asked, so a session whose only change is its outbox is no longer
  // dropped on the floor by the "nothing to commit" fast path.
  const dirs = [];
  for (const [dir, prefix] of [[MEM_DIR, "memory:"], [BUS_DIR, "✅TEAM:"]]) {
    if (!dir || !fs.existsSync(path.join(repo, dir))) continue;
    let dirty;
    try {
      dirty = git(repo, ["status", "--porcelain", "--", dir]).trim();
    } catch {
      continue;
    }
    if (dirty) dirs.push([dir, prefix]);
  }
  // Cheap: a clean tree exits here having touched no index and no network.
  if (dirs.length === 0) return;

  // Refuse to run mid-rebase/merge - committing into that state makes a mess a
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
  // the tree, and - the sync hook having no branch to push either - nothing
  // ever recovers it. Refusing leaves the files on disk, where the next session
  // picks them up. (An unborn branch is fine: symbolic-ref resolves before the
  // first commit.)
  try {
    git(repo, ["symbolic-ref", "-q", "HEAD"]);
  } catch {
    return;
  }

  // --- stage and commit ONE directory, alone ------------------------------
  // One pathspec per call and one pathspec per commit: never `add` both
  // directories together, or the mixed-staging guard described at the top of
  // this file rejects the commit and nothing lands. Returns true only when a
  // commit was actually created; every failure resets what it staged, so one
  // half failing cannot strand the other.
  const commitDir = (dir, prefix) => {
    try {
      git(repo, ["add", "--", dir]);
    } catch {
      return false;
    }

    // `add` can still leave nothing staged (e.g. ignored files only).
    let staged;
    try {
      // core.quotePath=false because git's default is to octal-escape and
      // double-quote any path that is not pure ASCII, which would put
      // `r\303\251sum\303\251.md"` in the subject line - and the stray closing quote
      // also defeats the `.md` strip.
      staged = git(repo, ["-c", "core.quotePath=false", "diff", "--cached", "--name-only", "--", dir])
        .split(/\r?\n/)
        .filter(Boolean);
    } catch {
      return false;
    }
    if (staged.length === 0) return false;

    // Name what changed so the log stays readable without opening the diff.
    const files = staged
      .map((f) => path.basename(f).replace(/\.md$/, ""))
      .join(", ")
      .slice(0, 90);

    // A failed commit must not leave the tree staged. The usual causes are
    // environmental and outlast the session - no committer identity yet, a signing
    // key this non-interactive hook cannot unlock, a locked index - so the staging
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
        `${prefix} ${staged.length} file(s) from a session - ${files}`,
        "--",
        dir,
      ]);
    } catch {
      try { git(repo, ["reset", "--quiet", "--", dir]); } catch { /* nothing left to try */ }
      return false;
    }
    return true;
  };

  // Memory first, then the bus - two commits, in that order.
  let committed = false;
  for (const [dir, prefix] of dirs) {
    if (commitDir(dir, prefix)) committed = true;
  }
  // Nothing committed - nothing to push, and nothing left staged.
  if (!committed) return;

  // ── Opportunistic push ──────────────────────────────────────────────────
  //
  // ⚠️ Why push here when ai-memory-sync pushes on the next SessionStart:
  // because "the next SessionStart" means the next one ON THIS MACHINE. End
  // your last session on one machine and open another, and that memory is
  // committed locally and reachable from nowhere - the exact case this layer
  // exists to prevent. The next SessionStart is still the reliable path: it
  // pulls first, resolves divergence and surfaces a conflict while the user is
  // there. This is the opportunistic one, and it stays silent about failure
  // because anything it misses the next session repairs.
  //
  // detached + unref'd so ending a session is never slower for it, whether the
  // network is slow, dead or absent - the failure mode that kept this hook off
  // the network to begin with. Matches ai-memory-commit.sh.
  //
  // ⛔ Current branch only, never --force, never a new remote. A rejected push
  // (diverged, no upstream, no remote) is the normal case, and SessionStart
  // handles it properly with a pull first.
  try {
    git(repo, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]);
  } catch {
    return;   // no upstream to push to; nothing to do here
  }

  // ⛔ Do NOT pass spawn's `timeout` option here. It arms a timer that keeps
  // this process's event loop alive, so node sits waiting for the full timeout
  // even with the child detached and unref'd - measured at 5s against a dead
  // remote, which is precisely the delay at session end this is meant to
  // avoid. The bound comes from git instead: the low-speed settings below end
  // a stalled HTTP transfer, GIT_TERMINAL_PROMPT=0 stops a credential prompt
  // waiting on a stdin nobody is watching, and SSH is bounded by its own
  // ConnectTimeout. Anything that still escapes is an orphan that harms
  // nothing and the next SessionStart repairs.
  const secs = String(Number(process.env.SUNSTONE_PUSH_TIMEOUT) || 20);
  try {
    const child = spawn("git", [
      "-C", repo,
      "-c", "http.lowSpeedLimit=1000",
      "-c", `http.lowSpeedTime=${secs}`,
      "push", "--quiet", "--no-verify",
    ], {
      detached: true,
      stdio: "ignore",
      // --no-verify because the framework's own pre-push guard is interactive
      // by design, and a guard asking a question with nobody there is a hang.
      // GIT_TERMINAL_PROMPT=0 for the same reason, one layer down.
      env: { ...process.env, GIT_TERMINAL_PROMPT: "0", GIT_SSH_COMMAND: process.env.GIT_SSH_COMMAND || `ssh -o ConnectTimeout=${secs} -o BatchMode=yes` },
    });
    child.unref();
  } catch { /* the next SessionStart pushes it */ }
}

try { main(); } catch { /* never break session end */ }
