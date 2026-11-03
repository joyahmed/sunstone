#!/usr/bin/env node
// guard-secrets - a PreToolUse hook on Bash|Read|Grep. It refuses a tool call
// that would READ a secret file into the transcript: `cat .env`, `source
// .env.local`, `grep KEY .env`, the Read tool opening an SSH key. Once a value
// is in the transcript it is in the session log, the context window and
// whatever the session hands to an agent - the rule "secrets never in the
// transcript" (skill secrets-and-privacy) was advice only until this hook.
//
// Allowed on purpose:
//   - .env.example / .env.sample / .env.template - that is how a session learns
//     which keys exist.
//   - `env-check.sh KEY ...` as one plain call - it prints present/empty/missing
//     per key, never a value. No pipe, redirect or chain may ride along.
//   - writing the NAME into .gitignore (`echo .env >> .gitignore`).
//
// Ported from EricTechPro/super-board hooks/guard-secrets.py (MIT), in Node
// because python3 on a Windows box can be the Microsoft Store stub, and a hook
// that cannot launch says nothing.
//
// MODE: GUARD_SECRETS=off in the environment switches it off for one shell.
//
// FAILS SAFE. Bad JSON, anything unexpected: silence, the call proceeds.

import { readFileSync } from "node:fs";

const B = "(?:^|[^A-Za-z0-9._-])"; // boundary before a name
const E = "(?:[^A-Za-z0-9._-]|$)"; // boundary after a name
const SECRET_RE = new RegExp([
  B + "\\.env" + E,
  "\\.env\\.(?:local|production|prod|staging|development|dev|test)" + E,
  B + "id_(?:rsa|ed25519|ecdsa|dsa)" + E,
  B + "\\.npmrc" + E,
  B + "\\.git-credentials" + E,
  "\\.aws[/\\\\]credentials" + E,
  B + "credentials\\.json" + E,
  "service-account[A-Za-z0-9._-]*\\.json",
  "\\.pem" + E,
].join("|"));

// In a shell command the NAME alone is not a read: a commit message, a note
// written by `node -e`, or `git add .env.example` all mention it harmlessly.
// What reads it is a reading command aimed at it in the same pipeline segment
// (`cat .env`, `bash -c 'grep K .env'`), or a `<` redirect from it. Found the
// hard way: the first version refused a bus note that only mentioned ".env".
const READERS = [
  "cat", "less", "more", "head", "tail", "bat", "batcat", "nl", "tac", "source", "\\.",
  "grep", "egrep", "fgrep", "rg", "ag", "awk", "gawk", "sed", "cut", "sort", "uniq",
  "strings", "xxd", "od", "hexdump", "base64", "scp", "curl", "wget", "tee", "diff",
  "vi", "vim", "nvim", "nano", "xargs", "jq", "yq", "openssl", "gpg", "type", "Get-Content", "gc",
].join("|");
const READ_RE = new RegExp(
  "(?:^|[\\s;|&(`'\"])(?:" + READERS + ")(?=\\s)[^|;&\\n]*?(?:" + SECRET_RE.source + ")" +
  "|<\\s*\\S*?(?:" + SECRET_RE.source + ")");

const ENV_CHECK =/^\s*(?:bash\s+|sh\s+)?(?:\S*\/)?env-check\.sh(?:\s+[A-Za-z0-9_.\/=-]+)*\s*$/;
// `echo .env >> .gitignore` (or printf) touches the name, never the contents.
const GITIGNORE_ONLY = /^\s*(?:echo|printf)\s+[^|;&<`$]*>>?\s*\S*\.(?:git|docker)ignore\s*$/;

const REASON =
  "Blocked by guard-secrets: this would read a secret file into the transcript. " +
  "For key NAMES read .env.example; to ask whether a key is set run " +
  "`bash ~/.claude/hooks/env-check.sh KEY ...` (prints present/empty/missing, never a value); " +
  "or ask the user to run the command themselves with the ! prefix.";

function subject(input) {
  const t = String(input.tool_name || "");
  const a = input.tool_input || {};
  if (t === "Bash") return String(a.command || "");
  if (t === "Read") return String(a.file_path || "");
  if (t === "Grep") return [a.path, a.glob].map((v) => String(v || "")).join(" ");
  return "";
}

function main() {
  if (String(process.env.GUARD_SECRETS || "").toLowerCase() === "off") return;
  let input = {};
  try { input = JSON.parse(readFileSync(0, "utf8") || "{}"); } catch { return; }
  const text = subject(input);
  if (!text) return;
  if (input.tool_name === "Bash" && (ENV_CHECK.test(text) || GITIGNORE_ONLY.test(text))) return;
  if (!(input.tool_name === "Bash" ? READ_RE : SECRET_RE).test(text)) return;
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: REASON,
    },
  }));
}

try { main(); } catch { /* fail open */ }
