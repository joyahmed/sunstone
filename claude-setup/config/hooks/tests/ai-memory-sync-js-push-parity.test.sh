#!/usr/bin/env bash
# Parity battery for ai-memory-sync.js - the Windows/Node twin of ai-memory-sync.sh.
#
# WHY THIS FILE EXISTS. ai-memory-sync-failure-classes.test.sh pins the .sh
# hook's push-retry reporting (cases 13-15), added after a live bug: a Mac's
# SessionStart printed "MEMORY SYNC FAILED" for a remote that answered fine,
# with 2 local commits sitting unpushed - a plain `git push` cleared it
# instantly. The .sh hook already distinguished "reachable but the push
# failed" from "genuinely offline"; the .js twin did not - it pushed once,
# swallowed a failure with no diagnosis, and reported nothing beyond a generic
# ahead/behind count with no reachability check at all. A Windows box running
# THIS file is the same bug wearing a different extension, so it gets the same
# four assertions, ported to node.
#
#   bash ai-memory-sync-js-push-parity.test.sh     (NODE=/path/to/node, HOOK=/path/to/ai-memory-sync.js)
#
# ⛔ EVERY CASE RUNS UNDER A FAKE $HOME AND A FIXTURE REPO. The hook finds its
# repo through $HOME/.claude/ai-memory-path, so a fake HOME is the whole
# isolation - nothing here touches the real memory repo.
#
# ⚠️ A MISSING PREREQUISITE EXITS 2, NOT 0 - "could not run the battery" must
# never be reported as "the hook is fine". 0 = green, 1 = a real failure,
# 2 = did not run.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="${HOOK:-$HERE/../ai-memory-sync.js}"

NODE="${NODE:-node}"
if ! "$NODE" --version >/dev/null 2>&1; then
	for cand in "${NVM_BIN:-}/node" /usr/local/bin/node /usr/bin/node /opt/homebrew/bin/node \
	            "${NVM_DIR:-${HOME:-}/.nvm}"/versions/node/*/bin/node; do
		[ -x "$cand" ] && { NODE="$cand"; break; }
	done
fi
"$NODE" --version >/dev/null 2>&1 || { echo "no node interpreter that runs - set NODE=/path/to/node"; exit 2; }
[ -f "$HOOK" ] || { echo "hook not found beside the test: $HOOK"; exit 2; }
for t in git mktemp; do
	command -v "$t" >/dev/null 2>&1 || { echo "no $t - the hook cannot be exercised"; exit 2; }
done

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_TERMINAL_PROMPT=0
unset GIT_DIR GIT_WORK_TREE 2>/dev/null || true

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/ai-memory-sync-js-test.XXXXXX") || {
	echo "could not create a temp dir - refusing to run against the real \$HOME"; exit 2; }
cleanup() { [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT INT TERM HUP

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n         want: %s\n         got:  %s\n' "$1" "$2" "$3"; }
clip() { printf '%s' "$1" | tr '\n' '|' | cut -c1-500; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "output contains '$2'" "$(clip "$3")" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1" "output does NOT contain '$2'" "$(clip "$3")" ;; *) ok "$1" ;; esac; }
eq()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

# build - a fake $HOME, a bare "remote", and a clone carrying a memory file,
# already pushed and TRACKING (so @{u} resolves) - same shape as the .sh
# battery's fixture, minus the shim machinery this file does not need.
FHOME="" REPO="" UP=""
build() {
	FHOME=$(mktemp -d "$TMPROOT/home.XXXXXX") || return 1
	mkdir -p "$FHOME/.claude"
	UP="$FHOME/up.git"; REPO="$FHOME/memory"
	git init -q --bare -b main "$UP"
	git init -q -b main "$REPO"
	git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
	mkdir -p "$REPO/claude-setup/memory"
	printf '# ABOUT-ME\n\nproves the injection ran\n' > "$REPO/claude-setup/memory/ABOUT-ME.md"
	git -C "$REPO" add -A >/dev/null 2>&1
	git -C "$REPO" commit -qm seed >/dev/null 2>&1
	git -C "$REPO" remote add origin "$UP" >/dev/null 2>&1
	git -C "$REPO" push -q -u origin main >/dev/null 2>&1 || return 1
	# Windows / Git Bash: node needs a native path, not /tmp/... (cygpath -m); plain path elsewhere.
	if command -v cygpath >/dev/null 2>&1; then printf '%s\n' "$(cygpath -m "$REPO")" > "$FHOME/.claude/ai-memory-path"
	else printf '%s\n' "$REPO" > "$FHOME/.claude/ai-memory-path"; fi
}

ahead_locally() {
	printf 'a commit only this clone has\n' >> "$REPO/claude-setup/memory/ABOUT-ME.md"
	git -C "$REPO" commit -qam "local-only memory commit" >/dev/null 2>&1
}

# Windows / Git Bash: node's os.homedir() reads USERPROFILE, so set it too or the hook hits the REAL repo.
runhook() {
	if [ -z "${HOME_CHECKED:-}" ]; then
		# Safety self-check: never run the hook if node's homedir is not under the fake HOME.
		NH=$(HOME="$FHOME" USERPROFILE="$FHOME" "$NODE" -e "process.stdout.write(require('os').homedir())" 2>/dev/null)
		NU=$NH; command -v cygpath >/dev/null 2>&1 && [ -n "$NH" ] && NU=$(cygpath -u "$NH")
		case "$NU" in "$FHOME"/*|"$FHOME") ;; *) echo "ABORT: node homedir [$NH] is not under fake HOME [$FHOME] - would touch the real repo"; exit 1 ;; esac
	fi
	OUT=$(HOME="$FHOME" USERPROFILE="$FHOME" "$NODE" "$HOOK" 2>&1 </dev/null); RC=$?
}
OUT=""; RC=0

# ===========================================================================
echo "case 1 - ahead of upstream, remote healthy: the push happens and stays SILENT"
# ⛔ INVERSE CONTROL. A notice on a healthy push is the failure this file
# exists to prevent from hiding a real one.
build || { echo "fixture failed"; exit 2; }
ahead_locally
runhook
eq    "exit 0"                       0  "$RC"
hasnt "no WARNING on a healthy push" "WARNING" "$OUT"
eq    "and the push really happened" "0" \
      "$(git -C "$REPO" rev-list --count '@{u}..HEAD' 2>/dev/null)"

echo
echo "case 2 - ahead of upstream, push REJECTED, remote reachable ⇒ LOUD, named as a push"
# The live bug: the remote answers fine but the PUSH fails. A count-only
# 'MEMORY IS NOT IN SYNC' with no reachability check must not be the whole
# story here.
build || { echo "fixture failed"; exit 2; }
ahead_locally
cat > "$UP/hooks/pre-receive" <<'EOF'
#!/bin/sh
echo "remote: refusing this push, testing" >&2
exit 1
EOF
chmod +x "$UP/hooks/pre-receive"
runhook
eq  "exit 0 - never fatal"                               0  "$RC"
has "reported, not swallowed"                            "MEMORY SYNC FAILED"                      "$OUT"
has "it says the remote IS reachable"                    "remote IS reachable"                     "$OUT"
has "named as a push, not a pull"                        "the push of this clone's memory commits" "$OUT"
has "git's own rejection reaches the session"            "refusing this push, testing"             "$OUT"
has "the memory is still injected alongside the warning" "proves the injection ran"                "$OUT"
eq  "the commit is still stranded locally (retry also failed)" "1" \
    "$(git -C "$REPO" rev-list --count '@{u}..HEAD' 2>/dev/null)"

echo
echo "case 3 - ahead of upstream, remote UNREACHABLE ⇒ quiet, marked stale, not FAILED"
# Being offline is normal. An unreachable remote fails the pull before the
# push is even attempted, so the report names the pull - still the quiet,
# non-alarming branch a machine with no network must get.
build || { echo "fixture failed"; exit 2; }
ahead_locally
git -C "$REPO" remote set-url origin "git://nope.invalid/nope.git"   # .invalid never resolves; see case 4
runhook
eq    "exit 0"                               0  "$RC"
has   "marked stale, not failed"             "MEMORY MAY BE STALE"  "$OUT"
has   "did not go through"                   "did not go through"   "$OUT"
hasnt "offline is NOT reported as a failure" "MEMORY SYNC FAILED"   "$OUT"
eq    "the commit stays stranded, silently"  "1" \
      "$(git -C "$REPO" rev-list --count '@{u}..HEAD' 2>/dev/null)"

echo
echo "case 4 - nothing ahead or behind ⇒ silent"
build || { echo "fixture failed"; exit 2; }
runhook
eq    "exit 0"          0  "$RC"
hasnt "no WARNING"       "WARNING" "$OUT"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
