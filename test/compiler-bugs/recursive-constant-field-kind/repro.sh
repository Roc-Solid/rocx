#!/usr/bin/env bash
# Unannotated.roc: an unannotated constant in a recursive binding group
# (`holder = { run: |_context, input| again(input) }`, where `again` reads
# `holder` back). NoContext.roc is the same without the unused parameter.
# Shapes.roc (the new test,
# test/cli/polymorphic_constant_in_recursive_group_field_kinds.roc) adds a
# constant with a data field and two function fields, a second context type
# and a use at an optional kind. Every run of these three should pass.
#
# On upstream main (bec95b9f4a) and on rocx-fixes-5 the boxy runs (the
# default, --specialize=no with --opt=dev or --opt=interpreter, and test
# units from a fresh cache) crash while computing the constant's instances
# at compile time: a debug compiler stops at "boxy runtime invariant
# violated: adapted descriptors describe different kinds of value"; a
# release compiler segfaults. --specialize=yes passes. rocx-fixes-4 (the
# nightly 890d6c8 plus the fork's fixes, before polymorphic constants)
# passes Unannotated.roc and NoContext.roc.
#
# Forwarded.roc and Literal.roc are NOT this bug and stay open with the fix
# (see the comments in each).
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
	said=$(printf '%s\n' "$out" | grep -aoE 'All \([0-9]+\) tests? passed|[0-9]+ failed|invariant violated: .{0,70}|Segmentation fault \(SIGSEGV\)|panic: .{0,90}|unresolved polymorphic type' | head -1)
	printf '%-16s %-45s exit %-3s %s\n' "$file" "$*" "$code" "$said"
}
for file in Unannotated.roc NoContext.roc Shapes.roc Forwarded.roc Literal.roc; do
	run "$file" --no-cache
	run "$file" --no-cache --specialize=no --opt=dev
	run "$file" --no-cache --specialize=no --opt=interpreter
	run "$file" --no-cache --specialize=yes
	cache=$(mktemp -d "${TMPDIR:-/tmp}/roc-cache.XXXXXX")
	ROC_CACHE_DIR=$cache run "$file" --specialize=no --opt=dev
	rm -rf "$cache"
done
