#!/usr/bin/env node
// memory-guard.mjs - PostToolUse hook on Bash (registered by the settings
// template). Two jobs, both aimed at the WSL freeze of 2026-10-25, when the
// 32GB VM filled up after a day of dev servers, screenshot scripts and four
// parallel builds, and the kernel could no longer hand out memory.
//
// 1. Low memory: when MemAvailable drops under MEMORY_GUARD_PCT (default 15)
//    percent, tell the session which processes hold the most memory, so it
//    stops starting work and closes what it left running. Linux only.
//
// 2. Leftover browsers: kill automation browsers whose launching script is
//    already dead.
//
// Screenshot and test scripts start Chromium through Playwright or Puppeteer
// and close it on their last line. When the script throws, or `timeout` kills
// node, that line never runs: the browser is reparented and lives on. On
// 2026-10-25 one WSL session left 64 of them behind (374 started, 310 closed)
// and the VM ran out of memory and froze.
//
// Two tests decide, both must hold:
//   - the process is a browser started for automation: its command line has
//     --remote-debugging-pipe or --remote-debugging-port. A browser a person
//     opened has neither, so it is never touched.
//   - it is the top of an orphaned tree: its parent is pid 1 or a
//     `systemd --user` subreaper, i.e. whoever launched it has exited.
// A live test run keeps its browser parented to node, so it is left alone.
//
// The whole process group gets SIGTERM, then SIGKILL after 2s for any
// survivor. No `ps` (Windows) or any failure: silent, never an error in the
// hook output. MEMORY_GUARD=0 turns it all off; MEMORY_GUARD_DRY=1 only reports.

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import { fileURLToPath } from "node:url";

const AUTOMATION = /--remote-debugging-(pipe|port)/;
// The program itself, not its arguments: `node chrome-shots.cjs` is not a browser.
const BROWSER = /^(chrome|chromium|chromium-browser|chrome-headless-shell|headless_shell|google-chrome[\w-]*)$/i;

export function listProcesses() {
  const out = execFileSync("ps", ["-eo", "pid=,ppid=,args="], { encoding: "utf8", timeout: 3000 });
  return out.split("\n").map((l) => l.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/)).filter(Boolean)
    .map(([, pid, ppid, args]) => ({ pid: +pid, ppid: +ppid, args }));
}

export function findOrphans(procs) {
  const byPid = new Map(procs.map((p) => [p.pid, p]));
  const isReaper = (pid) => {
    if (pid === 1) return true;
    const p = byPid.get(pid);
    return !!p && /(^|\/)(systemd|init)(\s|$)/.test(p.args.split(" ")[0]);
  };
  return procs.filter((p) => {
    const exe = p.args.split(" ")[0].split("/").pop();
    return BROWSER.test(exe) && AUTOMATION.test(p.args) && !/--type=/.test(p.args) && isReaper(p.ppid);
  });
}

function kill(pid, sig) {
  try { process.kill(-pid, sig); return; } catch { /* not a group leader */ }
  try { process.kill(pid, sig); } catch { /* already gone */ }
}

// Percent of RAM still available, from /proc/meminfo. null where there is none.
export function availablePct(meminfo) {
  const kb = (k) => +(meminfo.match(new RegExp(`^${k}:\\s+(\\d+)`, "m")) || [])[1];
  const total = kb("MemTotal"), avail = kb("MemAvailable");
  return total && avail >= 0 ? (100 * avail) / total : null;
}

function topMemory(n) {
  const out = execFileSync("ps", ["-eo", "rss=,pid=,args=", "--sort=-rss"], { encoding: "utf8", timeout: 3000 });
  return out.split("\n").filter(Boolean).slice(0, n).map((l) => {
    const [, rss, pid, args] = l.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/) || [];
    return `${(rss / 1048576).toFixed(1)}G pid ${pid} ${String(args).slice(0, 90)}`;
  });
}

async function main() {
  if (process.env.MEMORY_GUARD === "0" || process.platform === "win32") return;
  for await (const _ of process.stdin) { /* drain */ }
  const dry = process.env.MEMORY_GUARD_DRY === "1";
  const notes = [];

  const orphans = findOrphans(listProcesses());
  if (orphans.length) {
    if (!dry) {
      for (const o of orphans) kill(o.pid, "SIGTERM");
      await new Promise((r) => setTimeout(r, 2000));
      for (const o of orphans) kill(o.pid, "SIGKILL");
    }
    notes.push(
      `memory-guard: ${dry ? "found" : "closed"} ${orphans.length} leftover automation browser(s) ` +
      `(pids ${orphans.map((o) => o.pid).join(", ")}). A script launched a browser and exited without ` +
      "closing it - put browser.close() in a finally block.");
  }

  let pct = null;
  try { pct = availablePct(fs.readFileSync("/proc/meminfo", "utf8")); } catch { /* not Linux */ }
  const floor = +(process.env.MEMORY_GUARD_PCT || 15);
  if (pct !== null && pct < floor) {
    notes.push(
      `memory-guard: LOW MEMORY - only ${pct.toFixed(0)}% of RAM is free (warning under ${floor}%). ` +
      "Do not start builds, test runs, browsers or agents. Stop dev servers, scripts and browsers you " +
      "started and no longer need, then carry on. Biggest users:\n" + topMemory(8).join("\n"));
  }

  if (!notes.length) return;
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: notes.join("\n\n") },
  }));
}

// Run only as a hook, not when a test imports it. argv[1] is the ~/.claude/hooks
// symlink, so compare real paths.
let isMain = false;
try { isMain = fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url); } catch { /* no argv */ }
if (isMain) main().catch(() => { /* never an error in the hook output */ });
