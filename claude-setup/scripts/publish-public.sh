#!/usr/bin/env bash
# publish-public.sh - release a clean copy of this repo to the PUBLIC repo.
#
# Run BY HAND. Two modes:
#   (no flag)  dry run: export HEAD, strip, self-test the scanner, scan. Changes nothing outside
#              the staging folder. Prints the two commands that publish.
#   --push     same checks again, then ONE commit (author = GitHub noreply identity) pushed to
#              the public repo. Never force. A later release adds one commit on top of public main.
#
# Options:  --staging DIR   staging folder (default ~/projects/03_ai/sunstone-public-staging)
#           --release LABEL commit subject "Release LABEL" (default: today's date)
#
# This file is itself part of the exported tree, so it must pass its own scan: every bad word the
# scanner looks for is assembled at runtime from fragments. Keep it that way.
#
# Strip list: publish-public.strip, next to this script.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
STRIP_FILE="$HERE/publish-public.strip"
PUBLIC_REPO="joyahmed/sunstone"
PUBLIC_URL="git@github.com:${PUBLIC_REPO}.git"
DESCRIPTION="Your agent's memory is a git repo you own: hooks, skills and a memory sync for Claude Code."
MARKER=".publish-staging"
STAGE="$HOME/projects/03_ai/sunstone-public-staging"
LABEL=$(date +%F)
PUSH=0

die() { echo "REFUSED: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --push) PUSH=1 ;;
    --staging) STAGE="${2:?--staging needs a folder}"; shift ;;
    --release) LABEL="${2:?--release needs a label}"; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

command -v python3 >/dev/null || die "python3 not found"

# ---------------------------------------------------------------- scanner (python3, stdlib only)
scanner() { python3 -I - "$@" <<'PY'
import os, re, sys, shutil, tempfile

def j(*p): return ''.join(p)

IDENT_PLACEHOLDER = r'(?!(?:user|you|runner|name|username|example|\$|<|\*|\{|%)\b)'
RULES = {
  # secrets
  'aws_key':      r'AKIA[0-9A-Z]{16}',
  'gh_token':     r'\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}',
  'ai_key':       r'\bsk-(?:ant-)?[A-Za-z0-9_-]{20,}',
  'slack_token':  r'xox[abprs]-[A-Za-z0-9-]{10,}',
  'google_key':   r'AIza[0-9A-Za-z_-]{35}',
  'private_key':  r'-----BEGIN [A-Z ]*PRIV' r'ATE KEY',
  'conn_string':  r'[a-z+]+://[^\s/:@\'"]+:[^\s/@\'"]{3,}@',
  'assign_secret': r'(?i)(?:password|passwd|secret|api[_-]?key|token|auth[_-]?key)\s*[:=]\s*[\'"][^\'"\s$<{]{12,}[\'"]',
  'bearer':       r'(?i)bearer\s+[A-Za-z0-9._-]{24,}',
  'jwt':          r'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.',
  'dotenv_secret': r'^(?:DATABASE_URL|JWT_SECRET|[A-Z_]*SECRET[A-Z_]*|[A-Z_]*TOKEN)=\S{8,}',
  # personal / infra (email and ipv4 are filtered further below)
  'email':        r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
  'ipv4':         r'\b(?:\d{1,3}\.){3}\d{1,3}\b',
  # box names
  'box_steph':    r'\b[Ss]' r'teph\b',
  'box_ana':      r'\bAn' r'a\b',
  'box_meli':     r'(?i)\bme' r'li\b',
  'box_alina':    r'(?i)\bal' r'ina\b',
  'box_joyr5':    r'(?i)\bjoy' r'r5\b',
  'box_joyr9':    r'(?i)\bjoy' r'r9\b',
  'box_server':   r'(?i)zetta' r'server',
  # private repo names
  'repo_memory':  r'(?i)every' r'thing-j' r'oy',
  'repo_hrm':     r'(?i)zetta-' r'hrm',
  'repo_devcli':  r'(?i)zetta-' r'dev-cli',
  'repo_private': r'(?i)sunstone-' r'private',
  'repo_app':  r'(?i)ban' r'ani',
  # the owner's name in prose or quotes (LICENSE exempt)
  'owner_name':   r'\bJ' r'oy\b',
  # home paths
  'path_home':    r'/home/' + IDENT_PLACEHOLDER + r'[A-Za-z][A-Za-z0-9._-]*',
  'path_winusers': r'[A-Za-z]:[\\/]+Users[\\/]+(?!(?:Public|Default|All|user|you|name|username)\b|[%<$*{])[A-Za-z][A-Za-z0-9._-]*',
  'path_macusers': r'/Users/(?!(?:Shared|user|you|name|username)\b|[%<$*{])[A-Za-z][A-Za-z0-9._-]*',
  # AI attribution
  'ai_coauthor':  r'(?i)co-authored-by:\s*cl' r'aude',
  'ai_session':   r'(?i)cl' r'aude-session:',
  'ai_generated': r'(?i)generated with \[?cl' r'aude code',
}
CRX = {k: re.compile(v) for k, v in RULES.items()}
SKIP_DIRS = {'.git'}
SKIP_FILES = {'.publish-staging'}

def mask(s):
    return (s[:2] + '***' if len(s) > 2 else '***') + '(%d)' % len(s)

def ip_ok(m):
    parts = m.split('.')
    if m in ('127.0.0.1', '0.0.0.0'): return True
    return any(int(p) > 255 for p in parts)

def email_ok(m):
    low = m.lower()
    dom = low.rsplit('@', 1)[1]
    return m == 'git@github.com' or 'noreply' in low or dom.startswith('example.')

def scan_line(line, relname):
    out = []
    for name, rx in CRX.items():
        if name == 'owner_name' and os.path.basename(relname) == 'LICENSE': continue
        for m in rx.finditer(line):
            s = m.group(0)
            if name == 'ipv4' and ip_ok(s): continue
            if name == 'email' and email_ok(s): continue
            out.append((name, s))
    return out

def scan_text(text, relname):
    hits = []
    for i, line in enumerate(text.splitlines(), 1):
        for name, s in scan_line(line, relname):
            hits.append((relname, i, name, s))
    return hits

def scan_tree(root):
    hits, nfiles, binary = [], 0, 0
    for dp, dns, fns in os.walk(root):
        dns[:] = sorted(d for d in dns if d not in SKIP_DIRS)
        for fn in sorted(fns):
            if fn in SKIP_FILES and dp == root: continue
            p = os.path.join(dp, fn)
            rel = os.path.relpath(p, root)
            nfiles += 1
            # path text: line 0
            for name, s in scan_line(rel, rel):
                if name == 'owner_name' and fn == 'LICENSE': continue
                hits.append((rel, 0, name, s))
            if os.path.islink(p):
                text = os.readlink(p)
            else:
                with open(p, 'rb') as f: data = f.read()
                if b'\0' in data[:8000]:
                    binary += 1; continue
                text = data.decode('utf-8', 'replace')
            hits += scan_text(text, rel)
    return hits, nfiles, binary

def planted():
    """(rule, line) pairs, every bad value assembled at runtime."""
    A = 'a'
    return [
      ('aws_key', 'k = ' + 'AK' + 'IA' + 'ABCDEFGH' + 'IJKLMNOP'),
      ('gh_token', 'g = ' + 'gh' + 'p_' + A * 36),
      ('ai_key', 'a = ' + 's' + 'k-' + 'ant-' + A * 24),
      ('slack_token', 's = ' + 'xo' + 'xb-' + '1234567890' + '-abcdef'),
      ('google_key', 'k = ' + 'AI' + 'za' + A * 35),
      ('private_key', '-----BEGIN RSA ' + 'PRIV' + 'ATE KEY-----'),
      ('conn_string', 'db = ' + 'postgres' + '://' + 'dbuser' + ':' + 'hunter22' + '@' + 'dbhost/x'),
      ('assign_secret', 'pass' + 'word = "' + 'Zx9' + A * 14 + '"'),
      ('bearer', 'Authorization: Bear' + 'er ' + A * 30),
      ('jwt', 'eyJ' + A * 12 + '.' + 'eyJ' + A * 12 + '.sig'),
      ('dotenv_secret', 'JWT_' + 'SECRET=' + A * 12),
      ('email', 'mail ' + 'someone' + '@' + 'corp' + '.com'),
      ('ipv4', 'host ' + '203.0.113.' + '7'),
      ('box_steph', 'box ' + 'St' + 'eph here'),
      ('box_ana', 'box ' + 'An' + 'a here'),
      ('box_meli', 'box ' + 'Me' + 'li here'),
      ('box_alina', 'box ' + 'Al' + 'ina here'),
      ('box_joyr5', 'box ' + 'Jo' + 'yR5 here'),
      ('box_joyr9', 'box ' + 'Jo' + 'yR9 here'),
      ('box_server', 'box ' + 'zetta' + 'server here'),
      ('repo_memory', 'repo ' + 'every' + 'thing-' + 'joy'),
      ('repo_hrm', 'repo ' + 'zetta' + '-hrm'),
      ('repo_devcli', 'repo ' + 'zetta' + '-dev-cli'),
      ('repo_private', 'repo ' + 'sunstone' + '-pri' + 'vate'),
      ('repo_app', 'repo ' + 'ban' + 'ani'),
      ('owner_name', 'he said ' + 'J' + 'oy wants it'),
      ('path_home', 'cd /ho' + 'me/' + 'alice/x'),
      ('path_winusers', 'C:' + '\\' + 'Users' + '\\' + 'alice' + '\\x'),
      ('path_macusers', 'cd /Us' + 'ers/' + 'alice/x'),
      ('ai_coauthor', 'Co-Authored-' + 'By: ' + 'Cl' + 'aude <x>'),
      ('ai_session', 'Cl' + 'aude-Session: abc'),
      ('ai_generated', 'Generated with [' + 'Cl' + 'aude Code]'),
    ]

CLEAN = [
  'hello world, nothing here',
  'mail us at someone@example.com or git@github.com',
  'author 1234+login@users.noreply.github.com',
  'listen on 127.0.0.1 and 0.0.0.0, version 300.1.1.1',
  'cd /home/user/x and /home/$USER and /Users/name/x and C:\\Users\\Public\\x',
  'password = "$VAR" and token = "<your-token>"',
]

def selftest():
    d = tempfile.mkdtemp(prefix='scanner-selftest-')
    ok = True
    try:
        pl = planted()
        missing_rules = set(RULES) - {r for r, _ in pl}
        if missing_rules:
            print('SELFTEST FAIL: rules without a planted case: ' + ', '.join(sorted(missing_rules))); ok = False
        with open(os.path.join(d, 'bad.txt'), 'w') as f: f.write('\n'.join(t for _, t in pl) + '\n')
        with open(os.path.join(d, 'clean.txt'), 'w') as f: f.write('\n'.join(CLEAN) + '\n')
        with open(os.path.join(d, 'LICENSE'), 'w') as f: f.write('Copyright ' + 'J' + 'oy\n')
        with open(os.path.join(d, 'St' + 'eph-notes.txt'), 'w') as f: f.write('ok\n')
        hits, n, _ = scan_tree(d)
        got = {(h[1], h[2]) for h in hits if h[0] == 'bad.txt'}
        silent = [r for i, (r, _) in enumerate(pl, 1) if (i, r) not in got]
        if silent:
            print('SELFTEST FAIL: silent patterns: ' + ', '.join(silent)); ok = False
        false_pos = [h for h in hits if h[0] in ('clean.txt', 'LICENSE')]
        if false_pos:
            print('SELFTEST FAIL: false positives on clean text: ' +
                  ', '.join('%s:%d:%s' % (h[0], h[1], h[2]) for h in false_pos)); ok = False
        if not any(h[0].startswith('St') and h[1] == 0 for h in hits):
            print('SELFTEST FAIL: path names are not scanned'); ok = False
        if ok:
            print('selftest ok: %d of %d patterns fired on the planted file, 0 false positives on clean text, LICENSE exemption holds, path scan fires' % (len(pl), len(RULES)))
    finally:
        shutil.rmtree(d, ignore_errors=True)
    if os.path.exists(d):
        print('SELFTEST FAIL: planted file not deleted'); ok = False
    sys.exit(0 if ok else 3)

def main():
    cmd = sys.argv[1]
    if cmd == 'selftest': selftest()
    elif cmd == 'scan':
        hits, n, binary = scan_tree(sys.argv[2])
        for rel, line, name, s in hits:
            print('HIT %s:%d  [%s]  %s' % (rel, line, name, mask(s)))
        print('SCANRESULT files=%d hits=%d binary_skipped=%d' % (n, len(hits), binary))
        sys.exit(1 if hits else 0)
main()
PY
}

# ---------------------------------------------------------------- 1. staging folder
STAGE=$(python3 -c 'import os,sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "$STAGE")
RROOT=$(realpath "$ROOT")
case "$STAGE" in
  /|"$HOME"|"$RROOT"|"$RROOT"/*) die "staging folder $STAGE is unsafe (root, home or inside the repo)" ;;
esac
case "$RROOT" in "$STAGE"/*) die "staging folder $STAGE contains the repo" ;; esac

if [ -e "$STAGE" ]; then
  [ -d "$STAGE" ] || die "$STAGE exists and is not a folder"
  if [ -n "$(ls -A "$STAGE")" ]; then
    [ -f "$STAGE/$MARKER" ] || die "$STAGE is not empty and has no $MARKER marker; not wiping it"
    find "$STAGE" -mindepth 1 -delete
  fi
else
  mkdir -p "$STAGE"
fi

# ---------------------------------------------------------------- 2. export + strip
git -C "$ROOT" archive HEAD | tar -x -C "$STAGE"
printf 'created by publish-public.sh; safe to wipe\n' > "$STAGE/$MARKER"
HEADSHORT=$(git -C "$ROOT" rev-parse --short HEAD)

if [ -f "$STRIP_FILE" ]; then
  while IFS= read -r pat || [ -n "$pat" ]; do
    pat="${pat%%#*}"; pat="${pat%"${pat##*[![:space:]]}"}"; pat="${pat#"${pat%%[![:space:]]*}"}"
    [ -n "$pat" ] || continue
    case "$pat" in /*|*..*) die "strip pattern '$pat' must be relative and have no '..'" ;; esac
    ( cd "$STAGE"; shopt -s nullglob dotglob
      for m in $pat; do rm -rf -- "$m"; echo "stripped: $m"; done )
  done < "$STRIP_FILE"
fi

# ---------------------------------------------------------------- 3. scanner self-test
echo "== scanner self-test"
scanner selftest || die "scanner self-test failed: a pattern is silent or fires on clean text; nothing was scanned"

# ---------------------------------------------------------------- 4. scan
echo "== scan $STAGE"
set +e
SCAN_OUT=$(scanner scan "$STAGE"); SCAN_RC=$?
set -e
RESULT=$(printf '%s\n' "$SCAN_OUT" | grep '^SCANRESULT ' || true)
[ -n "$RESULT" ] || die "scanner produced no result line (rc=$SCAN_RC)"
printf '%s\n' "$SCAN_OUT" | grep -v '^SCANRESULT ' || true
NFILES=${RESULT#*files=}; NFILES=${NFILES%% *}
NHITS=${RESULT#*hits=}; NHITS=${NHITS%% *}
if [ "$NHITS" != "0" ] || [ "$SCAN_RC" != "0" ]; then
  die "$NHITS hit(s) in the staging tree (HEAD $HEADSHORT). Fix them at the source and commit; nothing was published."
fi

if [ "$PUSH" = 0 ]; then
  echo
  echo "ready: $NFILES files, 0 hits  (HEAD $HEADSHORT, staging $STAGE)"
  echo
  echo "To publish, run these two yourself, from the repo folder:"
  echo "  1. (first release only)"
  echo "     gh repo create $PUBLIC_REPO --public --disable-wiki --description \"$DESCRIPTION\""
  echo "  2. bash claude-setup/scripts/publish-public.sh --push"
  exit 0
fi

# ---------------------------------------------------------------- 5. --push
command -v gh >/dev/null || die "gh not found"
INFO=$(gh repo view "$PUBLIC_REPO" --json visibility,name,nameWithOwner) \
  || die "repo $PUBLIC_REPO does not exist (or gh cannot see it). Create it first (command 1 above)."
python3 -I -c '
import json,sys
d=json.loads(sys.argv[1]); want=sys.argv[2]
bad=[]
if d.get("name")!="sunstone": bad.append("name is %r, expected \"sunstone\" (a rename redirect points elsewhere)" % d.get("name"))
if d.get("nameWithOwner")!=want: bad.append("resolved to %r, expected %r" % (d.get("nameWithOwner"),want))
if str(d.get("visibility")).upper()!="PUBLIC": bad.append("visibility is %r, must be PUBLIC" % d.get("visibility"))
if bad: print("; ".join(bad)); sys.exit(1)
' "$INFO" "$PUBLIC_REPO" || die "target repo check failed (see line above)"

UID_NUM=$(gh api user -q .id); LOGIN=$(gh api user -q .login)
case "$UID_NUM" in ''|*[!0-9]*) die "could not read the numeric GitHub user id" ;; esac
[ "$LOGIN" = "${PUBLIC_REPO%%/*}" ] || die "gh is logged in as '$LOGIN', not the owner of $PUBLIC_REPO"
ID_NAME=$(git -C "$ROOT" config user.name || true); ID_NAME=${ID_NAME:-$LOGIN}
ID_MAIL="${UID_NUM}+${LOGIN}@users.noreply.github.com"
MSG="Release $LABEL"

cd "$STAGE"
GIT=(git -c core.hooksPath=/dev/null)   # fresh sterile repo: no machine-wide hooks
"${GIT[@]}" init -q -b main
mkdir -p .git/info; printf '%s\n' "$MARKER" >> .git/info/exclude
"${GIT[@]}" remote add public "$PUBLIC_URL"
if "${GIT[@]}" ls-remote --exit-code --heads public main >/dev/null 2>&1; then
  "${GIT[@]}" fetch -q public main
  "${GIT[@]}" reset -q --mixed FETCH_HEAD          # history = public main; files = new export
  echo "public main exists: adding one commit on top of $(git rev-parse --short FETCH_HEAD)"
else
  echo "public main is empty: this is the first release (one root commit)"
fi
"${GIT[@]}" add -A
if "${GIT[@]}" diff --cached --quiet; then
  echo "nothing new to release (public main already matches HEAD $HEADSHORT)"; exit 0
fi
GIT_AUTHOR_NAME="$ID_NAME" GIT_AUTHOR_EMAIL="$ID_MAIL" \
GIT_COMMITTER_NAME="$ID_NAME" GIT_COMMITTER_EMAIL="$ID_MAIL" \
  "${GIT[@]}" commit -q -m "$MSG"

got=$(git log -1 --format='%ae|%ce'); [ "$got" = "$ID_MAIL|$ID_MAIL" ] || die "commit identity is '$got', expected noreply"
git log -1 --format=%B | grep -qiE '^(co-authored-by|[a-z]+-session):|generated with' && die "commit message carries a trailer"

"${GIT[@]}" push public main
echo "published: $MSG -> $PUBLIC_REPO main ($(git rev-parse --short HEAD), $NFILES files)"
