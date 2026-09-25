#!/usr/bin/env bash
# Regression battery for run-node.sh.
#
# WHY THIS FILE EXISTS, and why it is the highest-value battery in this directory:
# run-node.sh is the launcher every Node hook is registered through, and the
# failure it closes is the one that made ALL of them do nothing at once. Under a
# lazy version manager `node` is a SHELL FUNCTION defined in the interactive rc
# file, and the manager's bin directory is never exported - so in the
# non-interactive shell that runs a hook there is no node on PATH at all, on a
# machine where node plainly exists and the harness itself is running on it. Every
# hook registered as bare `node <script>` exited 127, and an exit-127 hook prints
# nothing and is not reported: the context guard, the agent watcher and the
# supermode triggers were all dead, silently, on every tool call, for as long as
# they had been registered.
#
#   bash run-node.test.sh          (HOOK=/path/to/hook to point it elsewhere)
#
# ⭐ SO THE CENTRAL CASE BELOW REPRODUCES THAT EXACT CONDITION rather than
# approximating it: a PATH with ordinary tools on it and NO node whatsoever, a
# fixture version-manager tree holding a fake interpreter, and an assertion that
# the fake interpreter is the one that actually ran. The fake writes a marker
# naming itself, because "it exited 0" proves nothing here - a fall-through to a
# different interpreter also exits 0, and that is precisely how this failure hid.
#
# ⚠️ EVERY CASE RUNS UNDER A FAKE $HOME AND A FAKE PATH, by construction: the hook
# resolves $NVM_DIR, falling back to $HOME/.nvm, so a real HOME would make these
# cases depend on which node versions the person running them happens to have
# installed. mktemp, removed on exit via trap - on success, failure and interrupt.
#
# ⚠️ A MISSING PREREQUISITE EXITS 2, NOT 0. 0 = green, 1 = a real failure,
# 2 = did not run.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="${HOOK:-$HERE/../run-node.sh}"

[ -f "$HOOK" ] || { echo "hook not found beside the test: $HOOK"; exit 2; }

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/run-node-test.XXXXXX") || {
	echo "could not create a temp dir - refusing to run against the real HOME"; exit 2; }
cleanup() { [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT INT TERM HUP

pass=0; fail=0
ok()    { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()   { fail=$((fail+1)); printf '  FAIL %s\n         want: %s\n         got:  %s\n' "$1" "$2" "$3"; }
t()     { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains '$2'" "$3" ;; esac; }

# ⛔ THE PATH CANNOT SIMPLY BE EMPTIED. run-node.sh itself shells out to cat, ls,
# sort and tail while walking the version-manager tree, so a PATH of /nonexistent
# would break the very code under test and the battery would "prove" the resolution
# failed for a reason that never happens in the field. What the real failure looks
# like is an ORDINARY PATH WITH NO NODE ON IT, so that is what is built here: a
# directory holding links to exactly the tools the hook uses, and nothing else.
mk_toolpath() { # <dir> - returns non-zero if the machine is missing a tool
	mkdir -p "$1" || return 1
	for _tool in cat ls sort tail; do
		_p=$(command -v "$_tool" 2>/dev/null) || return 1
		case "$_p" in /*) ln -sf "$_p" "$1/$_tool" || return 1 ;; *) return 1 ;; esac
	done
}

# A stand-in interpreter that announces WHICH one it was. It also records its argv
# and its stdin, because the hook's contract is that it hands all three over
# untouched - stdin passed through by exec with no pipeline, argv forwarded whole,
# and the exit status returned as its own. `exit 7` is arbitrary and deliberate: 0
# would be indistinguishable from the launcher swallowing the failure.
mk_fake_node() { # <bin path> <tag> <marker dir>
	mkdir -p "$(dirname "$1")" || return 1
	cat > "$1" <<SH
#!/bin/sh
printf 'FAKE-NODE-STDOUT\n'
printf '%s\n' "$2" > "$3/which-node"
printf '%s\n' "\$*" > "$3/argv"
cat > "$3/stdin"
exit 7
SH
	chmod +x "$1"
}

# The script the launcher is asked to run. Valid, trivial JS on purpose: if a case
# ever falls through to a REAL node instead of the fixture one, it exits quietly
# rather than throwing, and the missing marker - not a stack trace - is what makes
# the assertion fail. The failure should read as "the wrong interpreter ran".
SCRIPT="$TMPROOT/scratch-hook.mjs"
printf 'process.exit(0);\n' > "$SCRIPT"

TOOLS="$TMPROOT/toolpath"
mk_toolpath "$TOOLS" || { echo "this machine is missing cat/ls/sort/tail as absolute paths - cannot build a node-free PATH"; exit 2; }

run() { # <PATH> <HOME> <NVM_DIR> [args to the hook...] -> sets RUN_OUT RUN_ERR RUN_RC
	_path="$1"; _home="$2"; _nvm="$3"; shift 3
	RUN_OUT=$(printf 'STDIN-PAYLOAD' | env -u NVM_BIN PATH="$_path" HOME="$_home" NVM_DIR="$_nvm" \
		/bin/sh "$HOOK" "$@" 2>"$TMPROOT/stderr")
	RUN_RC=$?
	RUN_ERR=$(cat "$TMPROOT/stderr")
}

newdir() { _d=$(mktemp -d "$TMPROOT/d.XXXXXX") && printf '%s' "$_d"; }

# The fixture's own assertion. If node were still reachable on the stripped PATH,
# every case below would pass for the wrong reason - so this is checked, not assumed.
echo "the fixture itself - the stripped PATH must genuinely have no node:"
t "no node on the stripped PATH" "" "$( (PATH="$TOOLS"; command -v node 2>/dev/null) )"

# ⭐ THE CASE THE WHOLE FILE IS FOR: no node on PATH, a version-manager tree that
# has one, and the launcher must find it and exec it.
echo "PATH has no node, a version-manager tree has one - it must still launch:"
m=$(newdir); h=$(newdir); nvm=$(newdir)
mk_fake_node "$nvm/versions/node/v99.0.0/bin/node" "nvm-v99" "$m"
run "$TOOLS" "$h" "$nvm" "$SCRIPT"
t   "the fixture interpreter is the one that ran" "nvm-v99" "$(cat "$m/which-node" 2>/dev/null)"
t   "it was handed the script path"               "$SCRIPT" "$(cat "$m/argv" 2>/dev/null)"
t   "stdin reached the script untouched"          "STDIN-PAYLOAD" "$(cat "$m/stdin" 2>/dev/null)"
t   "stdout is the script's alone"                "FAKE-NODE-STDOUT" "$RUN_OUT"
t   "the exit status is the script's, not the launcher's" 7 "$RUN_RC"
t   "the launcher stays silent on stderr when it succeeds" "" "$RUN_ERR"

# The version the person actually CHOSE beats the newest one installed, and the
# alias may take one hop (lts/*) before it names a version. Two versions exist
# here and the alias names the older, so only genuine alias resolution can pass:
# a fall-through to the newest-installed branch would report v99.
echo "the default alias wins over the newest installed version, one hop and all:"
m=$(newdir); h=$(newdir); nvm=$(newdir)
mk_fake_node "$nvm/versions/node/v98.0.0/bin/node" "nvm-v98-alias" "$m"
mk_fake_node "$nvm/versions/node/v99.0.0/bin/node" "nvm-v99-newest" "$m"
mkdir -p "$nvm/alias/lts"
printf 'lts/scratch\n' > "$nvm/alias/default"
printf '98.0.0\n'      > "$nvm/alias/lts/scratch"
run "$TOOLS" "$h" "$nvm" "$SCRIPT"
t "the aliased version ran, not the newest" "nvm-v98-alias" "$(cat "$m/which-node" 2>/dev/null)"

# Nothing about the fallbacks may cost anything when PATH is normal: an absolute,
# executable node on PATH is the free answer and must be taken first.
echo "a real node on PATH is used before any fallback:"
m=$(newdir); h=$(newdir); nvm=$(newdir)
withnode="$TMPROOT/toolpath-with-node"
mk_toolpath "$withnode" && mk_fake_node "$withnode/node" "on-path" "$m"
mk_fake_node "$nvm/versions/node/v99.0.0/bin/node" "nvm-v99" "$m"
run "$withnode" "$h" "$nvm" "$SCRIPT"
t "the PATH interpreter ran, not the fixture tree's" "on-path" "$(cat "$m/which-node" 2>/dev/null)"

# ⚠️ NEVER BLOCK THE TOOL CALL, BUT NEVER BE SILENT EITHER. A hook file that the
# settings name before it has been linked into place is a real, recurring case -
# a release adds a hook and the machine has not caught up - and the interpreter
# would otherwise print a stack trace on every single tool call.
echo "a script that is not there - skip it, say so on stderr, and do not fail the call:"
m=$(newdir); h=$(newdir); nvm=$(newdir)
mk_fake_node "$nvm/versions/node/v99.0.0/bin/node" "nvm-v99" "$m"
run "$TOOLS" "$h" "$nvm" "$TMPROOT/definitely-not-here.mjs"
t   "exits 0 so the tool call proceeds"   0  "$RUN_RC"
t   "⛔ stdout is untouched - it belongs to the hook protocol" "" "$RUN_OUT"
has "it names the file it skipped, on stderr" "definitely-not-here.mjs" "$RUN_ERR"
t   "the interpreter was never launched"  "" "$(cat "$m/which-node" 2>/dev/null)"

echo "no script given at all - same contract:"
m=$(newdir); h=$(newdir); nvm=$(newdir)
run "$TOOLS" "$h" "$nvm"
t   "exits 0"                      0  "$RUN_RC"
t   "stdout is untouched"          "" "$RUN_OUT"
has "it says what was missing"     "no script given" "$RUN_ERR"

# ⚠️ ONE BRANCH IS NOT COVERED HERE, KNOWINGLY: "no interpreter found anywhere",
# which must warn on stderr and exit 0. Its last fallback checks the ABSOLUTE paths
# /usr/local/bin/node, /usr/bin/node and /opt/homebrew/bin/node, and no fixture can
# make those absent from the machine running the battery - hiding them needs a
# container or a mount namespace, which is a dependency this framework does not
# have. Left uncovered and named, rather than faked with a stub that would only be
# testing the stub.

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
