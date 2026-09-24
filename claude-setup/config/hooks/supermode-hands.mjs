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
  const targets = [];
  let m;
  const redirect = /(?<![0-9<>])>>?\s*("[^"]+"|'[^']+'|[^\s;|&)]+)/g;
  while ((m = redirect.exec(cmd))) targets.push(m[1].replace(/^['"]|['"]$/g, ""));
  const inplace = /(^|[\s;|&(])(sed\s+(-[^\s]*\s+)*-i|perl\s+(-[^\s]*\s+)*-p?i|tee\b)/.test(cmd);
  const bad = targets.filter((t) => t !== "/dev/null" && !allowed(t));
  if (!inplace && !bad.length) process.exit(0);
  path = bad[0] || "(in-place edit)";
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
