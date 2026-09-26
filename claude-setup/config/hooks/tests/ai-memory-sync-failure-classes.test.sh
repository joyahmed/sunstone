#!/usr/bin/env bash
# Regression battery for ai-memory-sync.sh - the SessionStart hook that pulls the
# user's memory repo and injects the memory file. Specifically: does it tell the
# session WHY the memory it just injected might not be current?
#
# WHY THIS FILE EXISTS. The hook's pull used to fail SILENTLY for every reason
# there is, because the only thing it consulted after a failed pull was
# HEAD..@{u} - and a pull that fails has usually failed BEFORE fetching, so that
# count is 0 no matter what the remote holds. Measured live on the Linux box,
# 2026-09-26, in the real memory repo:
#
#   $ git -C ~/projects/03_ai/everything-joy pull --ff-only --quiet
#   error: cannot pull with rebase: You have unstaged changes.
#   error: Please commit or stash them.
#   rc=128
#   behind=0  ahead=0            ⇒ SYNC_WARN=[]        ⇒ the session was told NOTHING
#
# That machine's global config is pull.rebase=true + pull.ff=only, so a dirty
# tree is enough. "fatal: Cannot rebase onto multiple branches." (a stray
# FETCH_HEAD entry left by an earlier `git fetch --all`, same config) came out
# exactly the same way, as did a missing upstream and expired credentials. Every
# one of them was byte-identical to a laptop on a plane: a session that believed
# it held current memory while it held an older copy. That is the single
# highest-stakes silent failure in this framework, and these are its assertions.
#
# ⚠️ AND A DETECTOR FOR A SILENT FAULT IS THE EASIEST KIND TO FAKE. Three failure
# modes would all look like success:
#
#   · it stays silent on a broken box  → the original bug, back. Cases 3, 4, 5, 6
#     and 7 are NEGATIVE CONTROLS: each is a machine that CANNOT sync, and each
#     must be named out loud with git's own error text and a paste-able fix.
#   · it prints on a healthy box → a notice that appears every start is scrolled
#     past within a day, taking the one start that mattered with it. Cases 1, 2
#     and 10 are the INVERSE CONTROLS: healthy, and the hook must say NOTHING.
#   · it calls "I cannot tell" offline → the worst of the three, because
#     "offline, carry on" is the answer that needs no action. Cases 4, 6 and 8
#     pin the three states apart: an unreachable remote is quiet-but-stale, a
#     reachable one makes any failure LOUD, and an unmeasurable one says
#     UNKNOWN - never offline.
#
# ⛔ AND IT MUST NEVER BE FATAL. A SessionStart hook that exits non-zero or hangs
# breaks every session on the machine, so every case below also asserts exit 0.
#
#   bash ai-memory-sync-failure-classes.test.sh     (HOOK=/path/to/ai-memory-sync.sh)
#
# ⛔ EVERY CASE RUNS UNDER A FAKE $HOME AND A FIXTURE REPO, BY CONSTRUCTION. The
# hook finds its repo through $HOME/.claude/ai-memory-path, so a fake HOME is the
# whole isolation. Nothing here touches the real memory repo, and nothing here
# touches any git config outside its own mktemp fixture - the machine's
# pull.rebase/pull.ff belong to the user and the hook has to cope with them, not be
# relieved of them, so the fixtures RECREATE that combination instead.
#
# ⚠️ A MISSING PREREQUISITE EXITS 2, NOT 0 - "could not run the battery" must
# never be reported as "the hook is fine". 0 = green, 1 = a real failure,
# 2 = did not run.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="${HOOK:-$HERE/../ai-memory-sync.sh}"

[ -f "$HOOK" ] || { echo "ai-memory-sync.sh not found at $HOOK - set HOOK=/path/to/it"; exit 2; }
for t in git mktemp sed grep; do
	command -v "$t" >/dev/null 2>&1 || { echo "no $t - the hook cannot be exercised"; exit 2; }
done
GIT_BIN=$(command -v git) || { echo "no git"; exit 2; }
case "$(git --version 2>/dev/null)" in
	*version*) ;;
	*) echo "git does not answer --version - refusing to guess"; exit 2 ;;
esac

# ⛔ The fixtures must not inherit the machine's git config: this box has a global
# commit-msg hook that rejects a subject like "one", and a global pull.rebase that
# the fixtures set for THEMSELVES where they want it. /dev/null for both is how a
# fixture becomes a fixture instead of a sample of whoever ran it.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_TERMINAL_PROMPT=0
unset GIT_DIR GIT_WORK_TREE 2>/dev/null || true

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/ai-memory-sync-test.XXXXXX") || {
	echo "could not create a temp dir - refusing to run against the real \$HOME"; exit 2; }
cleanup() { [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT INT TERM HUP

pass=0; fail=0
ok()    { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()   { fail=$((fail+1)); printf '  FAIL %s\n         want: %s\n         got:  %s\n' "$1" "$2" "$3"; }
clip()  { printf '%s' "$1" | tr '\n' '|' | cut -c1-500; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "output contains '$2'" "$(clip "$3")" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1" "output does NOT contain '$2'" "$(clip "$3")" ;; *) ok "$1" ;; esac; }
eq()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

# ---------------------------------------------------------------------------
# build - a fake $HOME, a bare "remote", and a clone of it carrying a memory
# file. Rebuilt per scenario: the hook mutates the clone (that is its job) and a
# later scenario must not inherit an earlier one's repairs.
# ---------------------------------------------------------------------------
FHOME="" REPO="" UP="" SEED=""
build() {
	FHOME=$(mktemp -d "$TMPROOT/home.XXXXXX") || return 1
	mkdir -p "$FHOME/.claude"
	UP="$FHOME/up.git"; REPO="$FHOME/memory"; SEED="$FHOME/seed"
	SHIMBIN=""                  # a shim belongs to ONE scenario; it must not leak
	# -b main on BOTH: a bare repo whose HEAD still says refs/heads/master while
	# only main exists gives a clone with no checkout at all, and every assertion
	# about the injected file would then be measuring the fixture, not the hook.
	git init -q --bare -b main "$UP"
	git init -q -b main "$SEED"
	git -C "$SEED" config user.email t@t; git -C "$SEED" config user.name t
	mkdir -p "$SEED/claude-setup/memory"
	printf '# ABOUT-ME\n\nThis is the portable memory file, and this line proves the injection ran.\n' \
		> "$SEED/claude-setup/memory/ABOUT-ME.md"
	git -C "$SEED" add -A >/dev/null 2>&1
	git -C "$SEED" commit -qm seed >/dev/null 2>&1
	git -C "$SEED" push -q "$UP" main:refs/heads/main >/dev/null 2>&1
	git clone -q "$UP" "$REPO" >/dev/null 2>&1 || return 1
	git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
	printf '%s\n' "$REPO" > "$FHOME/.claude/ai-memory-path"
}

# upstream_advances - one new commit on the remote, so the clone is genuinely
# behind and a pull has real work to do.
upstream_advances() {
	printf 'a line that only the remote has\n' >> "$SEED/claude-setup/memory/ABOUT-ME.md"
	git -C "$SEED" commit -qam more >/dev/null 2>&1
	git -C "$SEED" push -q "$UP" main:refs/heads/main >/dev/null 2>&1
}

# joys_config - the combination on the real machine. NOT set on the machine by
# this battery; set inside the fixture clone only.
joys_config() {
	git -C "$REPO" config pull.rebase true
	git -C "$REPO" config pull.ff only
}

# shim GIT-SUBCOMMAND MESSAGE EXIT_CODE [SECOND-SUBCOMMAND MESSAGE EXIT]
# A `git` earlier on PATH that fails ONE subcommand with an exact message and
# passes everything else through to the real git. This is how an error that
# cannot be provoked on demand - "Cannot rebase onto multiple branches" needs a
# FETCH_HEAD state left behind by an unrelated earlier command - still gets a
# deterministic assertion, and how "the remote refuses us" is separated from
# "the remote is unreachable" without a network.
SHIMBIN=""
shim() {
	SHIMBIN="$FHOME/bin"; mkdir -p "$SHIMBIN"
	{
		printf '#!/bin/sh\n'
		printf 'REAL=%s\n' "$GIT_BIN"
		printf 'sub=""\nfor a in "$@"; do case "$a" in -*|/*) ;; *) sub="$a"; break ;; esac; done\n'
		printf 'if [ "$sub" = "%s" ]; then printf %s >&2; exit %s; fi\n' \
			"$1" "'%s\n' '$2'" "$3"
		if [ $# -ge 6 ]; then
			printf 'if [ "$sub" = "%s" ]; then printf %s >&2; exit %s; fi\n' \
				"$4" "'%s\n' '$5'" "$6"
		fi
		printf 'exec "$REAL" "$@"\n'
	} > "$SHIMBIN/git"
	chmod +x "$SHIMBIN/git"
}

# runhook - the hook, under the fake HOME, stdout+stderr captured, rc recorded.
OUT=""; RC=0
runhook() {
	local p="$PATH"
	[ -n "$SHIMBIN" ] && p="$SHIMBIN:$PATH"
	OUT=$(HOME="$FHOME" PATH="$p" bash "$HOOK" 2>&1 </dev/null); RC=$?
}

# ===========================================================================
echo "case 1 - a healthy box: the pull works and the hook says NOTHING about it"
# ⛔ INVERSE CONTROL. Everything below is worthless if a working machine also
# gets a notice: the notice stops being read, and the broken start goes by
# unnoticed again. There is real work to do here (the clone is behind by one
# commit) so this is a pull that SUCCEEDS, not a pull with nothing to do.
build || { echo "fixture failed"; exit 2; }
upstream_advances
runhook
eq    "exit 0"                                                   0            "$RC"
has   "the memory file is injected"                              "proves the injection ran" "$OUT"
hasnt "no WARNING on a healthy box"                              "WARNING"    "$OUT"
hasnt "does not claim staleness"                                 "STALE"      "$OUT"
hasnt "does not claim a failure"                                 "FAILED"     "$OUT"
hasnt "does not claim it could not verify"                        "COULD NOT BE VERIFIED" "$OUT"
eq    "and the pull really happened (clone no longer behind)"    "0" \
      "$(git -C "$REPO" rev-list --count 'HEAD..@{u}' 2>/dev/null)"

echo
echo "case 2 - healthy AND nothing to inject: the hook prints literally nothing"
# The other half of the inverse control: with no memory file there is no
# injection to hide a stray notice inside, so the output must be empty - byte
# for byte. This is the assertion that would catch a notice added 'just for
# visibility' later on.
build || { echo "fixture failed"; exit 2; }
rm -f "$REPO/claude-setup/memory/ABOUT-ME.md"
git -C "$REPO" commit -qam "drop the memory file" >/dev/null 2>&1
git -C "$REPO" push -q origin main >/dev/null 2>&1
runhook
eq "exit 0"                        0  "$RC"
eq "stdout is empty, byte for byte" "" "$OUT"

echo
echo "case 3 - the LIVE failure: pull.rebase=true + a dirty tree ⇒ LOUD"
# This is the measured failure from the top of this file, reproduced. It used to
# print nothing whatsoever. The remote here is a local path, so it IS reachable -
# which is exactly what makes "offline" an unavailable excuse.
build || { echo "fixture failed"; exit 2; }
joys_config
upstream_advances
printf 'an edit nobody committed yet\n' >> "$REPO/claude-setup/memory/ABOUT-ME.md"
runhook
eq  "exit 0 - never fatal"                              0  "$RC"
has "it is reported, not swallowed"                     "MEMORY SYNC FAILED"           "$OUT"
has "it says the remote IS reachable"                   "remote IS reachable"          "$OUT"
has "it quotes git's own error"                         "unstaged changes"             "$OUT"
has "it gives the exact fix - stash, pull, pop"         "stash push -u"                "$OUT"
has "the fix names the actual repo path"                "$REPO"                        "$OUT"
has "the memory is still injected alongside the warning" "proves the injection ran"                  "$OUT"
hasnt "and it is NOT sold as offline"                   "not reachable from this machine" "$OUT"

echo
echo "case 4 - genuinely offline: quiet, but the memory is MARKED as possibly stale"
# Requirement 1: a session on a plane must still start, and must not be nagged.
# But the memory it is handed is this machine's last synced copy, and saying so
# is not a nag. The remote is a port nothing listens on, so 'Connection refused'
# is deterministic and needs no network.
build || { echo "fixture failed"; exit 2; }
git -C "$REPO" remote set-url origin "git://127.0.0.1:1/nope.git"
runhook
eq    "exit 0"                                     0  "$RC"
has   "the injected memory is marked stale"        "MEMORY MAY BE STALE"     "$OUT"
has   "and it says the remote is unreachable"      "not reachable from this machine" "$OUT"
has   "and that there is nothing to fix"           "Nothing to fix if this machine is offline" "$OUT"
hasnt "offline is NOT reported as a failure"       "MEMORY SYNC FAILED"      "$OUT"
hasnt "nor as unverifiable"                        "COULD NOT BE VERIFIED"   "$OUT"
has   "the memory is still injected"               "proves the injection ran"              "$OUT"

echo
echo "case 5 - a config fault (upstream points at a ref the remote does not have) ⇒ LOUD"
# The class Alina named: the pull fails for a LOCAL reason while the network is
# fine. Previously silent, because with no resolvable @{u} the old code took the
# 'this is offline' early return.
build || { echo "fixture failed"; exit 2; }
git -C "$REPO" config branch.main.merge refs/heads/a-branch-that-was-deleted
runhook
eq    "exit 0"                                       0  "$RC"
has   "reported"                                     "MEMORY SYNC FAILED"      "$OUT"
has   "git's error is quoted"                        "no such ref was fetched" "$OUT"
has   "the fix is the upstream repair, not a stash"  "--set-upstream-to=origin/" "$OUT"
hasnt "not passed off as offline"                    "MEMORY MAY BE STALE"     "$OUT"

echo
echo "case 6 - 'fatal: Cannot rebase onto multiple branches.' ⇒ LOUD, with the right fix"
# Taken from a real box, verbatim. It needs a FETCH_HEAD state an unrelated earlier command
# left behind, so it is injected through a git shim rather than staged - the
# assertion is about the hook's handling, and the handling must not depend on
# being able to re-create the trigger.
build || { echo "fixture failed"; exit 2; }
joys_config
shim pull "fatal: Cannot rebase onto multiple branches." 128
runhook
eq    "exit 0"                                        0  "$RC"
has   "reported"                                      "MEMORY SYNC FAILED"     "$OUT"
has   "the exact git error reaches the session"       "Cannot rebase onto multiple branches" "$OUT"
has   "and the fix is an explicit refspec"            "pull --rebase origin main" "$OUT"
has   "with the reason the bare pull is ambiguous"    "stray FETCH_HEAD entry" "$OUT"
hasnt "not offline"                                   "MEMORY MAY BE STALE"    "$OUT"
hasnt "not unverifiable - ls-remote answered"         "COULD NOT BE VERIFIED"  "$OUT"

echo
echo "case 7 - credentials refused ⇒ LOUD (a refusal is an ANSWER, not an outage)"
# ⛔ The subtle one. An auth failure LOOKS like a network failure - git exits 128
# from the transport either way - and rounding it down to 'offline' is how
# expired credentials hide for weeks. The remote answered; that is reachable.
build || { echo "fixture failed"; exit 2; }
shim pull "fatal: Authentication failed for 'https://example.invalid/memory.git/'" 128 \
     ls-remote "fatal: Authentication failed for 'https://example.invalid/memory.git/'" 128
runhook
eq    "exit 0"                                    0  "$RC"
has   "reported as a failure"                     "MEMORY SYNC FAILED"      "$OUT"
has   "and named as a refusal, not an outage"     "refusing this machine's credentials" "$OUT"
has   "with the credential check as the fix"      "ls-remote origin"        "$OUT"
hasnt "⛔ NOT excused as offline"                 "MEMORY MAY BE STALE"     "$OUT"

echo
echo "case 8 - reachability unmeasurable ⇒ says UNKNOWN, never 'offline'"
# Requirement 3, and the reason it is a requirement: a check whose own failure
# mode imitates the fault it checks for is worse than no check. Here the pull
# fails AND the probe cannot answer, so the only honest output is 'unknown'.
build || { echo "fixture failed"; exit 2; }
shim pull "fatal: an error no pattern in this hook has ever seen" 128 \
     ls-remote "fatal: an error no pattern in this hook has ever seen" 128
runhook
eq    "exit 0"                                       0  "$RC"
has   "reported as unverifiable"                     "COULD NOT BE VERIFIED"  "$OUT"
has   "and it says so in those words"                "UNKNOWN"                "$OUT"
has   "with the instruction to treat it as stale"    "possibly stale"         "$OUT"
has   "git's error still reaches the session"        "no pattern in this hook" "$OUT"
hasnt "⛔ 'cannot tell' must NOT render as offline"  "MEMORY MAY BE STALE"    "$OUT"
hasnt "nor as a confirmed local fault"               "MEMORY SYNC FAILED"     "$OUT"

echo
echo "case 9 - ai-memory-path names a path this OS cannot open ⇒ CANNOT VERIFY"
# Requirement 5. ~/.claude/ai-memory-path is per-machine and routinely holds
# another machine's path. This used to exit 0 in silence, indistinguishable from
# a box that has no memory repo at all - so the session ran with no memory and
# no idea that it had none.
build || { echo "fixture failed"; exit 2; }
printf 'C:/Users/Someone/projects/memory-repo\n' > "$FHOME/.claude/ai-memory-path"
runhook
eq    "exit 0"                                        0  "$RC"
has   "reported"                                      "COULD NOT BE VERIFIED"      "$OUT"
has   "the offending path is quoted"                  "C:/Users/Someone/projects/memory-repo" "$OUT"
has   "named as another platform's path"              "another platform's path"    "$OUT"
has   "and the fix is the path file"                  "ai-memory-path"             "$OUT"
hasnt "⛔ not 'missing'"                              "MEMORY SYNC FAILED"         "$OUT"
hasnt "⛔ not offline"                                "MEMORY MAY BE STALE"        "$OUT"

echo "        ... and the same for a path that simply is not there"
build || { echo "fixture failed"; exit 2; }
printf '%s\n' "$FHOME/not-cloned-on-this-machine" > "$FHOME/.claude/ai-memory-path"
runhook
eq  "exit 0"                                  0  "$RC"
has "reported as unverifiable"                "COULD NOT BE VERIFIED"  "$OUT"
has "and says which of the three it is"       "no such directory on this machine" "$OUT"

echo
echo "case 10 - no memory repo configured at all ⇒ silent, and that is correct"
# INVERSE CONTROL for case 9. Nothing was ever claimed, so there is nothing to
# report: a machine that does not use the memory layer must not be told off by
# it every session.
build || { echo "fixture failed"; exit 2; }
rm -f "$FHOME/.claude/ai-memory-path"
runhook
eq "exit 0"                          0  "$RC"
eq "stdout is empty, byte for byte"  "" "$OUT"

echo
echo "case 11 - a local-only memory repo (no remote) ⇒ silent, also correct"
# A clone with no remote cannot sync and is not broken; sunstone is general
# purpose and someone's memory repo may be local by choice. Reporting it would
# be the every-session notice this battery exists to prevent.
build || { echo "fixture failed"; exit 2; }
git -C "$REPO" remote remove origin >/dev/null 2>&1
runhook
eq    "exit 0"                            0  "$RC"
has   "the memory is still injected"      "proves the injection ran"  "$OUT"
hasnt "and nothing is reported"           "WARNING"     "$OUT"

echo
echo "case 12 - a diverged clone still reports its COUNTS as well as its cause"
# The pre-existing behaviour, pinned so the rewrite did not lose it - and pinned
# together with the cause, because the counts block used to ASSIGN over whatever
# diagnosis sync_pull had produced, which is why the old rebase-conflict marker
# never reached a single session.
build || { echo "fixture failed"; exit 2; }
joys_config
upstream_advances
# A REAL divergence: origin/main is fetched (so the clone knows it is behind) and
# a memory commit exists only here. The shim goes on AFTER the fetch - the pull
# is what must fail, not the fixture's own setup.
git -C "$REPO" fetch -q origin >/dev/null 2>&1
printf 'a local-only memory line\n' >> "$REPO/claude-setup/memory/ABOUT-ME.md"
git -C "$REPO" commit -qam "local memory commit" >/dev/null 2>&1
shim pull "fatal: Cannot rebase onto multiple branches." 128
runhook
eq  "exit 0"                                   0  "$RC"
has "the cause survives"                       "Cannot rebase onto multiple branches" "$OUT"
has "and the counts are reported too"          "MEMORY IS NOT IN SYNC"  "$OUT"
has "named as divergence"                      "DIVERGED"               "$OUT"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
