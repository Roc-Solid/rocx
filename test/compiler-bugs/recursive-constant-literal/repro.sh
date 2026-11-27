#!/usr/bin/env bash
# Literal.roc: a constant in a recursive binding group
# (`holder = { n: 1, run: |input| again(input) }`, where `again` reads
# `holder` back) whose field holds a number literal. Shapes.roc (the new
# test, test/cli/polymorphic_constant_in_recursive_group_literal.roc) adds
# a read of the field and a second constant whose literal a use fixes to
# U8. Alone.roc is the same without the recursion. Every run of these
# should pass, as Alone.roc does everywhere.
#
# On upstream main (bec95b9f4a), on rocx-fixes-5 and with the field-kind fix
# (fix-recursive-constant-descriptor), a debug compiler stops every boxy run
# of Literal.roc and Shapes.roc at "Dev/codegen invariant violated at
# tag_payload_struct_access.inline" while evaluating the constant at compile
# time, and every --specialize=yes run in Monotype at "measuring a closed
# checked type did not record its Monotype". rocx-fixes-4 (the nightly
# 890d6c8 plus the fork's fixes, before polymorphic constants) reports a
# type error instead ("This top-level value still has an unresolved
# polymorphic type").
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
	said=$(printf '%s\n' "$out" | grep -aoE 'All \([0-9]+\) tests? passed|[0-9]+ failed|invariant violated: .{0,70}|invariant violated at [a-z_.]+|Segmentation fault \(SIGSEGV\)|panic: .{0,90}|unresolved polymorphic type' | head -1)
	printf '%-12s %-45s exit %-3s %s\n' "$file" "$*" "$code" "$said"
}
for file in Literal.roc Shapes.roc Alone.roc; do
	run "$file" --no-cache
	run "$file" --no-cache --specialize=no --opt=dev
	run "$file" --no-cache --specialize=no --opt=interpreter
	run "$file" --no-cache --specialize=yes
	run "$file" --no-cache --specialize=yes --opt=interpreter
	cache=$(mktemp -d "${TMPDIR:-/tmp}/roc-cache.XXXXXX")
	ROC_CACHE_DIR=$cache run "$file" --specialize=no --opt=dev
	rm -rf "$cache"
done
