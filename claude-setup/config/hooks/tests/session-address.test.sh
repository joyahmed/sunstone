#!/usr/bin/env bash
# Regression battery for the session ADDRESS: the launcher's --name derivation
# (bin/supermode) and the SessionStart identity line + session registry
# (session-bus-notice.js).
#
# WHY THIS FILE EXISTS. A peer choosing who to message reads a session listing,
# and the only thing that listing shows per row is the DISPLAY NAME. Unnamed, a
# session is titled from its first task - so a session whose first task was
# "contact the other box" is listed under a title naming a box it is NOT on.
# Five long messages went to the wrong box in one day on exactly that, and the
# box they were meant for appeared in no listing at all while it worked. The two
# fixes are a name set at LAUNCH and a registry written at SESSION START, and
# both are the kind of plumbing that breaks silently: a launcher that builds the
# wrong argv still launches, and a registry that appends a duplicate row every
# session still looks like it works until the file is read months later.
#
# ⛔ THE ARGV IS ASSERTED, NOT A LAUNCHED SESSION. A `claude` shim on PATH that
# prints its arguments is the only honest way to prove the flag reaches the CLI:
# starting a real session to find out is both slow and a side effect no gate may
# have.
#
# ⚠️ INVERSE CONTROLS ARE HALF OF THIS FILE. Every case that demands output has a
# twin that demands its absence - exactly one --name (never two), exactly one row
# per session id (never a duplicate), no warning at all on a session with nothing
# wrong with it, and an empty stderr on the healthy fixture. Without those, a hook
# that warned on every start or a registry that appended forever would pass.
#
#   bash session-address.test.sh          (NODE=/path/to/node to pick an interpreter)
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="${HOOK:-$HERE/../session-bus-notice.js}"
LAUNCHER="${LAUNCHER:-$HERE/../../../bin/supermode}"

# ⛔ `[ -x "$(command -v node)" ]` is the WRONG probe: under nvm, and in an agent
# shell, `node` is a shell FUNCTION and `command -v` prints the bare word, so the
# -x test is false on a machine where node runs fine. Ask whether it RUNS.
NODE="${NODE:-node}"
if ! "$NODE" --version >/dev/null 2>&1; then
	for cand in "${NVM_BIN:-}/node" /usr/local/bin/node /usr/bin/node /opt/homebrew/bin/node \
	            "${NVM_DIR:-${HOME:-}/.nvm}"/versions/node/*/bin/node; do
		[ -x "$cand" ] && { NODE="$cand"; break; }
	done
fi
"$NODE" --version >/dev/null 2>&1 || { echo "no node interpreter that runs - set NODE=/path/to/node"; exit 2; }
[ -f "$HOOK" ] || { echo "hook not found beside the test: $HOOK"; exit 2; }
[ -f "$LAUNCHER" ] || { echo "launcher not found in this checkout: $LAUNCHER"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git is needed to build the work-tree fixture"; exit 2; }

pass=0; fail=0
ok()    { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no()    { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else no "$1  want=[$2] got=[$3]"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) no "$1  (missing: $3)" ;; esac; }
hasnt() { case "$2" in *"$3"*) no "$1  (present: $3)" ;; *) ok "$1" ;; esac; }

WORK=$(mktemp -d 2>/dev/null) || { echo "cannot make a temp directory"; exit 2; }
trap 'rm -rf "$WORK"' EXIT INT TERM

# --- fixture ------------------------------------------------------------------
# A fake HOME (box name file, launcher settings, memory-repo pointer), a fake
# memory repo with a bus directory, a work tree to launch from and a loose
# directory that is not a repo. No real machine name, user or path appears here.
FHOME="$WORK/home"
MEMREPO="$WORK/memrepo"
BUS="$MEMREPO/claude-setup/session-bus"
TREE="$WORK/widget"
LOOSE="$WORK/loosedir"
mkdir -p "$FHOME/.claude/hooks" "$BUS" "$MEMREPO/claude-setup/config" "$TREE/src/deep" "$LOOSE"
: > "$FHOME/.claude/supermode.settings.json"
printf '%s\n' "$MEMREPO" > "$FHOME/.claude/ai-memory-path"
printf 'BUS_DIR=claude-setup/session-bus\nBUS_SIDE=alpha\n' > "$MEMREPO/claude-setup/config/sunstone.conf"
git -c init.templateDir= init -q "$MEMREPO" >/dev/null 2>&1 || mkdir -p "$MEMREPO/.git"
git -c init.templateDir= init -q "$TREE"    >/dev/null 2>&1 || mkdir -p "$TREE/.git"

# A `claude` that launches nothing and prints the argv it was handed, one per line.
SHIM="$WORK/shim"
mkdir -p "$SHIM"
cat > "$SHIM/claude" <<'SH'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done
SH
chmod +x "$SHIM/claude"

NAMEFILE="$FHOME/.claude/hooks/claude-name.txt"
SIDEFILE="$FHOME/.claude/bus-side"

# argv <cwd> [args...] - the whole command line the launcher builds for `claude`.
argv() {
	_cwd="$1"; shift
	( cd "$_cwd" 2>/dev/null || exit 9
	  HOME="$FHOME" CLAUDE_CONFIG_DIR= PATH="$SHIM:$PATH" SUPERMODE= \
	    sh "$LAUNCHER" "$@" 2>/dev/null )
}
# The value the launcher gave --name, or "" when it passed none.
named() { argv "$@" | awk '/^--name$/ { getline; print; exit }'; }
# How many --name flags the command line carries.
names() { argv "$@" | grep -c '^--name$'; }

echo "the launcher builds <box>/<repo> and hands it to the CLI:"
printf 'Boxone\n' > "$NAMEFILE"
rm -f "$SIDEFILE"
A=$(argv "$TREE/src/deep")
has "--name reaches the CLI at all"                 "$A" "--name"
eq  "one-line box file, launched inside a work tree" "Boxone/widget" "$(named "$TREE/src/deep")"
has "the settings flag is still there"              "$A" "--settings"
has "remote control is still added"                 "$A" "--remote-control"
eq  "exactly one --name, never two"                 "1" "$(names "$TREE")"

# ⛔ THE WELD. A box name file that grew a second line - a note, a stray value -
# must yield the FIRST line, not the two joined into a word no peer can retype.
# This exact defect was found and fixed in the status line, so it is pinned here.
printf 'Boxtwo\nsome trailing note\n' > "$NAMEFILE"
N=$(named "$TREE")
eq    "two-line box file: the first line wins"      "Boxtwo/widget" "$N"
hasnt "the two lines are not welded together"       "$N" "some"
hasnt "no space smuggled into the name"             "$N" " "

# A leading blank line is not a name either: the first NON-EMPTY line is.
printf '\n   \nBoxthree\n' > "$NAMEFILE"
eq "blank and blank-ish lines are skipped"          "Boxthree/widget" "$(named "$TREE")"

# CR-terminated file (written on the other OS of the same box, read here).
printf 'Boxfour\r\nnote\r\n' > "$NAMEFILE"
eq "a CR does not become part of the name"          "Boxfour/widget" "$(named "$TREE")"

# ⚠️ PINNED DECISION - a box file with no name in it. The fallback is the SHORT
# hostname (the per-machine bus-side file first, if there is one); if even that is
# empty the address is the repo ALONE. Never an empty segment, never a leading "/".
printf '   \n\t\n' > "$NAMEFILE"
rm -f "$SIDEFILE"
HOSTSHORT=$( (hostname 2>/dev/null || uname -n 2>/dev/null || true) | head -n1 | cut -d. -f1 | tr -cd 'A-Za-z0-9._-' )
N=$(named "$TREE")
if [ -n "$HOSTSHORT" ]; then
	eq "whitespace-only box file falls back to the short host name" "$HOSTSHORT/widget" "$N"
else
	eq "whitespace-only box file and no host name: the repo alone"  "widget" "$N"
fi
case "$N" in /*) no "an address must never begin with /" ;; *) ok "no empty box segment" ;; esac
case "$N" in */) no "an address must never end with /" ;; *) ok "no empty repo segment" ;; esac

# The per-machine bus-side file is the second source, ahead of the host name.
printf 'sidename\n' > "$SIDEFILE"
eq "an empty box file falls through to the bus-side file" "sidename/widget" "$(named "$TREE")"
rm -f "$SIDEFILE"

echo "outside a work tree, and when the caller names the session itself:"
printf 'Boxone\n' > "$NAMEFILE"
eq "outside a repo: the current directory's basename" "Boxone/loosedir" "$(named "$LOOSE")"

# ⛔ A caller that named the session MEANT it. Overriding that would be the same
# mistake as retitling a peer for someone else's routing.
eq "an explicit --name is not clobbered"   "chosen"  "$(named "$TREE" --name chosen)"
eq "an explicit --name is not duplicated"  "1"       "$(names "$TREE" --name chosen)"
eq "the short -n form is respected too"    "0"       "$(names "$TREE" -n chosen)"
A=$(argv "$TREE" --name=chosen)
eq "the --name=value form is respected"    "0"       "$(printf '%s\n' "$A" | grep -c '^--name$')"
has "the caller's --name=value survives"   "$A"      "--name=chosen"

echo "the SessionStart hook tells the session its own address:"
run_hook() { # <session-id> [cwd] - stdout of the hook; stderr goes to $ERR
	printf '{"session_id":"%s","cwd":"%s"}' "$1" "${2:-$TREE}" \
	  | env HOME="$FHOME" CLAUDE_CONFIG_DIR= BUS_SIDE= "$NODE" "$HOOK" 2>"$ERR"
}
ERR="$WORK/stderr"
OUT=$(run_hook sess-one)
RC=$?
eq  "the hook exits 0"                              "0" "$RC"
has "the address is injected"                       "$OUT" "Boxone/widget"
has "the FROM rule is stated"                       "$OUT" "FROM Boxone/widget"
has "it is SessionStart additionalContext"          "$OUT" "additionalContext"
eq  "nothing on stderr"                             "" "$(cat "$ERR")"
# ⛔ INVERSE CONTROL: a session with NOTHING wrong with it is told its address and
# nothing else. A hook that scolds every correctly-named session at every start is
# noise that gets switched off, and then the fix is gone.
hasnt "no warning on a healthy session"             "$OUT" "⚠️"
hasnt "no refusal marker on a healthy session"      "$OUT" "⛔"
hasnt "no cannot-verify note on a healthy session"  "$OUT" "cannot verify"
hasnt "the session is not told to rename itself"    "$OUT" "rename"

# ⭐ THE SEPARATOR IS PINNED. The slash is the spelling the convention uses, in
# the display name and in the FROM line alike. A change of separator must break
# this assertion and be argued for, not slip in as a tidy-up.
has "the address keeps its slash"                   "$OUT" "Boxone/widget"
echo "the registry records the session where every box can read it:"
REG="$BUS/sessions-alpha.md"
rows() { grep -c '^| [0-9]' "$1" 2>/dev/null || echo 0; }
eq  "one row after the first start"                 "1" "$(rows "$REG")"
has "the row carries the box"                       "$(cat "$REG")" "| Boxone |"
has "the row carries the repo"                      "$(cat "$REG")" "| widget |"
has "the row carries the session id"                "$(cat "$REG")" "sess-one"
# ⛔ INVERSE CONTROL FOR IDEMPOTENCE: the same session id twice must UPDATE, not
# append. An appending registry looks healthy for a week and is unreadable after.
cp "$REG" "$WORK/first.md"
run_hook sess-one >/dev/null
eq "the same session id adds no second row"         "1" "$(rows "$REG")"
if cmp -s "$WORK/first.md" "$REG"; then ok "a repeat start leaves the file byte-identical"
else no "a repeat start rewrote the file"; fi
run_hook sess-two >/dev/null
eq "a different session id adds exactly one row"    "2" "$(rows "$REG")"

# An absent registry is created, not a failure.
rm -f "$REG"
run_hook sess-three >/dev/null
eq  "an absent registry file is created"            "1" "$(rows "$REG")"
eq  "creating it is silent on stderr"               "" "$(cat "$ERR")"

# Pruning: a row older than the window goes, today's stays. This is the only
# thing standing between the file and unbounded growth, so it is pinned.
OLD=$("$NODE" -e 'process.stdout.write(new Date(Date.now()-9*86400000).toISOString().replace(/\.\d+Z$/,"Z"))')
{
	printf '| started (UTC) | box | repo | session id | display name |\n'
	printf '| --- | --- | --- | --- | --- |\n'
	printf '| %s | Boxold | widget | sess-ancient | - |\n' "$OLD"
} > "$REG"
run_hook sess-four >/dev/null
hasnt "a row past the window is pruned"             "$(cat "$REG")" "sess-ancient"
has   "this session's row is kept"                  "$(cat "$REG")" "sess-four"
# And a ceiling, so a flood of same-day rows cannot grow the file without bound.
{
	printf '| started (UTC) | box | repo | session id | display name |\n'
	printf '| --- | --- | --- | --- | --- |\n'
	NOW=$("$NODE" -e 'process.stdout.write(new Date().toISOString().replace(/\.\d+Z$/,"Z"))')
	i=0; while [ "$i" -lt 130 ]; do printf '| %s | Boxone | widget | flood-%s | - |\n' "$NOW" "$i"; i=$((i+1)); done
} > "$REG"
run_hook sess-five >/dev/null
eq "the row count is capped"                        "100" "$(rows "$REG")"

# The name as actually stored is invisible to a hook, so the registry carries the
# intended address instead - and when a name IS visible and disagrees with the
# address, that disagreement is the finding and gets said.
OUT=$(printf '{"session_id":"sess-named","cwd":"%s","session_name":"somethingelse"}' "$TREE" \
        | env HOME="$FHOME" CLAUDE_CONFIG_DIR= BUS_SIDE= "$NODE" "$HOOK" 2>"$ERR")
has  "a listed name that disagrees with the address is reported" "$OUT" "but its address is Boxone/widget"
eq   "reporting it stays off stderr"                "" "$(cat "$ERR")"
# ⛔ INVERSE CONTROL: a name that AGREES must produce no such note.
OUT=$(printf '{"session_id":"sess-agree","cwd":"%s","session_name":"Boxone/widget"}' "$TREE" \
        | env HOME="$FHOME" CLAUDE_CONFIG_DIR= BUS_SIDE= "$NODE" "$HOOK" 2>"$ERR")
hasnt "a name that agrees is not reported"          "$OUT" "but its address is"

echo "the cases where the registry cannot be written:"
# ⚠️ A declared memory repo that this process cannot open is CANNOT VERIFY, not
# missing - the path can belong to the other OS of the same physical box. Saying
# nothing there is how a box ends up in no listing with nobody noticing.
printf '%s\n' "$WORK/not-a-path-that-exists" > "$FHOME/.claude/ai-memory-path"
OUT=$(run_hook sess-six); RC=$?
eq  "an unresolvable repo path still exits 0"       "0" "$RC"
has "the address is injected anyway"                "$OUT" "Boxone/widget"
has "it says cannot verify"                         "$OUT" "cannot verify"
eq  "and stays off stderr"                          "" "$(cat "$ERR")"
# No pointer file at all is not a defect: the memory layer is simply not set up.
rm -f "$FHOME/.claude/ai-memory-path"
OUT=$(run_hook sess-seven); RC=$?
eq    "no pointer file: still exits 0"              "0" "$RC"
has   "the address is still injected"               "$OUT" "Boxone/widget"
hasnt "and nothing is reported as unverifiable"     "$OUT" "cannot verify"

# ⛔ A SessionStart hook that blocks hangs every session on the box. Empty stdin
# (and a closed one) must return immediately.
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 10"
printf '' | env HOME="$FHOME" CLAUDE_CONFIG_DIR= $TO "$NODE" "$HOOK" >/dev/null 2>&1
eq "empty stdin returns at once and exits 0"        "0" "$?"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
