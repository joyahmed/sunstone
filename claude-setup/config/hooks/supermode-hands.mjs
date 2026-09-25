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
// The deny is not a wall: the way past it is to SPAWN AN AGENT, which is the
// thing the mode exists to make happen. `touch ~/.claude/ctx/<sid>.hands` (or
// SUPERMODE_HANDS=1) takes the wheel back for the rest of the session when an
// agent genuinely cannot be spawned - but it is the fallback, not the answer, and
// it is not always available: a permission classifier in auto mode has refused
// that very touch as a bypass flag. So the deny message leads with delegation and
// mentions the marker second. The point of the marker is that taking the wheel
// becomes a DECISION with a command behind it, instead of a drift nobody notices.
//
// Silent on every failure: a guard that crashes must not block the work.
//
// ⛔ HOW TO TELL WHETHER THIS GUARD IS ENFORCING - read the log, do not probe.
// The guard falls open on FIVE separate conditions (supermode off, no transcript
// in the payload, a transcript that is not the parent session's, the six-denial
// breaker tripped, the `.hands` escape present), so running a deliberately-bad
// command and watching it succeed proves NOTHING: an inert hook and a hook that
// fell through look identical from the outside. That conflation shipped once in a
// probe recipe and a peer caught it.
//
// So every invocation appends one line to ~/.claude/ctx/<sid>.handslog:
//     <iso> tool=Bash decision=allow reason=supermode-off target=-
// No line for this session => the hook never ran (not installed, not wired to
// this tool, or the snapshot predates it). A line with decision=allow => it ran
// and fell through, and `reason=` names which of the five paths it took. The
// command text is never logged - an argument can hold a secret - only the tool,
// the decision, a stable reason token and the single offending path, which is
// already in the deny message anyway.
//
// Gating: the log is written whenever the ctx directory already EXISTS, with no
// env var to remember. That directory is created by the supermode launcher, so on
// a machine that has never run supermode there is nothing to write to and the
// logging costs one existsSync; on a machine that has, the log is the answer to
// the question every session eventually asks. It self-rotates past ~512 KB so an
// always-on append cannot grow without bound, and every part of it is wrapped so
// a read-only home or a full disk cannot stop the guard returning its decision.
import { appendFileSync, existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
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

// One line per invocation, so "inert" and "fell open" are distinguishable. See
// the header. Every step is inside the try: logging is a courtesy, the decision
// is the contract.
const LOG_MAX = 512 * 1024;
const note = (decision, reason, target) => {
  try {
    if (!sid || !existsSync(ctx)) return;
    const f = resolve(ctx, `${sid}.handslog`);
    try { if (statSync(f).size > LOG_MAX) writeFileSync(f, ""); } catch { /* no file yet */ }
    appendFileSync(f, `${new Date().toISOString()} tool=${String(input.tool_name || "-").replace(/\s+/g, "_")}` +
      ` decision=${decision} reason=${reason} target=${target ? String(target).replace(/\s+/g, "_") : "-"}\n`);
  } catch { /* a read-only home must not break the guard */ }
};
const fallOpen = (reason, target) => { note("allow", reason, target); process.exit(0); };

const on = process.env.SUPERMODE === "1" || (sid && existsSync(resolve(ctx, `${sid}.sm`)));
if (!on) fallOpen("supermode-off");
// The wheel, taken back deliberately.
if (process.env.SUPERMODE_HANDS === "1" || (sid && existsSync(resolve(ctx, `${sid}.hands`)))) fallOpen("hands-escape");

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
if (!parentTranscript) fallOpen("not-parent-transcript");

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
  fallOpen("breaker-tripped");
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
  if (allowed(path)) fallOpen("allowlisted", path);
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
  // so both are removed before looking for operators. `forOps` - quotes emptied,
  // contents gone - is what makes `git commit -m "a -> b"` work, so the redirect
  // scan must keep using it.
  const stripHeredocs = (t) =>
    t.replace(/<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1[\s\S]*?(?:\n[ \t]*\2[ \t]*(?:\n|$)|$)/g, " ");
  const base = stripHeredocs(cmd);
  const forOps = base.replace(/'[^']*'/g, " '' ").replace(/"(?:[^"\\]|\\.)*"/g, ' "" ');

  const targets = [];
  let m;
  const redirect = /(?<![0-9<>])>>?\s*([^\s;|&)]+)/g;
  while ((m = redirect.exec(forOps))) targets.push(m[1]);

  // ⛔ THE WRITER'S ARGUMENTS MUST BE TOKENIZED QUOTE-AWARE, not read off a
  // quote-stripped copy of the line. The first version peeled the quotes and
  // then split on whitespace, so a sed script with a SPACE in it fell apart into
  // words and every word after the first was taken for a filename:
  //     sed -i 's/^- GATE: `bash -n` OK\./.../' claude-setup/memory/<note>.md
  // was denied with the target named as `GATE:` - a false deny on a path that is
  // squarely allowlisted. Reported live from another machine, 2026-09-25.
  //
  // So a quoted argument is ONE token, and its value is the quote-STRIPPED
  // contents, which is what keeps `tee "src/out.ts"` a deny. The lexer returns
  // null on an unbalanced quote: ambiguous tokenizing means no targets, which
  // means ALLOW. Fail open, always - see the ceiling note below.
  const SEP = Symbol("sep");
  const lex = (s) => {
    const out = [];
    let cur = null;
    const push = () => { if (cur) out.push(cur); cur = null; };
    const add = (txt, quoted) => { cur = cur || { v: "", q: false }; cur.v += txt; if (quoted) cur.q = true; };
    for (let i = 0; i < s.length; i++) {
      const c = s[i];
      if (c === "'") {                                   // literal to the next quote
        const j = s.indexOf("'", i + 1);
        if (j < 0) return null;
        add(s.slice(i + 1, j), true); i = j; continue;
      }
      if (c === '"') {                                   // same, honouring backslash escapes
        let j = i + 1, v = "";
        for (; j < s.length && s[j] !== '"'; j++) { if (s[j] === "\\" && j + 1 < s.length) j++; v += s[j]; }
        if (j >= s.length) return null;
        add(v, true); i = j; continue;
      }
      if (c === "\\") { if (i + 1 < s.length) add(s[++i], true); continue; }
      if (/\s/.test(c) && c !== "\n") { push(); continue; }
      if (c === "\n" || c === ";" || c === "|" || c === "&" || c === "(" || c === ")" || c === "`") {
        push(); out.push(SEP); continue;                 // a new simple command starts here
      }
      if (c === "<" || c === ">") {
        // A redirect ends the argument list as far as THIS scan cares: its target
        // is the redirect scanner's job above, and stopping early can only yield
        // FEWER targets, which is the fail-open direction.
        if (cur && !cur.q && /^[0-9]+$/.test(cur.v)) cur = null;   // the fd of `2>`
        push(); out.push(SEP);
        while (i + 1 < s.length && (s[i + 1] === ">" || s[i + 1] === "&")) i++;
        continue;
      }
      add(c, false);
    }
    push();
    return out;
  };

  // `tee`, `sed -i`, `perl -pi`, `dd of=` write the files they are GIVEN - so
  // read the files they are given, rather than denying the command for existing.
  const writerTargets = (rest, kind) => {
    const out = [];
    let skipNext = false, scriptSeen = kind !== "sed";  // sed's first bare arg is its script
    for (const t of rest) {
      if (skipNext) { skipNext = false; scriptSeen = true; continue; }
      if (/^-/.test(t.v)) { if (/^(-e|-E|--expression|-f|--file)$/.test(t.v)) skipNext = true; continue; }
      if (!scriptSeen) { scriptSeen = true; continue; }
      out.push(t.v);
    }
    return out;
  };

  // Commands that only carry another command; the writer may be behind one.
  const WRAP = /^(sudo|doas|env|command|time|nohup|stdbuf|xargs|nice|ionice)$/;
  const toks = lex(base);
  for (const seg of (toks || []).reduce((acc, t) => {
    if (t === SEP) { if (acc[acc.length - 1].length) acc.push([]); } else acc[acc.length - 1].push(t);
    return acc;
  }, [[]])) {
    let k = 0, wrapped = false;
    while (k < seg.length) {                             // find the real command name
      const v = seg[k].v;
      if (WRAP.test(v) || /^[A-Za-z_][A-Za-z0-9_]*=/.test(v)) { k++; wrapped = true; continue; }
      if (wrapped && /^-/.test(v)) { k++; continue; }     // the wrapper's own flags
      break;
    }
    if (k >= seg.length) continue;
    const name = seg[k].v.replace(/^.*\//, "");          // /usr/bin/sed -> sed
    const rest = seg.slice(k + 1);
    const flagged = (re) => rest.some((t) => re.test(t.v));
    // ⚠️ The `-i` test must allow the flag anywhere in the flags, first included.
    // An earlier lookahead required `\s-i`, so `sed -i 's/a/b/' src/app.ts` - the
    // commonest form there is - matched nothing and sailed through.
    let kind = null;
    if (name === "tee") kind = "tee";
    else if (name === "sed" && flagged(/^(-[a-zA-Z]*i|--in-place)/)) kind = "sed";
    else if (name === "perl" && flagged(/^-[a-zA-Z]*i/)) kind = "perl";
    else if (name === "dd") kind = "dd";
    if (!kind) continue;
    if (kind === "dd") {                                 // the target rides on a flag
      for (const t of rest) { const d = /^of=(.+)$/.exec(t.v); if (d) targets.push(d[1]); }
      continue;
    }
    targets.push(...writerTargets(rest, kind));
  }

  // ⛔ THE CEILING, stated so nobody mistakes this for a boundary: an
  // interpreter can always write a file, and no text scan can see it without
  // running the code - `python3 -c 'open("src/x.ts","w")'` goes through, and so
  // does a redirect written INSIDE an awk or perl program, because stripping
  // quotes is exactly what makes `git commit -m "a -> b"` work. Those are false
  // ALLOWS on a guard that already fails open by design: the mode leaks a
  // little, nothing breaks. A false DENY is the expensive direction - it blocks
  // real work and burns one of the six the breaker allows. This is a nudge
  // against absent-minded editing with a one-command escape hatch, not a
  // sandbox, and hardening it into one would cost the thing that makes it safe.
  const bad = targets.filter((t) => t !== "/dev/null" && !/^\/dev\//.test(t) && !allowed(t));
  // nothing written, or everything written is the orchestrator's own
  if (!bad.length) fallOpen(targets.length ? "allowlisted" : "no-write-target",
    targets.find((t) => !/^\/dev\//.test(t)) || targets[0]);
  path = bad[0];
} else {
  fallOpen("not-an-edit-tool");
}

const reason =
  `supermode: you are the orchestrator, so this edit is not yours to make. ` +
  `Spawn an Agent (Agent tool) for the slice that touches ${path} and let it do the editing - ` +
  `its context is spent instead of this session's, which is the whole reason the mode exists. ` +
  `Give the agent the verified facts you already hold (exact paths, the gate command, what "done" is) ` +
  `so it does not rediscover them, and keep its slice small enough to finish under 60% of its window ` +
  `(\`node ~/.claude/hooks/agent-watch.mjs --report\` shows where each one stands). ` +
  `The handoff note, the queue row, the gate and the commit stay yours. ` +
  `Delegating is the way out of this deny - not an alternative to it. ` +
  `If an agent truly cannot do it and your permission layer allows the command, ` +
  `\`touch ${resolve(ctx, `${sid || "<session-id>"}.hands`)}\` takes the wheel for the rest of the session; ` +
  `say in one line why, then repeat the edit. Some setups refuse that touch - then delegate.`;

note("deny", "denied", path);
try { writeFileSync(denyLog, String(denies + 1) + "\n"); } catch { /* the breaker is a courtesy */ }

process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: reason,
  },
}) + "\n");
