#!/usr/bin/env node
// Windows port of ~/.claude/statusline-command.sh, for hosts without jq:
// JSON parsing is done with node instead.
//
// It ports the same PAYLOAD, not the same rendering, and the difference is
// deliberate. The shell script paints a Nerd-Font, truecolor line — glyph +
// directory basename, git branch, model, context %, and each rate-limit window
// with the clock time it resets at. The hosts that need THIS file (PowerShell,
// cmd.exe, a stock Windows Terminal profile) frequently have neither a patched
// font to draw those glyphs nor a git on PATH to answer for the branch, so it
// paints a PS1-shaped line in plain ANSI instead:
//   user:cwd  model[ ↯]  ctx <used>/<size> (<pct>%)  5h <p>%  7d <p>%
// i.e. no glyphs, no branch, no reset times, and the context window spelled out
// in tokens as well as a percentage. Same numbers, different canvas — do not
// "fix" one of them to look like the other without deciding that on purpose.
//
// The model name drops its " (...)" suffix, and ↯ appears next to the model
// only while fast mode is ACTUALLY on.

const os = require("os");

let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => (raw += c));
process.stdin.on("end", () => {
  let d = {};
  try { d = JSON.parse(raw); } catch { d = {}; }

  const g = (path, def = undefined) => {
    let cur = d;
    for (const k of path.split(".")) {
      if (cur && typeof cur === "object" && k in cur) cur = cur[k];
      else return def;
    }
    return cur;
  };

  // --- PS1 base: user:cwd ---
  const user = process.env.USER || process.env.USERNAME || process.env.LOGNAME || "user";
  let cwd = g("cwd") || process.cwd();
  const home = os.homedir();

  // Normalize backslashes so the collapse logic works on Windows paths too.
  const norm = (p) => p.replace(/\\/g, "/");
  const cwdN = norm(cwd);
  const homeN = norm(home);
  if (cwdN === homeN) cwd = "~";
  else if (cwdN.startsWith(homeN + "/")) cwd = "~" + cwdN.slice(homeN.length);
  else cwd = cwdN;

  // That "~" is the ONLY abbreviation applied to the path, and it is derived
  // from the real home directory, so it is true on every machine. An earlier
  // version also deleted a literal "projects/" segment — ~/projects/<repo> was
  // shown as ~/<repo> — which reads nicely only if you happen to keep every
  // checkout in that one folder. For anyone who does not, it silently printed a
  // path that was not where they actually were, and a status line that lies
  // about the cwd is worse than a long one. Removed on purpose: if a shortening
  // is ever wanted back, derive it from the path itself (depth, width of the
  // terminal), never from a folder name someone is assumed to use.

  const chroot = process.env.debian_chroot;
  const prefix = chroot ? `(${chroot})` : "";

  const GREEN = "\x1b[01;32m", BLUE = "\x1b[01;34m", DIM = "\x1b[01;34m", RST = "\x1b[00m";
  const FAST = "\x1b[01;33m"; // bold yellow - must not blend into the blue run

  let out = `${prefix}${GREEN}${user}${RST}:${BLUE}${cwd}${RST} `;
  const line2 = [];

  // --- model (+ fast mode) ---
  // `fast_mode` is a TOP-LEVEL boolean in the statusline payload, and it is
  // the only honest source. Claude Code drops out of fast mode by itself on
  // fast-mode-specific cooldowns, so `"fastMode": true` in settings.json says
  // what was ASKED for, never what is live. Read the payload, not the setting.
  let model = g("model.display_name");
  if (model) {
    model = String(model).split(" (")[0];
    const fast = g("fast_mode") === true;
    line2.push(`${DIM}${model}${RST}${fast ? ` ${FAST}↯${RST}` : ""}`);
  }

  // --- context-window usage ---
  const usedPct = g("context_window.used_percentage");
  const usedTok = g("context_window.total_input_tokens");
  const ctxSize = g("context_window.context_window_size");
  const human = (n) => {
    n = Number(n);
    if (!isFinite(n)) return "?";
    if (n >= 1e6) return (n / 1e6).toFixed(1) + "M";
    if (n >= 1e3) return (n / 1e3).toFixed(0) + "k";
    return n.toFixed(0);
  };
  if (usedPct !== undefined && usedPct !== null) {
    if (usedTok !== undefined && usedTok !== null && ctxSize) {
      line2.push(`${DIM}ctx ${human(usedTok)}/${human(ctxSize)} (${Math.round(usedPct)}%)${RST}`);
    } else {
      line2.push(`${DIM}ctx ${Math.round(usedPct)}%${RST}`);
    }
  }

  // --- Claude.ai rate-limit usage (5h session + 7d weekly) ---
  const five = g("rate_limits.five_hour.used_percentage");
  const week = g("rate_limits.seven_day.used_percentage");
  const rate = [];
  if (five !== undefined && five !== null) rate.push(`5h ${Math.round(five)}%`);
  if (week !== undefined && week !== null) rate.push(`7d ${Math.round(week)}%`);
  if (rate.length) line2.push(`${DIM}${rate.join("  ")}${RST}`);

  process.stdout.write(out + line2.join(" ") + "\n");
});
