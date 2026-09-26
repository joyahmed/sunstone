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
// ⚠️ IT WATCHES TWO VERBS. Writing (below) and READING - see "THE SECOND VERB"
// further down: an orchestrator that never edits a file can still burn its whole
// window on `cat`, `grep` and `Read`, so read-shaped calls are counted and an
// `Agent` spawn resets the count.
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
// ⛔ THE SECOND VERB. A write is not the only way an orchestrator does the work
// itself, and it is not even the common one. This guard watched `Edit`, `Write`
// and the Bash forms that write a file - and an orchestrator's window is emptied
// by READING: `cat`, `sed -n`, `grep`, `find`, `Read`, `Glob`, and command output
// generally. So a session could obey the contract perfectly, never edit one file,
// and still spend its whole window on investigation an agent was supposed to pay
// for. The guard was silent throughout, because none of it was a write.
//
// So there is a second counter here, and it is a NUDGE, not a block. Blocking
// reads would make the mode unusable: the orchestrator legitimately reads the
// queue, the handoff note, gate output and its agents' reports. Instead:
//
//   * every read-shaped tool call by the ORCHESTRATOR increments
//     ~/.claude/ctx/<sid>.reads  ({"n":<count>,"band":<last nudged band>})
//   * an `Agent` call - the observable, authoritative signal that this session is
//     delegating - resets it to zero
//   * crossing a band of READ_NUDGE_AT (default 8) with no intervening spawn emits
//     ONE message naming the count and what to hand over, then stays quiet until
//     the next band, exactly the way context-guard.mjs bands its 5% notices. A
//     nudge that fires every call gets muted, and a muted nudge is worse than none.
//
// Why 8: reading the queue row, the handoff note and one gate output is three to
// six calls, and that IS the orchestrator's own business. Eight is the first count
// that cannot be explained by the orchestrator's own business, and repeating every
// eight keeps the reminder proportional to the drift.
//
// ⚠️ Scope, honestly stated: `git` is never counted (the commit, the log and the
// gate are the orchestrator's by contract), and neither is any `mcp__*` tool - the
// sandboxed-analysis tools are the SANCTIONED way to look at bulk data, and
// counting them would argue against the very habit this nudge wants. The Bash test
// is a scan for a reader at command position over a stripped copy of the line:
// cheap, and a false count costs one tick of a counter, never a block.
const rnEnv = parseInt(process.env.SUPERMODE_READ_NUDGE ?? "", 10);
const READ_NUDGE_AT = Number.isFinite(rnEnv) ? Math.max(0, rnEnv) : 8;   // 0 disables
const READ_TOOLS = /^(Read|Glob|Grep|NotebookRead|WebFetch|WebSearch)$/;
const SPAWN_TOOLS = /^(Agent|Task)$/;
// Commands whose output lands in the window. Deliberately NOT here: git, the
// package managers and test runners (the gate), and anything that mutates.
const READERS = /^(cat|bat|head|tail|sed|awk|grep|egrep|fgrep|rg|ag|ack|find|fd|fdfind|ls|tree|wc|nl|jq|yq|less|more|od|xxd|strings|diff|column|readlink|realpath|du)$/;
const WRAPPERS = /^(sudo|doas|env|command|time|nohup|stdbuf|xargs|nice|ionice)$/;

// A reader at command position, on a copy with heredoc bodies, quoted spans and
// `#` comments removed - so `git commit -m "fix; cat handling"` is a commit, not a
// read, and a reader NAMED in a comment is prose, not a call.
//
// ⚠️ THE ORDER IS THE WHOLE TRICK, and a naive `s/#.*//` breaks both halves of it.
// Quotes and heredoc bodies go first, so a `#` inside a string or a message body is
// already gone before comments are considered - which is what keeps a commit
// message a commit. Then the comment strip fires only on a `#` that STARTS a word
// (line start, whitespace, or one of the operators that also separate commands),
// because mid-word `#` is an ordinary character in a shell: `file#1` is a filename.
// The separator is put back, since it is also what splits the segments below.
const bashReads = (cmd) => {
  const plain = String(cmd || "")
    .replace(/<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1[\s\S]*?(?:\n[ \t]*\2[ \t]*(?:\n|$)|$)/g, " ")
    .replace(/'[^']*'/g, " ").replace(/"(?:[^"\\]|\\[\s\S])*"/g, " ")
    .replace(/(^|[\s;|&()])#[^\n]*/g, "$1 ");
  for (const seg of plain.split(/(?:\|\||&&|[;|&\n()])+/)) {
    const toks = seg.trim().split(/\s+/).filter(Boolean);
    let k = 0;
    while (k < toks.length && (WRAPPERS.test(toks[k]) || /^[A-Za-z_][A-Za-z0-9_]*=/.test(toks[k]))) k++;
    if (k >= toks.length) continue;
    const name = toks[k].replace(/^.*\//, "");
    if (!READERS.test(name)) continue;
    // an in-place edit is a WRITE; the branch above owns it, this must not double-count
    if (/^(sed|perl)$/.test(name) && toks.slice(k + 1).some((t) => /^-[a-zA-Z]*i/.test(t))) continue;
    return true;
  }
  return false;
};

// Set once the caller is known to be the orchestrator (see the checks below), so
// that supermode-off, the `.hands` escape and subagents count nothing.
let counting = false;

// Called on every quiet exit. Returns nothing; may write the one nudge itself,
// synchronously (writeFileSync on fd 1 - process.exit can truncate an async
// stdout write, and a half-written JSON object is a hook the harness cannot read).
function readNudge() {
  if (!counting || !READ_NUDGE_AT || !sid) return;
  let f;
  try { if (!existsSync(ctx)) return; f = resolve(ctx, `${sid}.reads`); } catch { return; }
  const tool = String(input.tool_name || "");

  // A spawn is the signal that this session is delegating. Reset, say nothing.
  if (SPAWN_TOOLS.test(tool)) {
    let seenSpawns = 0;
    try {
      const a = JSON.parse(readFileSync(resolve(ctx, `${sid}.agents.json`), "utf8") || "{}");
      if (Number.isFinite(a.total)) seenSpawns = a.total | 0;
    } catch { /* the watcher may not be running */ }
    try { writeFileSync(f, JSON.stringify({ n: 0, band: 0, spawned: seenSpawns }) + "\n"); } catch { /* read-only home */ }
    note("allow", "spawn-reset", tool);
    return;
  }
  const isRead = READ_TOOLS.test(tool) || (tool === "Bash" && bashReads((input.tool_input || {}).command));
  if (!isRead) return;

  let n = 0, seen = 0, spawned = 0;
  try {
    if (existsSync(f)) {
      const p = JSON.parse(readFileSync(f, "utf8") || "{}");
      if (Number.isFinite(p.n)) n = p.n | 0;
      if (Number.isFinite(p.band)) seen = p.band | 0;
      if (Number.isFinite(p.spawned)) spawned = p.spawned | 0;
    }
  } catch { /* corrupt or unreadable: start over rather than throw */ }

  // ⛔ THE SPAWN SIGNAL MUST NOT DEPEND ON THIS HOOK SEEING THE `Agent` TOOL.
  // Whether it does is a settings question (the matcher), and a HALF-registered
  // guard is worse than none: reads counted, spawns invisible, counter never reset,
  // nudge firing forever until somebody mutes the hook. So there is a second,
  // independent signal that needs no matcher at all - agent-watch.mjs runs on EVERY
  // PostToolUse and writes <sid>.agents.json with `total`, the number of subagent
  // transcripts this session has, which only ever goes up. `total` higher than the
  // figure recorded at the last read = an agent was spawned since = delegating =
  // reset. The `Agent` branch above is the direct signal; this is the one that
  // holds when the direct one is not wired.
  let nowSpawned = spawned;
  try {
    const a = JSON.parse(readFileSync(resolve(ctx, `${sid}.agents.json`), "utf8") || "{}");
    if (Number.isFinite(a.total)) nowSpawned = a.total | 0;
  } catch { /* no watcher, no file: fall back to the Agent branch alone */ }
  if (nowSpawned > spawned) { n = 0; seen = 0; note("allow", "spawn-reset-observed", String(nowSpawned)); }

  n += 1;
  const band = Math.floor(n / READ_NUDGE_AT) * READ_NUDGE_AT;
  const due = band >= READ_NUDGE_AT && band > seen;
  try { writeFileSync(f, JSON.stringify({ n, band: due ? band : seen, spawned: nowSpawned }) + "\n"); } catch { /* still nudge */ }
  if (!due) { note("allow", "read-counted", String(n)); return; }

  note("nudge", "reads-nudge", String(n));
  const msg =
    `supermode delegation check (a warning - nothing is blocked, the tool call proceeds). ` +
    `This session has made ${n} read-shaped tool calls (Read/Grep/Glob/WebFetch, or a Bash ` +
    `\`cat\`/\`sed -n\`/\`grep\`/\`find\`) since it last spawned an Agent. Reading IS the work: ` +
    `every byte of it lands in THIS window, and protecting this window is the whole reason the ` +
    `mode exists - the Edit/Write guard cannot see any of it, so obeying that guard perfectly ` +
    `still empties the session. Name the question you are investigating and hand it to an Agent ` +
    `(Agent tool): give it the exact paths and the verified facts you already hold, and ask for ` +
    `the CONCLUSION, not the files. \`node ~/.claude/hooks/agent-watch.mjs --report\` shows where ` +
    `each agent stands. Reading the work queue, the handoff note, gate output and an agent's ` +
    `report is your own business and needs no agent; everything else does. This counter resets the ` +
    `moment you spawn one, and this notice repeats once per ${READ_NUDGE_AT} further reads.`;
  try {
    writeFileSync(1, JSON.stringify({
      systemMessage: `supermode: ${n} read-shaped calls with no Agent spawned - the orchestrator is investigating instead of delegating (warning only).`,
      hookSpecificOutput: { hookEventName: "PreToolUse", additionalContext: msg },
    }) + "\n");
  } catch { /* nothing to be done about a closed stdout */ }
}

const quiet = (reason, target) => { note("allow", reason, target); readNudge(); process.exit(0); };

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

// Past this line the caller is the orchestrator itself, so its reads are the reads
// the nudge above is counting.
counting = true;
// ⛔ ...but only for a session that EXISTS. The read counter is the one piece of
// STATE this guard keeps, and state keyed by a session id is only safe while that
// id names a live session. An invocation whose transcript is not on disk is a
// replay, a probe or a harness reusing one fixed id - and giving it a counter lets
// one run's band survive into the next run under that id, where the nudge then
// fires on reads the session never made: a warning on a call that deserved silence,
// which is the expensive direction for a guard nobody is watching. Everything else
// here is stateless and judges such a call identically; only the counting stops.
try { if (!existsSync(transcript)) counting = false; } catch { counting = false; }

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
