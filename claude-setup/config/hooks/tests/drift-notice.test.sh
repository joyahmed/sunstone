#!/usr/bin/env bash
# Regression battery for drift-notice.sh.
#
# ⚠️ Runs the SessionStart hook against a FAKE framework checkout - a
# scratch directory carrying a stand-in claude-setup/scripts/drift-check.sh
# that prints known output and exits with a chosen code - never the real
# framework or the real drift-check.sh, so this battery is not at the mercy
# of whatever drift the machine running it happens to have.
#
#   bash drift-notice.test.sh
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="${HOOK:-$HERE/../drift-notice.sh}"
[ -f "$HOOK" ] || { echo "hook not found beside the test: $HOOK"; exit 2; }
command -v bash >/dev/null 2>&1 || { echo "no bash"; exit 2; }

_tmp="${TMPDIR:-/tmp}"; _tmp="${_tmp%/}"; [ -n "$_tmp" ] || _tmp=/tmp
TMPROOT=$(mktemp -d "$_tmp/drift-notice-test.XXXXXX") || { echo "could not create a temp dir"; exit 2; }
cleanup() { [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT INT TERM HUP

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n         want: %s\n         got:  %s\n' "$1" "$2" "$3"; }

# mk_framework <exit-code> <stdout> -> a scratch dir carrying a fake drift-check.sh
mk_framework() {
	fw=$(mktemp -d "$TMPROOT/fw.XXXXXX")
	mkdir -p "$fw/claude-setup/scripts"
	cat > "$fw/claude-setup/scripts/drift-check.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$2"
exit $1
EOF
	chmod +x "$fw/claude-setup/scripts/drift-check.sh"
	printf '%s' "$fw"
}

# run <home> <sunstone-path-target> [EXTRA_ENV=val ...] -> hook's stdout
run() {
	h="$1"; fw="$2"; shift 2
	printf '%s\n' "$fw" > "$h/.claude/sunstone-path"
	out=$(env -i HOME="$h" PATH="$PATH" "$@" bash "$HOOK" 2>&1)
	printf '%s' "$out"
}

echo "clean (exit 0) - silent:"
h=$(mktemp -d "$TMPROOT/home.XXXXXX"); mkdir -p "$h/.claude"
fw=$(mk_framework 0 "drift-check: clean")
out=$(run "$h" "$fw")
[ -z "$out" ] && ok "clean => silent" || bad "clean => silent" "" "$out"

echo "drift found (exit 1, a flagged line) - injects it:"
h=$(mktemp -d "$TMPROOT/home.XXXXXX"); mkdir -p "$h/.claude"
fw=$(mk_framework 1 "drift-check: /home/user
  ! hooks: 3/5 linked - re-run setup

drift-check: 1 item(s) flagged")
out=$(run "$h" "$fw")
case "$out" in
	*"hooks: 3/5 linked"*) ok "flagged line present" ;;
	*) bad "flagged line present" "hooks: 3/5 linked" "$out" ;;
esac
case "$out" in
	*additionalContext*) ok "carries additionalContext (or plain text fallback)" ;;
	*"hooks: 3/5"*) ok "carries additionalContext (or plain text fallback)" ;;
	*) bad "carries additionalContext (or plain text fallback)" "additionalContext" "$out" ;;
esac

echo "DRIFT_NOTICE=off - silent even with drift:"
h=$(mktemp -d "$TMPROOT/home.XXXXXX"); mkdir -p "$h/.claude"
fw=$(mk_framework 1 "  ! something flagged")
out=$(run "$h" "$fw" DRIFT_NOTICE=off)
[ -z "$out" ] && ok "DRIFT_NOTICE=off => silent" || bad "DRIFT_NOTICE=off => silent" "" "$out"

echo "no framework found - silent, never fails session start:"
# ⚠️ Run an ISOLATED COPY of the hook, not $HOOK in place: $HOOK lives inside a
# real sunstone checkout, so its own-location candidate would find the REAL
# drift-check.sh and this case would test nothing.
h=$(mktemp -d "$TMPROOT/home.XXXXXX"); mkdir -p "$h/.claude"
iso=$(mktemp -d "$TMPROOT/isolated.XXXXXX")
cp "$HOOK" "$iso/drift-notice.sh"
out=$(env -i HOME="$h" PATH="$PATH" bash "$iso/drift-notice.sh" 2>&1); rc=$?
[ -z "$out" ] && [ "$rc" = "0" ] && ok "no framework => silent, exit 0" || bad "no framework => silent, exit 0" "'' rc=0" "'$out' rc=$rc"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
