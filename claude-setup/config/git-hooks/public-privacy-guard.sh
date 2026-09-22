#!/bin/sh
# public-privacy-guard - refuse to commit personal content into a PUBLIC repo.
#
# WHY: a framework repo is world-readable, and the material an assistant writes
# into it drifts personal without anyone deciding to. It happened here: a hook
# file shipped with its author's first name and a dated verbatim quote in the
# header comment and again in the string it printed at runtime. Nobody chose
# that; it was written the way a private note is written, and pushed.
#
# Stating the rule was not enough for AI co-author trailers either - that one
# is enforced by a git hook, and this is the same shape of problem, so it gets
# the same answer. A rule that lives only in a memory file is a rule that gets
# re-learned after it is broken.
#
# ⚠️ THIS FILE MUST CONTAIN NO PERSONAL DATA ITSELF. It ships in the public
# repo it guards. Every pattern is derived at RUN TIME from the machine's own
# git identity and $HOME, so the guard is portable to anyone and hardcodes
# nobody. Do not add a name, an email or a path here to "make it stricter".
#
# USAGE: public-privacy-guard.sh <repo-name>   (exit 1 refuses the commit)
# Called by the global pre-commit hook, which passes the derived repo name.
#
# WHICH REPOS: space-separated PUBLIC_REPOS in the environment, else the
# single default below. Keep the default list to repos that are actually
# world-readable - guarding a private repo only trains people to use the
# override.
#
# ESCAPE HATCH: ALLOW_PERSONAL_IN_PUBLIC=1 git commit ...
# Intended for the one legitimate case - authorship - which is normally
# covered by the LICENSE/AUTHORS exemption below.

REPO="$1"
[ -n "$REPO" ] || exit 0
[ "$ALLOW_PERSONAL_IN_PUBLIC" = "1" ] && exit 0

PUBLIC_REPOS="${PUBLIC_REPOS:-sunstone}"

matched=0
for r in $PUBLIC_REPOS; do
	[ "$r" = "$REPO" ] && matched=1
done
[ "$matched" = "1" ] || exit 0

# --- what counts as personal ------------------------------------------------
# Derived, never hardcoded: the full name, the email, and the home-directory
# forms of the current user on all three platforms.
NAME=$(git config user.name 2>/dev/null)
EMAIL=$(git config user.email 2>/dev/null)
USERDIR=$(basename "${HOME:-}" 2>/dev/null)

PATTERNS=""
[ -n "$NAME" ] && PATTERNS="$PATTERNS
$NAME"
[ -n "$EMAIL" ] && PATTERNS="$PATTERNS
$EMAIL"
if [ -n "$USERDIR" ]; then
	PATTERNS="$PATTERNS
/Users/$USERDIR
/home/$USERDIR"
fi

# ⭐ ATTRIBUTION, built from the FIRST token of the name. This is the part that
# matters. A bare first name is deliberately NOT matched - it is a common
# English word in too many repos, and a guard that cries wolf gets switched
# off - but the shapes personal content actually TAKES in source are matched:
#
#     "<First>, 2026-09-21: \"...\""      a dated verbatim quote
#     "<First> said ..."                  attribution in a runtime string
#     "<First>'s ..."                     possessive
#
# ⚠️ The first version of this guard matched only the full name, the email and
# the home paths - and was therefore BLIND to the exact commit that prompted
# writing it, whose line read `// <First>, <date>: "..."`. It was tested
# against that real line, found to miss it, and this block is the fix. A check
# that shares a blind spot with the thing it checks reports green.
FIRST=$(printf '%s\n' "$NAME" | awk '{print $1}' | tr -cd '[:alnum:]')
ATTRIB=""
if [ -n "$FIRST" ]; then
	ATTRIB="(^|[^[:alnum:]])${FIRST}(,[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}|'s[^[:alnum:]]|[[:space:]]+(said|says|asked|wants|wanted|prefers|told|decided)[^[:alnum:]])"
fi

[ -n "$PATTERNS" ] || [ -n "$ATTRIB" ] || exit 0

# --- what is exempt ---------------------------------------------------------
# Authorship is the one place a real name belongs, and the stated rule is "my
# name only as the fact that I created it". So the files whose entire job is to
# say who wrote this are never scanned.
is_exempt() {
	case "$(basename "$1")" in
		LICENSE|LICENSE.*|LICENCE|LICENCE.*|COPYING|COPYING.*|AUTHORS|AUTHORS.*|NOTICE|NOTICE.*) return 0 ;;
	esac
	return 1
}

# --- scan only ADDED lines in the staged diff -------------------------------
# Added lines, not whole files: a file that already carries an old occurrence
# must not block every future edit to it. Removing personal content is always
# allowed, which is what makes a forward fix possible.
TMPF="${TMPDIR:-/tmp}/.ppg.$$"
: > "$TMPF" 2>/dev/null || exit 0

for f in $(git diff --cached --name-only --diff-filter=ACM 2>/dev/null); do
	is_exempt "$f" && continue
	added=$(git diff --cached -U0 -- "$f" 2>/dev/null | sed -n 's/^+//p')
	[ -n "$added" ] || continue

	printf '%s\n' "$PATTERNS" | while IFS= read -r pat; do
		[ -n "$pat" ] || continue
		if printf '%s\n' "$added" | grep -Fq -- "$pat"; then
			printf '%s\t%s\n' "$f" "$pat" >> "$TMPF"
		fi
	done

	if [ -n "$ATTRIB" ]; then
		if printf '%s\n' "$added" | grep -Eq -- "$ATTRIB"; then
			printf '%s\tattribution to %s (name+date, possessive, or "%s said")\n' \
				"$f" "$FIRST" "$FIRST" >> "$TMPF"
		fi
	fi
done

FOUND=$(cat "$TMPF" 2>/dev/null)
rm -f "$TMPF" 2>/dev/null

[ -n "$FOUND" ] || exit 0

echo "⛔ pre-commit: refusing to put PERSONAL CONTENT in a public repo ($REPO)"
echo
echo "   These staged lines carry your own identity into a world-readable repo:"
echo
printf '%s\n' "$FOUND" | while IFS="$(printf '\t')" read -r file pat; do
	printf '     %s  ← %s\n' "$file" "$pat"
done
echo
echo "   A public framework file should state its requirement, not attribute it"
echo "   to a person. Rewrite the line so it names no one:"
echo
echo "     \"<name>, <date>: \\\"if i say X you do Y\\\"\"  →  \"The requirement: if the user types X, ...\""
echo "     \"<name> said ...\"                         →  \"The user said ...\""
echo
echo "   Authorship belongs in LICENSE / AUTHORS, which this guard never scans."
echo "   Removing an existing occurrence is always allowed - only ADDED lines"
echo "   are checked, so a forward fix is never blocked."
echo
echo "   Genuinely intended:  ALLOW_PERSONAL_IN_PUBLIC=1 git commit ..."
echo "   Change the list:     PUBLIC_REPOS=\"a b\" in the environment"
exit 1
