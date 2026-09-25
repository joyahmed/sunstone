#!/bin/sh
# run-node.sh - run a Node hook script with an interpreter this shell can
# actually find, then get out of the way.
#
#   bash ~/.claude/hooks/run-node.sh ~/.claude/hooks/<script>.mjs [args...]
#
# ⛔ THE FAILURE THIS CLOSES, found on 2026-09-25: every hook registered as bare
# `node <script>` had never run once on a machine using a lazy Node version
# manager. Under nvm, `node` is a SHELL FUNCTION defined in the interactive rc
# file and nvm's bin directory is never exported, so in the non-interactive shell
# that runs a hook there is no node at all - on a machine where node plainly
# exists and Claude Code itself is running on it. `sh -c 'command -v node'` fails.
#
# A hook that cannot launch says nothing: no output, no warning, and Claude Code
# does not report a hook that exited 127. So the context guard (the only thing
# that keeps a session from walking into its context limit), the agent watcher and
# the supermode triggers were all dead, silently, on every tool call, for as long
# as they had been registered. The one hook that did fire was the one registered
# with an ABSOLUTE interpreter path. That is the whole difference.
#
# The same mechanism reaches every non-interactive caller - cron, systemd, git
# hooks, ssh, task runners, a login shell invoked from another OS - and had
# already blanked this framework's status line once. The rule it teaches: FIND
# the interpreter, do not ask the PATH whether it feels like having one.
#
# Contract, because hooks communicate over stdin/stdout/exit code:
#   - stdin is passed through untouched (exec, no pipeline, no `cat`)
#   - stdout is NEVER written to by this script - it belongs to the hook protocol
#   - the hook's exit status is this script's exit status (exec)
#   - if no interpreter is found, exit 0 so the tool call is never blocked, and
#     say so in ONE line on stderr - silence is what cost the evening above.
#
# POSIX sh on purpose: it is the launcher for the machines where the fancy thing
# is missing. No `local`, no arrays, no bashisms.

if [ "$#" -eq 0 ]; then
  printf 'run-node.sh: no script given\n' >&2
  exit 0
fi

# A first argument that looks like a path must exist - otherwise the interpreter
# would exit non-zero with a stack trace on every single tool call. Happens for
# real: a release adds a hook, the settings name it, and the file has not been
# linked into place yet.
case "$1" in
  -*) : ;;
  *) [ -f "$1" ] || { printf 'run-node.sh: %s not found - skipping\n' "$1" >&2; exit 0; } ;;
esac

# Resolution order, same as the status line's find_node:
#   1. node on PATH (the normal case, and free)
#   2. $NVM_BIN - set when a version manager is active in this environment
#   3. the version manager's `default` alias, resolving one alias hop (lts/*):
#      the version the person actually chose
#   4. the newest installed version, by VERSION order, not lexical order
#   5. plain installs, including Homebrew on Apple silicon
# Nothing is ever printed to stdout here; the path is captured, not echoed.
NODE_BIN=''

# ⚠️ `command -v node` does NOT mean there is a node binary. For a shell
# function, alias or builtin it prints the NAME - and that is exactly what a lazy
# version manager leaves behind: `command -v node` prints `node`, and `exec node`
# then dies with 127. So accept the answer only if it is an absolute path to
# something executable. (Not a bare relative name either: a repo that happens to
# contain an executable file called `node` must not become the interpreter.)
found_on_path=$(command -v node 2>/dev/null)
case "$found_on_path" in
  /*) [ -x "$found_on_path" ] && NODE_BIN=$found_on_path ;;
esac

if [ -z "$NODE_BIN" ] && [ -n "${NVM_BIN:-}" ] && [ -x "$NVM_BIN/node" ]; then
  NODE_BIN="$NVM_BIN/node"
fi

NVM_ROOT="${NVM_DIR:-$HOME/.nvm}"

if [ -z "$NODE_BIN" ] && [ -r "$NVM_ROOT/alias/default" ]; then
  alias_default=$(cat "$NVM_ROOT/alias/default" 2>/dev/null)
  if [ -n "$alias_default" ] && [ -r "$NVM_ROOT/alias/$alias_default" ]; then
    alias_default=$(cat "$NVM_ROOT/alias/$alias_default" 2>/dev/null)
  fi
  for cand in "$alias_default" "v$alias_default"; do
    [ -n "$cand" ] || continue
    if [ -x "$NVM_ROOT/versions/node/$cand/bin/node" ]; then
      NODE_BIN="$NVM_ROOT/versions/node/$cand/bin/node"
      break
    fi
  done
fi

if [ -z "$NODE_BIN" ] && [ -d "$NVM_ROOT/versions/node" ]; then
  # The whole pipeline's stderr is swallowed: on a machine so bare that PATH has
  # no ls/sort/tail, the shell's own "command not found" lines would otherwise
  # turn this one honest warning into three lines of confusing noise.
  newest=$( { ls -1 "$NVM_ROOT/versions/node" | sort -t. -k1.2,1n -k2,2n -k3,3n | tail -1; } 2>/dev/null )
  if [ -n "$newest" ] && [ -x "$NVM_ROOT/versions/node/$newest/bin/node" ]; then
    NODE_BIN="$NVM_ROOT/versions/node/$newest/bin/node"
  fi
fi

if [ -z "$NODE_BIN" ]; then
  for cand in /usr/local/bin/node /usr/bin/node /opt/homebrew/bin/node; do
    [ -x "$cand" ] && { NODE_BIN=$cand; break; }
  done
fi

if [ -z "$NODE_BIN" ]; then
  # Never block the tool call over a missing interpreter - but never be silent
  # about it either, and name the mechanism so the next reader does not go
  # hunting for a bug in the hook itself.
  printf 'run-node.sh: no node interpreter found (a lazy version manager exports node as a shell function, not on PATH) - %s skipped\n' "$1" >&2
  exit 0
fi

# exec: stdin, stdout, stderr and the exit status are the hook's, not ours.
exec "$NODE_BIN" "$@"
