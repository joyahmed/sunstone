#!/usr/bin/env bash
# Regression battery for memory-guard.mjs (PostToolUse on Bash).
#
# WHY THIS FILE EXISTS. On 2026-10-25 the WSL VM filled its 32GB and froze.
# The guard kills automation browsers whose launcher is dead and warns the
# session when RAM runs low. A regression here either leaves leftovers alive
# again or, worse, kills a browser a test run or a person is still using - so
# the inverse controls (live parent, no automation flag, child processes) are
# half of the file. Pure-function tests: no real browser is started.
#
#   bash memory-guard.test.sh          (NODE=/path/to/node to pick an interpreter)
set -u
# ⛔ set +B: Apple's /bin/bash 3.2 BRACE-EXPANDS the {pid:..,ppid:..} objects inside
# "$(orphans "[{...}]")" - node then got '[pid:5,pid:10]', printed nothing, and the 3
# "want [10]" cases failed on the Mac only (2026-11-01). Off here; bash 5 is unaffected.
set +B
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GUARD="$HERE/../memory-guard.mjs"

NODE="${NODE:-node}"
if ! "$NODE" --version >/dev/null 2>&1; then
	for cand in "${NVM_BIN:-}/node" /usr/local/bin/node /usr/bin/node /opt/homebrew/bin/node \
	            "${NVM_DIR:-${HOME:-}/.nvm}"/versions/node/*/bin/node; do
		[ -x "$cand" ] && { NODE="$cand"; break; }
	done
fi
"$NODE" --version >/dev/null 2>&1 || { echo "no node interpreter that runs - set NODE=/path/to/node"; exit 2; }

pass=0; fail=0
ok()    { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no()    { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else no "$1  want=[$2] got=[$3]"; fi; }

# orphans <procs-js-array> -> comma list of pids the guard would kill
orphans() {
	"$NODE" --input-type=module -e "
import { findOrphans } from '$GUARD';
console.log(findOrphans($1).map((p) => p.pid).join(','));"
}
SHELL_PW='/home/user/.cache/ms-playwright/chromium_headless_shell-1228/chrome-headless-shell-linux64/chrome-headless-shell'
CHROME='/home/user/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome'

echo "browsers"
eq "orphan under pid 1 is killed" "10" \
	"$(orphans "[{pid:10,ppid:1,args:'$SHELL_PW --remote-debugging-pipe --headless'}]")"
eq "orphan under systemd --user is killed" "10" \
	"$(orphans "[{pid:5,ppid:1,args:'/usr/lib/systemd/systemd --user'},{pid:10,ppid:5,args:'$CHROME --remote-debugging-port=0'}]")"
eq "orphan under WSL /init is killed" "10" \
	"$(orphans "[{pid:7,ppid:1,args:'/init'},{pid:10,ppid:7,args:'$CHROME --remote-debugging-pipe'}]")"
eq "browser with a live node parent is kept" "" \
	"$(orphans "[{pid:9,ppid:1,args:'node run.cjs'},{pid:10,ppid:9,args:'$CHROME --remote-debugging-pipe'}]")"
eq "browser a person opened (no debugging flag) is kept" "" \
	"$(orphans "[{pid:10,ppid:1,args:'/usr/bin/chromium-browser https://example.com'}]")"
eq "renderer/gpu children (--type=) are not targeted" "" \
	"$(orphans "[{pid:11,ppid:1,args:'$CHROME --type=renderer --remote-debugging-pipe'}]")"
eq "a node script named chrome-shots is not a browser" "" \
	"$(orphans "[{pid:10,ppid:1,args:'node chrome-shots.cjs --remote-debugging-port=9222'}]")"

echo "memory"
pct() { "$NODE" --input-type=module -e "import { availablePct } from '$GUARD'; const p = availablePct(process.argv[1]); console.log(p === null ? 'null' : p.toFixed(0));" "$1"; }
eq "available percent from meminfo" "25" "$(pct $'MemTotal:       1000 kB\nMemFree:  10 kB\nMemAvailable:    250 kB')"
eq "no meminfo -> null" "null" "$(pct 'nothing here')"

echo "hook"
out=$(echo '{}' | MEMORY_GUARD=0 "$NODE" "$GUARD"); eq "MEMORY_GUARD=0 is silent" "" "$out"
out=$(echo 'not json' | MEMORY_GUARD_PCT=0 "$NODE" "$GUARD" 2>&1)
case "$out" in *rror*) no "bad input stays quiet  got=[$out]";; *) ok "bad input stays quiet";; esac

echo; echo "memory-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
