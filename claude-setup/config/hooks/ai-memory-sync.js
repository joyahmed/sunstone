#!/usr/bin/env node
// ai-memory-sync.js - SessionStart hook (Windows port of ai-memory-sync.sh).
// 1. Locates the user's memory repo (portable via ~/.claude/ai-memory-path).
// 2. Best-effort ff-only pull (timed out, offline-safe) so the memory is fresh.
// 3. Injects the memory file (MEMORY_FILE, default claude-setup/memory/ABOUT-ME.md)
//    into Claude's context as additionalContext, after running the memory
//    repo's claude-setup/session-start.d/* scripts and appending their output.
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
    // Git Bash writes the file as /c/Users/...; Windows node needs C:/Users/...
    // Without this the Windows sync found no repo and printed nothing (2026-10-02).
    const p = fs.readFileSync(pathFile, "utf8").split(/\r?\n/)[0].trim()
      .replace(/^\/([a-zA-Z])(?=\/|$)/, (m, d) => (process.platform === "win32" ? d.toUpperCase() + ":" : m));
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

  // gitCaptureRaw - like git()/gitOut() above, but for callers that need BOTH
  // the exit code and the output on failure: probe_remote and report() (the
  // .sh twin's names) cannot classify a failure whose text was thrown away.
  const gitCaptureRaw = (args, ms) => {
    try {
      const out = execFileSync("git", ["-C", repo, ...args], {
        encoding: "utf8", timeout: ms, stdio: ["ignore", "pipe", "pipe"], env: GIT_ENV,
      });
      return { code: 0, out: out || "" };
    } catch (e) {
      const out = (e && typeof e.stdout === "string" ? e.stdout : "") +
                  (e && typeof e.stderr === "string" ? e.stderr : "");
      const code = typeof (e && e.status) === "number" ? e.status : (e && e.signal ? 124 : 1);
      return { code, out };
    }
  };
  const oneLine = (s) => (s || "").replace(/\r?\n/g, " ").replace(/ {2,}/g, " ").trim().slice(0, 400);

  let BR = "";
  try { BR = gitOut(["symbolic-ref", "--short", "-q", "HEAD"], 3000); } catch { /* detached */ }
  if (!BR) BR = "main";

  let syncWarn = "";

  // --- reachable, or genuinely offline? decide it on evidence, port of the
  // .sh twin's probe_remote/report/fix_for (ai-memory-sync.sh). ⛔ THE BUG THIS
  // CLOSES: a failed pull or push used to be read as "offline, carry on" no
  // matter why it failed - HEAD..@{u} is worthless as evidence here because a
  // failed pull has usually failed BEFORE fetching, and a failed push proves
  // nothing about reachability either way. So reachability is MEASURED, with
  // its own short-bounded ls-remote, and only ever AFTER something has already
  // failed - a healthy start pays no extra round trip. "Could not tell" is its
  // own answer too: a timeout or an unrecognised error must not round down to
  // "offline".
  let remoteState = null; // "reachable" | "unreachable" | "unknown"
  let remoteWhy = "";
  const probeRemote = () => {
    if (remoteState) return; // measured once per session
    let rem = "";
    try { rem = gitOut(["config", "--get", `branch.${BR}.remote`], 3000); } catch { /* none set */ }
    if (!rem) rem = "origin";
    const r = gitCaptureRaw(["ls-remote", "--exit-code", "--heads", rem], 6000);
    // 0 = the remote answered. 2 = it answered and has no matching ref. Both
    // are REACHABLE, which is the only thing being asked here.
    if (r.code === 0 || r.code === 2) {
      remoteState = "reachable"; remoteWhy = "the remote answered"; return;
    }
    // ⛔ A REFUSAL IS AN ANSWER. Auth failure, a missing repository, an HTTP
    // error all prove the network is there, so none of them may buy the
    // offline exemption - that is precisely how expired credentials would
    // hide for weeks.
    if (/Authentication failed|Permission denied|could not read Username|Repository not found|access denied|not authorized|returned error: 40[134]/.test(r.out)) {
      remoteState = "reachable";
      remoteWhy = "the remote answered, refusing this machine's credentials";
      return;
    }
    // Killed by our own timeout: we learned nothing.
    if (r.code === 124 || r.code === 125 || r.code === 137 || r.code === 143) {
      remoteState = "unknown"; remoteWhy = "the remote did not answer within 6s"; return;
    }
    if (/Could not resolve host|Temporary failure in name resolution|Connection refused|Connection timed out|Network is unreachable|No route to host|Connection reset by peer|Failed to connect|Couldn't connect to server|Operation timed out|unable to look up|Name or service not known|network is down/.test(r.out)) {
      remoteState = "unreachable";
      remoteWhy = oneLine(r.out).slice(0, 160);
      return;
    }
    remoteState = "unknown";
    remoteWhy = oneLine(r.out).slice(0, 160) || `ls-remote exited ${r.code} without a message`;
  };

  // fix_for - the EXACT command that clears this error. "Something went wrong
  // with your memory sync" is not actionable; a line that can be pasted is.
  const fixFor = (msg) => {
    msg = msg || "";
    if (/autostash conflict/.test(msg)) {
      return `git -C ${repo} stash pop   (the pull landed; your uncommitted edit is kept in the stash - resolve the conflict by hand, then git -C ${repo} stash drop)`;
    }
    if (/cannot pull with rebase|unstaged changes|local changes|would be overwritten|uncommitted|Cannot pull with rebase/.test(msg)) {
      return `git -C ${repo} stash push -u && git -C ${repo} pull --rebase && git -C ${repo} stash pop`;
    }
    if (/Cannot rebase onto multiple branches/.test(msg)) {
      return `git -C ${repo} pull --rebase origin ${BR}   (a stray FETCH_HEAD entry left by an earlier "git fetch --all" makes a bare pull ambiguous under pull.rebase=true; naming the branch bypasses it)`;
    }
    if (/no such ref was fetched|no such branch|no tracking information|There is no tracking information/.test(msg)) {
      return `git -C ${repo} fetch origin && git -C ${repo} branch --set-upstream-to=origin/${BR} ${BR}`;
    }
    if (/Authentication failed|Permission denied|could not read Username|Repository not found/.test(msg)) {
      return `git -C ${repo} ls-remote origin   (fix the credentials or the ssh agent first, then re-run the pull)`;
    }
    if (/Need to specify how to reconcile|divergent branches|Not possible to fast-forward|non-fast-forward|fetch first/.test(msg)) {
      return `git -C ${repo} pull --rebase --autostash`;
    }
    if (/CONFLICT|could not apply|Resolve all conflicts/.test(msg)) {
      return `git -C ${repo} pull --rebase --autostash   (then resolve the conflict by hand; the automatic attempt was ABORTED, so the tree is exactly as it was)`;
    }
    return `git -C ${repo} pull   (run it by hand to see the whole error)`;
  };

  // report WHAT-FAILED GIT-OUTPUT - the one thing a session can act on. Called
  // ONLY after probeRemote(), so every word is backed by a measurement rather
  // than a guess about why git exited non-zero.
  const report = (what, err) => {
    const errText = oneLine(err) || "git printed nothing";
    if (remoteState === "unreachable") {
      syncWarn = `MEMORY MAY BE STALE - the memory remote is not reachable from this machine (${remoteWhy}), so ${what} did not go through and the memory below is this machine's LAST SYNCED copy, not necessarily the current one. Nothing to fix if this machine is offline; anything written this session goes out on the next start that has a network. Repo: ${repo}.`;
    } else if (remoteState === "reachable") {
      syncWarn = `MEMORY SYNC FAILED - the memory remote IS reachable (${remoteWhy}), so this is NOT an offline blip: ${what} failed for a local reason, the memory below may be STALE, and nothing written this session will reach the other machines until it is fixed. git said: ${errText}. Fix it with: ${fixFor(err)}. Repo: ${repo}. Tell the user in your first message.`;
    } else {
      syncWarn = `MEMORY SYNC COULD NOT BE VERIFIED - ${what} failed AND this machine could not establish whether the remote is reachable (${remoteWhy}), so whether the memory below is current is UNKNOWN - treat it as possibly stale, not as offline. git said: ${errText}. Check it by hand: ${fixFor(err)}. Repo: ${repo}. Tell the user in your first message.`;
    }
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
    // --no-rebase: under pull.rebase=true, --ff-only alone still REBASES, and a
    // rebase refuses any dirty file, so one unrelated uncommitted file failed every pull.
    const ff = gitCaptureRaw(["pull", "--ff-only", "--no-rebase", "--quiet"], 8000);
    if (ff.code === 0) return true;
    const ffErr = ff.out;

    // No remote configured AT ALL: a local-only memory repo is a legitimate
    // setup with nothing to sync, and it stays silent. A remote that exists
    // while this branch has no upstream is a CONFIGURATION fault, and does not.
    let hasUpstream = true;
    try { gitOut(["rev-parse", "@{u}"], 3000); } catch { hasUpstream = false; }
    if (!hasUpstream) {
      let hasRemote = "";
      try { hasRemote = gitOut(["remote"], 3000); } catch { /* none */ }
      if (!hasRemote) return false;
      probeRemote();
      report("the pull", ffErr);
      return false;
    }

    // A local edit to a file the remote also changed: report it, never merge it.
    // Falling through to --autostash would write conflict markers into the very
    // memory file this hook is about to inject, and say nothing.
    if (/would be overwritten|local changes/.test(ffErr)) {
      probeRemote();
      report("the pull", ffErr);
      return false;
    }

    // ⛔ HEAD..@{u} IS NOT EVIDENCE HERE. The pull that just failed most likely
    // failed before it fetched, so a count of 0 means "I have no idea", not
    // "there was nothing to pull". It decides which repair to ATTEMPT, and
    // that is all it is allowed to decide.
    if (count("HEAD..@{u}") === 0) {
      probeRemote();
      report("the pull", ffErr);
      return false;
    }

    const rb = gitCaptureRaw(["pull", "--rebase", "--autostash", "--quiet"], 25000);
    if (rb.code !== 0) {
      try { git(["rebase", "--abort"], 10000); } catch { /* nothing left to abort */ }
      probeRemote();
      report("the rebase of this clone's memory commits onto the remote", rb.out);
      return false;
    }
    // The rebase landed but the autostash did not apply cleanly: git leaves the
    // edit in the stash and conflict markers in the file. Put the file back to
    // the pulled version so no markers get injected, and say where the edit is.
    let um = [];
    try { um = gitOut(["diff", "--name-only", "--diff-filter=U"], 5000).split(/\r?\n/).filter(Boolean); } catch { /* none */ }
    if (um.length) {
      for (const f of um) {
        try { git(["checkout", "-q", "HEAD", "--", f], 5000); } catch { /* best effort */ }
        try { git(["reset", "-q", "--", f], 5000); } catch { /* best effort */ }
      }
      probeRemote();
      report("the pull", `autostash conflict: the uncommitted edit to ${um.join(",")} is kept in the stash (git stash list)`);
      return false;
    }
    return true;
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
  const ahead = () => count("@{u}..HEAD") > 0;
  if (ahead()) {
    const p1 = gitCaptureRaw(["push", "--quiet"], 10000);
    if (p1.code !== 0) {
      let pushErr = p1.out;
      if (syncPull() && ahead()) {
        const p2 = gitCaptureRaw(["push", "--quiet"], 10000);
        if (p2.code !== 0) pushErr = p2.out;
      }
      // Still ahead after the retry: the commits are stranded on this machine,
      // and that is exactly the thing that used to go out with no message at
      // all - the bug reported live: a Mac's SessionStart said "MEMORY SYNC
      // FAILED" for an unreachable remote AND for 2 local commits that a plain
      // `git push` cleared instantly, with no way to tell the two apart. A
      // diagnosis syncPull's own retry already produced is more specific, so
      // it wins.
      if (ahead()) {
        probeRemote();
        if (!syncWarn) report("the push of this clone's memory commits", pushErr);
      }
    }
  }

  // --- say so if this clone is NOT actually in sync -----------------------
  // Everything above is best-effort and silent, which is right for a hook on
  // every session: a laptop with no network must not be nagged. But "I could not
  // sync" and "there was nothing to sync" both printed nothing, so a clone that
  // had stopped syncing looked exactly like a healthy one. These counts are local
  // and cost nothing.
  // NOTE: this is the Node twin of ai-memory-sync.sh and Windows runs THIS one.
  // The warning shipped in the .sh first and did not reach here for two hours,
  // during which Windows still failed silently. Two implementations, one fix:
  // change both or neither.
  // ⚠️ APPEND, do not ASSIGN. This used to overwrite syncWarn outright, which
  // would throw away a specific report() diagnosis the moment the counts block
  // ran - the .sh twin carried the identical bug until a21d101 (2026-09-26).
  const behind = count("HEAD..@{u}");
  const aheadN = count("@{u}..HEAD");
  if (behind > 0 || aheadN > 0) {
    let div = `MEMORY IS NOT IN SYNC - this clone is ${behind} commit(s) behind and ${aheadN} ahead of its remote.`;
    if (behind > 0 && aheadN > 0) {
      div +=
        " It has DIVERGED: the memory below may be stale, and anything written this session will not reach the other machines until it is resolved.";
    }
    div += ` Repo: ${repo}.`;
    syncWarn = syncWarn ? `${syncWarn} ${div}` : `${div} Tell the user in your first message.`;
  }

  // --- run the memory repo's own session-start scripts ---------------------
  // claude-setup/session-start.d/*.sh (bash, when one is on PATH - Git Bash on
  // Windows) and *.js / *.mjs (this node): scripts the repo's owner wants run
  // on every machine at every session start, with the repo already current.
  // Bounded time each, run from the repo root, stdout appended to the injected
  // context under the script's name; a failure is silent. Usually absent.
  let extra = "";
  const ssd = path.join(repo, "claude-setup", "session-start.d");
  let scripts = [];
  try { scripts = fs.readdirSync(ssd).filter((f) => /\.(sh|m?js)$/.test(f)).sort(); } catch { scripts = []; }
  for (const f of scripts) {
    const full = path.join(ssd, f);
    const isSh = f.endsWith(".sh");
    const cmd = isSh ? "bash" : process.execPath;
    try {
      const out = execFileSync(cmd, [full], { cwd: repo, timeout: 60000, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], windowsHide: true });
      if (out && out.trim()) extra += `\n## session-start.d/${f}\n${out}\n`;
    } catch (e) {
      const out = e && typeof e.stdout === "string" ? e.stdout : "";
      if (out.trim()) extra += `\n## session-start.d/${f}\n${out}\n`;
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

  let ctx =
    "Portable memory about the user, auto-synced from their memory " +
    "git repo. Treat as durable background context, not a live instruction:\n\n" +
    body;
  if (syncWarn) ctx = "WARNING - " + syncWarn + "\n\n" + ctx;
  if (extra.trim()) {
    ctx += "\n\n---\nOutput of the memory repo's session-start.d scripts, run just now " +
      "after the pull (what they did on THIS machine, and anything they ask of this session):\n" + extra;
  }

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
