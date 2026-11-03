#!/usr/bin/env bash
# Regression battery for the "permissions.allow" rule of merge-settings-template
# (.py and .mjs, which must behave identically).
#
# The rule: a template can only ADD allow rules (exact-string, appended, never
# removed or reordered). deny / ask / defaultMode / additionalDirectories are
# never read or written, so a template can never weaken a box's own permissions.
# Each case runs against BOTH ports and also asserts the two outputs are equal.
#
#   bash merge-settings-permissions.test.sh
#
# ⚠️ A MISSING PREREQUISITE EXITS 2, NOT 0. 0 = green, 1 = a real failure,
# 2 = did not run.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PY="$HERE/../../merge-settings-template.py"
MJS="$HERE/../../merge-settings-template.mjs"

[ -f "$PY" ] && [ -f "$MJS" ] || { echo "merger not found beside the test"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found"; exit 2; }
command -v node >/dev/null 2>&1 || { echo "node not found"; exit 2; }

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/merge-perm-test.XXXXXX") || {
	echo "could not create a temp dir"; exit 2; }
cleanup() { [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT INT TERM HUP

pass=0; fail=0
ok()    { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()   { fail=$((fail+1)); printf '  FAIL %s\n         want: %s\n         got:  %s\n' "$1" "$2" "$3"; }
t()     { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

# jq-free JSON read: print a compact JSON value at a python expression on `d`.
get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(eval(sys.argv[2]),separators=(",",":")))' "$1" "$2"; }

TPL="$TMPROOT/tpl.json"
cat > "$TPL" <<'J'
{"permissions":{"allow":["Bash(git push:*)","Bash(ls:*)"],"deny":["Bash(rm:*)"],"ask":["Bash(curl:*)"],"defaultMode":"bypassPermissions","additionalDirectories":["/x"]}}
J

# run <port> <settings-file> -> sets OUT
run() { case "$1" in py) OUT=$(python3 "$PY" "$2" "$TPL" 2>&1) ;; mjs) OUT=$(node "$MJS" "$2" "$TPL" 2>&1) ;; esac; }

for port in py mjs; do
	echo "[$port]"
	S="$TMPROOT/$port-a.json"

	# target without permissions (file missing) gets it created, allow only
	rm -f "$S"; run $port "$S"
	t "$port: creates permissions.allow" '["Bash(git push:*)","Bash(ls:*)"]' "$(get "$S" 'd["permissions"]["allow"]')"
	t "$port: only the allow key is written" '["allow"]' "$(get "$S" 'list(d["permissions"].keys())')"
	t "$port: one line per added rule" 2 "$(printf '%s\n' "$OUT" | grep -c 'added permissions.allow')"

	# second run = no change
	run $port "$S"
	t "$port: second run prints no change" "  no change" "$OUT"

	# existing entries kept, in order; only the missing rule is appended
	printf '{"permissions":{"allow":["Bash(ls:*)","Zed"],"deny":["Bash(sudo:*)"],"defaultMode":"default"},"model":"x"}' > "$S"
	run $port "$S"
	t "$port: keeps order, appends missing, no duplicate" '["Bash(ls:*)","Zed","Bash(git push:*)"]' "$(get "$S" 'd["permissions"]["allow"]')"
	t "$port: reports only the added rule" "  added permissions.allow: Bash(git push:*)" "$OUT"
	t "$port: target deny untouched" '["Bash(sudo:*)"]' "$(get "$S" 'd["permissions"]["deny"]')"
	t "$port: target defaultMode untouched" '"default"' "$(get "$S" 'd["permissions"]["defaultMode"]')"
	t "$port: template ask not copied" 'false' "$(get "$S" '"ask" in d["permissions"]')"
	t "$port: template additionalDirectories not copied" 'false' "$(get "$S" '"additionalDirectories" in d["permissions"]')"
	t "$port: other keys kept" '"x"' "$(get "$S" 'd["model"]')"

	# target with permissions but no allow: deny/defaultMode ignored from template
	printf '{"permissions":{"ask":["Mine"]}}' > "$S"
	run $port "$S"
	t "$port: allow created beside existing keys" '{"ask":["Mine"],"allow":["Bash(git push:*)","Bash(ls:*)"]}' "$(get "$S" 'd["permissions"]')"
done

# parity: identical output files from the same input
printf '{"permissions":{"allow":["Zed"]},"hooks":{}}' > "$TMPROOT/p1.json"
cp "$TMPROOT/p1.json" "$TMPROOT/p2.json"
python3 "$PY" "$TMPROOT/p1.json" "$TPL" >/dev/null
node "$MJS" "$TMPROOT/p2.json" "$TPL" >/dev/null
t "py and mjs write identical files" "$(cat "$TMPROOT/p1.json")" "$(cat "$TMPROOT/p2.json")"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
