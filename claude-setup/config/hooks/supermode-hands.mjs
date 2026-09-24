#!/usr/bin/env node
// supermode-hands - the guard that keeps the orchestrator's hands off the work.
// A PreToolUse hook on the editing tools. Pure Node.js, no shell dependency.
//
// Supermode's bargain is that the SESSION spends no context on the work: it reads
// the queue, decides the slice, spawns an agent, gates, commits, hands off. The
// failure mode is not dramatic - the session just starts doing the slice itself,
// "because it is small", and twenty of those later the window is full and the mode
// has quietly become an ordinary session with extra ceremony - and the user, who
// left the chair precisely so this would not need watching, finds a full window
// and a summary where a night of work should be. Words in a command file cannot
// hold a line the model crosses one small edit at a time. A hook can.
//
// So: while supermode is on (~/.claude/ctx/<sid>.sm, or SUPERMODE=1), Edit, Write
// and NotebookEdit are DENIED unless the path is orchestrator's business -
//   * the handoff and the queue:  docs/ai-memory/**, session-<date>.md, WORK-QUEUE,
//     HANDOFF, MEMORY.md, ABOUT-*.md, any *.md under a docs/ tree
//   * the scratchpad and the gauge files themselves
// - and the same rule is applied to the Bash commands that are really edits
// (`sed -i`, `perl -pi`, `tee`, a `>` redirect). Bash is otherwise untouched: the
// gate, git and the launcher are the orchestrator's own job and must stay central.
//
// The deny is not a wall. `touch ~/.claude/ctx/<sid>.hands` (or SUPERMODE_HANDS=1)
// takes the wheel back for the rest of the session - for when an agent cannot be
// spawned, or a one-line fix is genuinely faster than a delegation. The point is
// that taking the wheel becomes a DECISION with a command behind it, instead of a
// drift nobody notices.
//
// Silent on every failure: a guard that crashes must not block the work.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { homedir } from "node:os";

let input = {};
try { input = JSON.parse(readFileSync(0, "utf8") || "{}"); } catch { process.exit(0); }

function cfgDir() {
  const e = process.env.CLAUDE_CONFIG_DIR;
  if (e && e.trim() !== "") return e.startsWith("~") ? resolve(homedir(), e.replace(/^~[/\\]?/, "")) : resolve(e);
  return resolve(homedir(), ".claude");
}
const sid = typeof input.session_id === "string" ? input.session_id.replace(/[^A-Za-z0-9_-]/g, "") : "";
const ctx = resolve(cfgDir(), "ctx");
const on = process.env.SUPERMODE === "1" || (sid && existsSync(resolve(ctx, `${sid}.sm`)));
if (!on) process.exit(0);
// The wheel, taken back deliberately.
if (process.env.SUPERMODE_HANDS === "1" || (sid && existsSync(resolve(ctx, `${sid}.hands`)))) process.exit(0);

// ⛔ The agents inherit these hooks. A subagent's tool calls arrive here with the
// SAME session_id as the orchestrator's, so a guard that only asked "is supermode
// on?" would deny the very edits it exists to cause - the mode would forbid all
// work by anyone and wedge on its first slice.
//
// So the orchestrator is identified POSITIVELY, never by "not a subagent": its
// transcript is the session's own file, <...>/<session-id>.jsonl, while a
// subagent's is <...>/<session-id>/subagents/agent-<id>.jsonl. Anything else -
// no transcript in the payload, a path shaped some other way, a layout this
// hook has not seen - is left alone. This guard fails OPEN by construction: a
// missed deny costs one edit in the wrong window, a wrong deny costs the run.
const transcript = String(input.transcript_path || "").replace(/\\/g, "/");
const parentTranscript = sid && transcript.endsWith(`/${sid}.jsonl`) && !transcript.includes("/subagents/");
if (!parentTranscript) process.exit(0);

// The breaker. The identification above rests on a transcript layout that is the
// harness's to change, and hooks are snapshotted at session start, so a mistaken
// guard cannot be fixed from inside the session it is breaking. If it denies six
// times in one session, something is wrong with the guard and not with the work:
// it disengages itself, leaves the `.hands` marker so the rest of the session is
// consistent, and says so once. A tool that cannot be wrong is a tool nobody can
// leave running unattended.
const denyLog = resolve(ctx, `${sid}.handsdeny`);
let denies = 0;
try { denies = parseInt(readFileSync(denyLog, "utf8").trim(), 10) || 0; } catch { denies = 0; }
if (denies >= 6) {
  try { writeFileSync(resolve(ctx, `${sid}.hands`), "disengaged: six denials in one session\n"); } catch { /* */ }
  process.exit(0);
}

const tool = String(input.tool_name || "");
const args = input.tool_input || {};

// Paths the orchestrator itself owns. Everything else is an agent's job.
const ALLOW = [
  /(^|\/)docs\/ai-memory\//i,
  /(^|\/)docs\/.*\.md$/i,
  /session-\d{4}-\d{2}-\d{2}.*\.md$/i,
  /(^|\/)(WORK-QUEUE|HANDOFF|MEMORY|ABOUT-[A-Z]+)[^/]*\.md$/i,
  /(^|\/)claude-setup\/memory\//i,
  /\/scratchpad\//i,
  /^\/tmp\//i,
  /\.claude\/ctx\//i,
];
const allowed = (p) => !p || ALLOW.some((re) => re.test(String(p).replace(/\\/g, "/")));

let path = null;
if (tool === "Edit" || tool === "Write" || tool === "NotebookEdit") {
  path = args.file_path || args.notebook_path || "";
  if (allowed(path)) process.exit(0);
} else if (tool === "Bash") {
  const cmd = String(args.command || "");
  // Only the forms that WRITE a file. A redirect into /dev/null, into the
  // scratchpad or into an allowlisted note is not an edit of the work.
  //
  // ⛔ SCAN THE SHELL SYNTAX, NOT THE TEXT. The first version matched `>` and
  // `tee` anywhere in the string, which denied the orchestrator's own work:
  //     git commit -m "slice 2 -> gate passed"    the arrow is PROSE
  //     git log --format="%h => %s"               so is this one
  //     pnpm build | tee <scratchpad>/build.log   an allowed target
  // Commits are the one thing the contract promises stay the orchestrator's, so
  // a guard that denies them is worse than no guard - and each false deny burns
  // one of the six the breaker allows. Found by a peer session reading the
  // pushed file, 2026-09-25.
  //
  // A redirect operator cannot appear inside quotes and a heredoc body is data,
  // so both are removed before looking for operators; targets are read from a
  // second copy where the quotes are peeled off but their CONTENTS survive, so a
  // quoted path is still checked.
  const stripHeredocs = (t) =>
    t.replace(/<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1[\s\S]*?(?:\n[ \t]*\2[ \t]*(?:\n|$)|$)/g, " ");
  const base = stripHeredocs(cmd);
  const forOps = base.replace(/'[^']*'/g, " '' ").replace(/"(?:[^"\\]|\\.)*"/g, ' "" ');
  const forArgs = base.replace(/'([^']*)'/g, "$1").replace(/"((?:[^"\\]|\\.)*)"/g, "$1");

  const targets = [];
  let m;
  const redirect = /(?<![0-9<>])>>?\s*([^\s;|&)]+)/g;
  while ((m = redirect.exec(forOps))) targets.push(m[1]);

  // `tee`, `sed -i`, `perl -pi` write the files they are GIVEN - so read the
  // files they are given, rather than denying the command for existing.
  const writerTargets = (seg, kind) => {
    const tok = seg.trim().split(/\s+/).slice(1);      // drop the command itself
    const out = [];
    let skipNext = false, scriptSeen = kind !== "sed";  // sed's first bare arg is its script
    for (const t of tok) {
      if (skipNext) { skipNext = false; scriptSeen = true; continue; }
      if (/^-/.test(t)) { if (/^(-e|-E|--expression|-f|--file)$/.test(t)) skipNext = true; continue; }
      if (!scriptSeen) { scriptSeen = true; continue; }
      out.push(t);
    }
    return out;
  };
  // ⚠️ The `-i` lookahead must allow the flag to come FIRST. Requiring `\s-i`
  // meant `sed -i 's/a/b/' src/app.ts` - the commonest form there is - matched
  // nothing and sailed through. Caught by the test battery, not by reading.
  for (const re of [/(?:^|[;|&(]\s*)(tee\s+[^;|&)]*)/g,
                    /(?:^|[\s;|&(])(sed\s+(?=(?:[^;|&)]*\s)?-i)[^;|&)]*)/g,
                    /(?:^|[\s;|&(])(perl\s+(?=(?:[^;|&)]*\s)?-[a-zA-Z]*i)[^;|&)]*)/g]) {
    let w;
    while ((w = re.exec(forArgs))) {
      const kind = w[1].startsWith("sed") ? "sed" : w[1].startsWith("perl") ? "perl" : "tee";
      targets.push(...writerTargets(w[1], kind));
    }
  }

  const bad = targets.filter((t) => t !== "/dev/null" && !/^\/dev\//.test(t) && !allowed(t));
  if (!bad.length) process.exit(0);   // nothing written, or everything written is the orchestrator's own
  path = bad[0];
} else {
  process.exit(0);
}

const reason =
  `supermode: you are the orchestrator, so this edit is not yours to make. ` +
  `Spawn an Agent (Agent tool) for the slice that touches ${path} and let it do the editing - ` +
  `its context is spent instead of this session's, which is the whole reason the mode exists. ` +
  `Give the agent the verified facts you already hold (exact paths, the gate command, what "done" is) ` +
  `so it does not rediscover them, and keep its slice small enough to finish under 60% of its window ` +
  `(\`node ~/.claude/hooks/agent-watch.mjs --report\` shows where each one stands). ` +
  `The handoff note, the queue row, the gate and the commit stay yours. ` +
  `If this genuinely cannot be delegated - no agent can be spawned, or it is a one-liner an agent would ` +
  `cost more than - take the wheel deliberately: \`touch ${resolve(ctx, `${sid || "<session-id>"}.hands`)}\` ` +
  `and say in one line why, then repeat the edit.`;

try { writeFileSync(denyLog, String(denies + 1) + "\n"); } catch { /* the breaker is a courtesy */ }

process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: reason,
  },
}) + "\n");
