#!/usr/bin/env node
// supermode-hands - the guard that notices when the orchestrator's hands are on
// the work. A PreToolUse hook on the editing tools. Pure Node.js, no shell.
//
// Supermode's bargain is that the SESSION spends no context on the work: it reads
// the queue, decides the slice, spawns an agent, gates, commits, hands off. The
// failure mode is not dramatic - the session just starts doing the slice itself,
// "because it is small", and twenty of those later the window is full and the mode
// has quietly become an ordinary session with extra ceremony.
//
// ⚠️ IT WARNS. IT DOES NOT DENY. The reasoning is worth keeping, because it is
// what makes this file safe to leave running:
//
//   * The drift this guard was built against had a specific cause, and that cause
//     has since been fixed elsewhere: the supermode contract used to be injected
//     once and decay about twenty turns later. The trigger now re-injects it on
//     EVERY prompt, so the model is reminded by the thing designed to remind it.
//   * A deny can never be complete. Any interpreter can write a file; no text scan
//     sees it without running the code. So the wall was always a fence with a gate
//     in it, and hardening it would cost more than it bought.
//   * The asymmetry decides it. A missed catch costs "the orchestrator did a little
//     work itself". A false positive costs the mode DISABLING ITSELF in the middle
//     of an unattended run - and the deny mechanism was wrong three separate ways
//     in one night (arrows in commit messages, variables in paths, subagents read
//     as the orchestrator). Cheap failure on one side, expensive on the other.
//
// So while supermode is on (~/.claude/ctx/<sid>.sm, or SUPERMODE=1), a write by the
// ORCHESTRATOR to a path that is not the orchestrator's own business gets a warning
// attached to the tool call - `systemMessage` for the user, `additionalContext`
// for the model - and the call proceeds through the ordinary permission flow.
// The orchestrator's own business is:
//   * the handoff and the queue:  docs/ai-memory/**, session-<date>.md, WORK-QUEUE,
//     HANDOFF, MEMORY.md, ABOUT-*.md, any *.md under a docs/ tree
//   * the scratchpad (including the one named in the hook payload) and the gauges
// and the same rule is applied to the Bash commands that are really edits (`sed -i`,
// `perl -pi`, `tee`, `dd of=`, a `>` redirect). Bash is otherwise untouched: the
// gate, git and the launcher are the orchestrator's own job and must stay central.
//
// ⛔ A SUBAGENT IS NOT THE ORCHESTRATOR, and telling one otherwise is the bug this
// guard existed to prevent, inverted. Agents inherit these hooks, and a subagent's
// tool call arrives with the PARENT session's session_id AND the PARENT session's
// transcript_path - so the old "is this the parent's transcript?" test passed for
// every subagent and the guard warned the exact actor it exists to produce. The
// harness ships the right field and says so in its own schema:
//
//     agent_id - "Present only when the hook fires from within a subagent ...
//     Absent for the main thread, even in --agent sessions. Use this field (not
//     agent_type) to distinguish subagent calls from main-thread calls."
//
// `agent_id` present => not the orchestrator => silent, logged as reason=subagent.
// The transcript-shape test stays as a second, weaker guard for payloads that
// predate the field. Verified live, 2026-09-25: a subagent editing a hook file was
// told "you are the orchestrator, so this edit is not yours to make - delegate".
// It WAS the delegate.
//
// ⛔ AND THE WARNING NEVER HANDS OUT THE ESCAPE AS A PASTEABLE COMMAND. The old
// deny message ended with `touch ~/.claude/ctx/<sid>.hands` spelled out in full -
// and because of the misclassification above, the sid it printed was the PARENT's.
// A subagent that followed the hook's own advice would have taken the wheel away
// from the session that spawned it, for the rest of the run, silently. Taking the
// wheel is the orchestrator's deliberate act, documented in the supermode command;
// it is named here, not spelled out, and never to a caller identified as a subagent.
//
// Silent on every failure: a guard that crashes must not get in the way.
//
// ⛔ HOW TO TELL WHETHER THIS GUARD IS RUNNING - read the log, do not probe.
// It stays silent on many conditions (supermode off, a subagent, no transcript in
// the payload, a transcript that is not the parent session's, the `.hands` escape,
// an allowlisted target, a target it cannot resolve), so watching a deliberately-bad
// command succeed proves NOTHING - it succeeds either way now. Every invocation
// appends one line to ~/.claude/ctx/<sid>.handslog:
//     <iso> tool=Bash decision=allow reason=supermode-off target=-
// No line for this session => the hook never ran (not installed, not wired to this
// tool, or the snapshot predates it). `reason=` names which path it took, and
// `decision=warn reason=warned` is a place the orchestrator drifted - which, with
// nothing being blocked any more, is the whole visible product of this file. The
// command text is never logged - an argument can hold a secret - only the tool, the
// decision, a stable reason token and the single offending path.
//
// ⛔ THERE IS NO BREAKER ANY MORE. There used to be one: six denials in a session
// and the guard disengaged itself, on the theory that a tool nobody can leave
// running unattended is worse than a leaky one. That theory was right about a DENY
// and is exactly backwards for a warning - a warning blocks nothing, so there is
// nothing to break, and a counter that silently switches the warning off is the
// self-disabling failure this whole change is meant to remove. If a counter is ever
// added back, it must never turn the warning off.
//
// Gating: the log is written whenever the ctx directory already EXISTS, with no env
// var to remember. That directory is created by the supermode launcher. It
// self-rotates past ~512 KB, and every part of it is wrapped so a read-only home or
// a full disk cannot stop the guard returning.
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

// One line per invocation, so "inert" and "fell through" are distinguishable. See
// the header. Every step is inside the try: logging is a courtesy, the decision is
// the contract.
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
const quiet = (reason, target) => { note("allow", reason, target); process.exit(0); };

const on = process.env.SUPERMODE === "1" || (sid && existsSync(resolve(ctx, `${sid}.sm`)));
if (!on) quiet("supermode-off");
// The wheel, taken back deliberately by the orchestrator.
if (process.env.SUPERMODE_HANDS === "1" || (sid && existsSync(resolve(ctx, `${sid}.hands`)))) quiet("hands-escape");

// The one authoritative "this is not the orchestrator" signal - see the header.
const isSubagent = typeof input.agent_id === "string" && input.agent_id !== "";
if (isSubagent) quiet("subagent");

// Second, weaker test, for a payload with no agent_id at all: the orchestrator's
// transcript is the session's own file, <...>/<session-id>.jsonl. Anything shaped
// otherwise is a layout this hook has not seen, and it is left alone. Note this
// test canNOT see a subagent on a current harness - a subagent is handed the
// PARENT's transcript_path - which is why agent_id is checked first and this is a
// backstop, not the mechanism.
const transcript = String(input.transcript_path || "").replace(/\\/g, "/");
const parentTranscript = sid && transcript.endsWith(`/${sid}.jsonl`) && !transcript.includes("/subagents/");
if (!parentTranscript) quiet("not-parent-transcript");

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
// The harness names this session's scratchpad in the payload; it is the
// orchestrator's own by definition, whatever it is called on this machine.
const scratch = typeof input.scratchpad_dir === "string" ? input.scratchpad_dir.replace(/\\/g, "/") : "";
const allowed = (p) => {
  if (!p) return true;
  const s = String(p).replace(/\\/g, "/");
  if (scratch && (s === scratch || s.startsWith(scratch.replace(/\/$/, "") + "/"))) return true;
  return ALLOW.some((re) => re.test(s));
};

// ⛔ VARIABLES IN A WRITE TARGET. `echo x > "$D/out.sh"` used to be reported as a
// write to the literal string `$D/out.sh` - or, when the target was quoted, to the
// empty string, and the message read `the slice that touches ""`. Both were denies
// on paths the guard could not even name, and the second one cost a real
// verification step: an agent could not build a throwaway copy of a script.
//
// The rule now: RESOLVE what can honestly be resolved - this process's environment
// and any NAME=value assignment in the same command line - and judge the result.
// What cannot be resolved is not guessed at: no target, no warning, and a reason
// token in the log so the fall-through is visible rather than invisible. An empty
// result is likewise not a source file. Command substitution is never resolved,
// because resolving it means RUNNING it, and a guard does not run the command it
// is inspecting.
const localVars = Object.create(null);
const VAR = /\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/g;
const expand = (t) => {
  if (!/[$`]/.test(t)) return { ok: true, v: t };
  if (/\$\(|`/.test(t)) return { ok: false, why: "unresolvable-target" };   // never execute it
  let missing = false;
  const v = t.replace(VAR, (_m, braced, bare) => {
    const n = braced || bare;
    if (n in localVars) return localVars[n];
    if (typeof process.env[n] === "string") return process.env[n];
    missing = true;                                   // $UNSET expands to "" in the
    return "";                                        // shell, but this hook cannot
  });                                                 // know the shell's env - so
  if (missing || /[$`]/.test(v)) return { ok: false, why: "unresolvable-target" };
  return { ok: true, v };
};

let path = null;      // the offending target, once there is one
let how = "";         // where it came from, so the warning can say why

if (tool === "Edit" || tool === "Write" || tool === "NotebookEdit") {
  path = args.file_path || args.notebook_path || "";
  how = `the ${tool} tool's target file`;
  if (allowed(path)) quiet("allowlisted", path);
} else if (tool === "Bash") {
  const cmd = String(args.command || "");
  // Only the forms that WRITE a file. A redirect into /dev/null, into the
  // scratchpad or into an allowlisted note is not an edit of the work.
  //
  // ⛔ SCAN THE SHELL SYNTAX, NOT THE TEXT. The first version matched `>` and `tee`
  // anywhere in the string, which flagged the orchestrator's own work:
  //     git commit -m "slice 2 -> gate passed"    the arrow is PROSE
  //     git log --format="%h => %s"               so is this one
  // Commits are the one thing the contract promises stay the orchestrator's. A
  // heredoc body is data and a redirect operator cannot appear inside quotes, so
  // heredocs are stripped and the rest is LEXED quote-aware - never regex-scanned
  // over a quote-stripped copy, which is how `> "docs/ai-memory/note.md"` came out
  // as the empty string.
  const stripHeredocs = (t) =>
    t.replace(/<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1[\s\S]*?(?:\n[ \t]*\2[ \t]*(?:\n|$)|$)/g, " ");
  const base = stripHeredocs(cmd);

  // ⛔ THE WRITER'S ARGUMENTS MUST BE TOKENIZED QUOTE-AWARE. An earlier version
  // peeled the quotes and split on whitespace, so a sed script with a SPACE in it
  // fell apart into words and every word after the first was taken for a filename:
  //     sed -i 's/^- GATE: `bash -n` OK\./.../' claude-setup/memory/<note>.md
  // was reported against `GATE:`. So a quoted argument is ONE token and its value
  // is the quote-STRIPPED contents, which is what keeps `tee "src/out.ts"` caught.
  // The lexer returns null on an unbalanced quote: ambiguous tokenizing means no
  // targets, which means silence. Fail quiet, always.
  const SEP = Symbol("sep");
  const lex = (s) => {
    const out = [];
    const redirects = [];
    let cur = null, wantsFile = false;
    const push = () => {
      if (cur) { if (wantsFile) { redirects.push(cur); wantsFile = false; } out.push(cur); }
      cur = null;
    };
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
      // A `#` that starts a word starts a COMMENT, and a comment is prose. Found
      // 2026-09-25 by a probe script whose own comment line - `# <hook> <cmd>` -
      // was read as a redirect into a file called `<cmd>`, and refused.
      if (c === "#" && !cur) { while (i + 1 < s.length && s[i + 1] !== "\n") i++; continue; }
      if (/\s/.test(c) && c !== "\n") { push(); continue; }
      if (c === "\n" || c === ";" || c === "|" || c === "&" || c === "(" || c === ")" || c === "`") {
        push(); wantsFile = false; out.push(SEP); continue;   // a new simple command starts here
      }
      if (c === "<" || c === ">") {
        const writes = c === ">";
        if (cur && !cur.q && /^[0-9]+$/.test(cur.v)) cur = null;   // the fd of `2>`
        push(); out.push(SEP);
        let j = i;
        if (s[j + 1] === ">") j++;                       // `>>`
        let dup = false;
        if (s[j + 1] === "&") {                          // `2>&1` duplicates an fd,
          dup = true; j++;                               // it does not open a file
          while (j + 1 < s.length && /[0-9-]/.test(s[j + 1])) j++;
        }
        i = j;
        if (writes && !dup) wantsFile = true;            // the NEXT token is the file
        continue;
      }
      add(c, false);
    }
    push();
    return { out, redirects };
  };

  const lexed = lex(base);
  if (!lexed) quiet("unlexable");
  const { out: toks, redirects } = lexed;

  // `D=/tmp/x; ... > $D/f` is one command line, so its own assignments are the
  // first place to look a variable up.
  for (const t of toks) {
    if (t === SEP) continue;
    const a = /^([A-Za-z_][A-Za-z0-9_]*)=([\s\S]*)$/.exec(t.v);
    if (!a) continue;
    const e = expand(a[2]);
    if (e.ok) localVars[a[1]] = e.v;
  }

  const raw = redirects.map((t) => ({ v: t.v, how: "a `>` redirect" }));

  // `tee`, `sed -i`, `perl -pi`, `dd of=` write the files they are GIVEN - so read
  // the files they are given, rather than flagging the command for existing.
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
  for (const seg of toks.reduce((acc, t) => {
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
      for (const t of rest) { const d = /^of=([\s\S]+)$/.exec(t.v); if (d) raw.push({ v: d[1], how: "the `of=` argument to `dd`" }); }
      continue;
    }
    const label = kind === "sed" ? "an argument to `sed -i`" : kind === "perl" ? "an argument to `perl -pi`" : "an argument to `tee`";
    for (const v of writerTargets(rest, kind)) raw.push({ v, how: label });
  }

  // ⛔ THE CEILING, stated so nobody mistakes this for a boundary: an interpreter
  // can always write a file, and no text scan can see it without running the code -
  // `python3 -c 'open("src/x.ts","w")'` goes through, and so does a redirect written
  // INSIDE an awk or perl program, because a quoted string is data. Those are misses
  // on a guard that is now only a warning, so a miss costs a warning nobody got.
  // This is a nudge against absent-minded editing, not a sandbox.
  const bad = [];
  let sawTarget = false, unresolved = null;
  for (const t of raw) {
    const e = expand(t.v);
    if (!e.ok) { unresolved = unresolved || { why: e.why, v: t.v }; continue; }   // logged, never warned
    const v = e.v.trim();
    if (!v) { unresolved = unresolved || { why: "empty-target", v: t.v }; continue; }
    if (v === "/dev/null" || /^\/dev\//.test(v)) { sawTarget = true; continue; }
    sawTarget = true;
    if (!allowed(v)) bad.push({ ...t, v });
  }
  if (!bad.length) {
    if (unresolved) quiet(unresolved.why, unresolved.v);
    quiet(sawTarget ? "allowlisted" : "no-write-target", raw.length ? raw[0].v : null);
  }
  path = bad[0].v;
  how = bad[0].how;
} else {
  quiet("not-an-edit-tool");
}

// ⛔ SPECIFIC, OR IT IS NOISE. Name the file, name where the write was seen, and
// name why that path is not the orchestrator's - a generic "you should be
// orchestrating" is the kind of warning people learn to scroll past.
const warning =
  `supermode drift check (a warning - nothing is blocked, the tool call proceeds). ` +
  `This session is the orchestrator, and ${how} is \`${path}\`, which is not one of the ` +
  `paths the orchestrator owns (the handoff note and docs/ai-memory/**, the work queue, ` +
  `MEMORY.md and ABOUT-*.md, claude-setup/memory/**, the scratchpad and ~/.claude/ctx). ` +
  `That makes it slice work, and slice work belongs to an Agent: its context is spent ` +
  `instead of this session's, which is the whole reason the mode exists. ` +
  `If you have not already delegated this, spawn an Agent (Agent tool) for the slice that ` +
  `touches \`${path}\`, hand it the verified facts you already hold (exact paths, the gate ` +
  `command, what "done" is) so it does not rediscover them, and keep its slice small enough ` +
  `to finish under 60% of its window (\`node ~/.claude/hooks/agent-watch.mjs --report\` ` +
  `shows where each one stands). The handoff note, the queue row, the gate and the commit ` +
  `stay yours. If you are deliberately taking the wheel for the rest of the session, the ` +
  `\`.hands\` marker described in the supermode command silences this - say in one line why, ` +
  `and do it as a decision rather than by drifting into it.`;

note("warn", "warned", path);

process.stdout.write(JSON.stringify({
  systemMessage: `supermode: the orchestrator is writing \`${path}\` itself (warning only - this is slice work an Agent should own).`,
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: warning,
  },
}) + "\n");
