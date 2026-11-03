#!/usr/bin/env bash
# run-all.sh - run every *.test.sh in this directory and aggregate the result.
#
# Deliberately nothing more than a loop. Each battery beside it is standalone and
# stays standalone - that is how they get run while a hook is being worked on, and
# a runner that became the only way in would take that away. This exists for the
# other moment: before a release, or on a machine that has just been set up, when
# the question is "are ALL the hooks still doing what they say".
#
# ⚠️ EXIT 2 FROM A BATTERY MEANS IT DID NOT RUN - a missing interpreter, a missing
# hook file - and it is reported as SKIP, counted separately, and called out at the
# end. It is NOT folded into the pass count: a battery that silently did not run is
# the same class of failure as a hook that silently did not run, which is what all
# of this exists to end.
#
#   bash run-all.sh          (NODE=/path/to/node is passed through to the batteries)
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

ran=0; ok=0; bad=0; skipped=0
failed_names=""; skipped_names=""

for test in "$HERE"/*.test.sh; do
	[ -f "$test" ] || continue          # the glob itself when the directory is empty
	name=$(basename "$test")
	ran=$((ran+1))
	echo "=== $name"
	bash "$test"
	rc=$?
	case "$rc" in
		0) ok=$((ok+1)) ;;
		2) skipped=$((skipped+1)); skipped_names="$skipped_names $name" ;;
		*) bad=$((bad+1)); failed_names="$failed_names $name" ;;
	esac
	echo
done

echo "======================================================"
printf '%d batteries: %d green, %d failed, %d did not run\n' "$ran" "$ok" "$bad" "$skipped"
[ -n "$failed_names" ]  && echo "failed: $failed_names"
[ -n "$skipped_names" ] && echo "⚠️ did not run (a SKIP is not a pass):$skipped_names"
[ "$bad" -eq 0 ]
