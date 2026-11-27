#!/usr/bin/env bash
# Local.roc reads a polymorphic constant (`holder = { run: |x| x }`) inside a
# local function whose type mentions only its enclosing function's variable
# (`inner = |x| [other, (holder.run)(x)]` inside `outer = |other| ...`).
# Shapes.roc (the new test, test/cli/polymorphic_constant_read_in_monomorphic_local.roc)
# has the same read in a local that is called, passed as a function value,
# and called from another such local. Every run should pass.
#
# On upstream main (bec95b9f4a) and on rocx-fixes-5 the boxy runs (the
# default, --specialize=no with --opt=dev or --opt=interpreter, and test
# units from a fresh cache) crash the compiler in boxy_lowering: a release
# compiler segfaults; a debug one stops at "Boxy lowering invariant
# violated: an edge's 0 literal arguments do not cover its callee's 1
# literal requirements". --specialize=yes passes on a release compiler, but
# a debug one stops in Monotype at "a read of polymorphic constant root 0
# names no instance (edge use)". On rocx-fixes-4 (the nightly 890d6c8 plus
# the fork's fixes, before polymorphic constants) every run of Local.roc
# passes; Shapes.roc reads `holder` at three types, which only a polymorphic
# constant allows, so there it is a type error.
#
#     ROC=…/roc ./repro.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
roc=${ROC:-$(ls -d "$here"/../../../.tools/roc/roc_nightly-*/roc 2>/dev/null | head -1)}
[ -x "$roc" ] || { echo "set ROC to a roc binary"; exit 2; }
cd "$here"
"$roc" version
run() {
	local file=$1
	shift
	out=$("$roc" test "$@" "$file" 2>&1)
	code=$?
	said=$(printf '%s\n' "$out" | grep -aoE 'All \([0-9]+\) tests? passed|[0-9]+ failed|invariant violated: .*|Segmentation fault \(SIGSEGV\)|panic: .*' | head -1)
	stage=$(printf '%s\n' "$out" | grep -aoE '^ +post-check +[a-z_]+' | sed -E 's/ +/ /g' | head -1)
	printf '%-10s %-45s exit %-3s %s%s\n' "$file" "$*" "$code" "$said" "${stage:+ (in$stage)}"
}
for file in Local.roc Shapes.roc; do
	run "$file" --no-cache
	run "$file" --no-cache --specialize=no --opt=dev
	run "$file" --no-cache --specialize=no --opt=interpreter
	run "$file" --no-cache --specialize=yes
	cache=$(mktemp -d "${TMPDIR:-/tmp}/roc-cache.XXXXXX")
	ROC_CACHE_DIR=$cache run "$file" --specialize=no --opt=dev
	rm -rf "$cache"
done
