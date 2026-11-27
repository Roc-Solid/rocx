#!/usr/bin/env bash
# Forwarded.roc: a constant in a recursive binding group (`holder` reads
# `again`, which reads `holder` back), read inside a generic function
# (`forwarded = |context, input| (holder.run)(context, input)`). Fields.roc:
# the same with a field the generic function does not read. Shapes.roc (the
# new test, test/cli/polymorphic_constant_in_recursive_group_forwarded.roc)
# has both, a second context type and a forward through two generic
# functions. Every run of these should pass.
#
# With the field-kind fix (fix-recursive-constant-descriptor) and on
# rocx-fixes-5 (5ef2601bb3) the boxy runs pass, and a debug compiler stops
# every --specialize=yes run in Monotype: Forwarded.roc and Shapes.roc at
# "unresolved record field kind reached Monotype sealing", Fields.roc at "a
# read of polymorphic constant root 0 names no instance (edge use)". On
# upstream main (bec95b9f4a) a release compiler segfaults every boxy run
# (the field-kind bug, recursive-constant-descriptor) and passes
# --specialize=yes with its invariants off. rocx-fixes-4 (the nightly
# 890d6c8 plus the fork's fixes, before polymorphic constants) passes every
# run, and so does the fix.
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
	printf '%-14s %-45s exit %-3s %s\n' "$file" "$*" "$code" "$said"
}
for file in Forwarded.roc Fields.roc Shapes.roc; do
	run "$file" --no-cache
	run "$file" --no-cache --specialize=no --opt=dev
	run "$file" --no-cache --specialize=no --opt=interpreter
	run "$file" --no-cache --specialize=yes
	run "$file" --no-cache --specialize=yes --opt=interpreter
	cache=$(mktemp -d "${TMPDIR:-/tmp}/roc-cache.XXXXXX")
	ROC_CACHE_DIR=$cache run "$file" --specialize=no --opt=dev
	rm -rf "$cache"
done
