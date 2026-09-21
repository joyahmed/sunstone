#!/usr/bin/env node
// graphify-nudge.mjs - PreToolUse hook on Bash (registered by the settings
// template).
//
// When the project has a graphify knowledge graph (graphify-out/graph.json in
// the working directory) and the command about to run is a code search, add
// one line of context: read the graph report first. That is the whole job.
//
// It used to be an inline `python3 -c` pipeline in the template itself, which
// assumed python3 on every machine - a wrong assumption on Windows. This is
// the Node port: no dependencies, and every failure is silent, so a machine
// without graphify, without node, or with unreadable input gets nothing, never
// an error in the hook output. The template's command also tests for the graph
// file before starting node at all, so the common case costs one shell test.

import fs from "node:fs";

async function main() {
  if (!fs.existsSync("graphify-out/graph.json")) return;
  let raw = "";
  for await (const chunk of process.stdin) raw += chunk;
  let cmd = "";
  try {
    const d = JSON.parse(raw);
    cmd = String((d && d.tool_input && d.tool_input.command) || (d && d.command) || "");
  } catch {
    return;
  }
  // The same searches the shell version nudged on: grep in any spelling, and
  // rg / ripgrep / find / fd / ack / ag as a word.
  if (!/grep|\b(?:rg|ripgrep|find|fd|ack|ag)\b/.test(cmd)) return;
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext:
        "graphify: Knowledge graph exists. Read graphify-out/GRAPH_REPORT.md for god nodes and " +
        "community structure before searching raw files.",
    },
  }));
}

main().catch(() => { /* never an error in the hook output */ });
