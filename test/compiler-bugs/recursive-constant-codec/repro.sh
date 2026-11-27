#!/usr/bin/env bash
# Minimal.roc: a polymorphic constant in a recursive binding group with a
# function that encodes a record (`holder` reads `shown`, `shown` reads
# `holder`). Shapes.roc (the new test,
# test/cli/polymorphic_constant_in_recursive_group_codec.roc) has the same
# with a `where` clause and a record update, read at two types, and with
# parsing. Every run of both should pass.
#
# On upstream main (bec95b9f4a) and on rocx-fixes-5 a debug compiler stops
# in boxy_lowering at "a derived codec or map dictionary is resolved from a
# type alone, but checking records each with its plan at the dispatch it
# serves" (--specialize=no), and in Monotype at "composite scheme requirement
# had no checked call-site evidence" (--specialize=yes). A release compiler,
# where that invariant is unreachable, segfaults in boxy_lowering on some
# runs and passes on others, so each run below is repeated RUNS times (3 by
# default) and the distinct outcomes are counted. rocx-fixes-4 (the nightly
# 890d6c8 plus the fork's fixes, before polymorphic constants) passes.
#
# Unannotated.roc is a separate regression found on the way, still open
# with the fix: its --specialize=no runs crash ("adapted descriptors
# describe different kinds of value").
#
#     ROC=…/roc [RUNS=5] ./repro.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
roc=${ROC:-$(ls -d "$here"/../../../.tools/roc/roc_nightly-*/roc 2>/dev/null | head -1)}
[ -x "$roc" ] || { echo "set ROC to a roc binary"; exit 2; }
runs=${RUNS:-3}
cd "$here"
"$roc" version
outcome() {
	local out code said
	out=$("$@" 2>&1)
	code=$?
	said=$(printf '%s\n' "$out" | grep -aoE 'All \([0-9]+\) tests? passed|[0-9]+ failed|invariant violated: .{0,70}|Segmentation fault \(SIGSEGV\)|panic: .{0,70}' | head -1)
	printf 'exit %s %s' "$code" "$said"
}
run() {
	local file=$1
	shift
	local results=()
	for _ in $(seq "$runs"); do
		if [ "${FRESH_CACHE:-}" = 1 ]; then
			cache=$(mktemp -d "${TMPDIR:-/tmp}/roc-cache.XXXXXX")
			results+=("$(ROC_CACHE_DIR=$cache outcome "$roc" test "$@" "$file")")
			rm -rf "$cache"
		else
			results+=("$(outcome "$roc" test "$@" "$file")")
		fi
	done
	printf '%-16s %-44s %s\n' "$file" "$*" "$(printf '%s\n' "${results[@]}" | sort | uniq -c | sed -E 's/^ +//' | paste -sd '|' - | sed 's/|/ | /g')"
}
for file in Minimal.roc Shapes.roc Unannotated.roc; do
	run "$file" --no-cache --specialize=no --opt=dev
	run "$file" --no-cache --specialize=no --opt=interpreter
	run "$file" --no-cache --specialize=yes --opt=dev
	run "$file" --no-cache --specialize=yes --opt=interpreter
	FRESH_CACHE=1 run "$file" --specialize=no --opt=dev
done
