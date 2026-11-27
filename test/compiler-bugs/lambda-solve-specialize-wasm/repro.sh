#!/usr/bin/env bash
# Runs Bad.roc's one expect with lambda-set specialization (`--opt=size --specialize=yes`, and
# `--opt=speed`, whose default it is) and without it (`--opt=size --specialize=no`, `--opt=dev`).
# Each should pass. On nightly-2026-11-18-a520eed and the rocx fork's builds on it (4674b5973d),
# the specialized runs crash in `post-check lambda_solve`, while the other two pass; the fork's
# builds on nightly 890d6c8 (c69cdc3fdf, 24e2e481a8) pass all four. A release compiler's crash
# differs from run to run (mostly a segfault; at times a stack overflow, a "guarded list
# invalidated" panic, or, rarely, no crash at all), as it goes on with a broken type store; a
# debug build stops each time at "postcheck invariant violated: a scheme node was not a class
# root". So each mode runs RUNS times (3 unless set).
#
#     ROC=…/roc ./repro.sh
#     ROC=…/roc RUNS=10 ./repro.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
roc=${ROC:-$(ls -d "$here"/../../../.tools/roc/roc_nightly-*/roc 2>/dev/null | head -1)}
[ -x "$roc" ] || { echo "set ROC to a roc binary"; exit 2; }
runs=${RUNS:-3}
cd "$here"
"$roc" version
for opts in "--opt=size --specialize=yes" "--opt=speed" "--opt=size --specialize=no" "--opt=dev"; do
	for _ in $(seq "$runs"); do
		# shellcheck disable=SC2086 # $opts is two flags
		out=$("$roc" test $opts --no-cache Bad.roc 2>&1)
		code=$?
		said=$(printf '%s\n' "$out" | grep -oE 'All \([0-9]+\) tests? passed|invariant violated: .*|guarded list invalidated: [^;]*|Segmentation fault \(SIGSEGV\)|overflowed its stack|panic: .*' | head -1)
		stage=$(printf '%s\n' "$out" | grep -oE '^ +post-check +[a-z_]+' | sed -E 's/ +/ /g' | head -1)
		printf '%-28s exit %-3s %s%s\n' "$opts" "$code" "$said" "${stage:+ (in$stage)}"
	done
done
