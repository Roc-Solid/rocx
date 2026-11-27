#!/usr/bin/env bash
# Runs each program's expect with lambda-set specialization (`--opt=size --specialize=yes`, and
# `--opt=speed`, whose default it is) and without it (`--opt=size --specialize=no`, `--opt=dev`).
# Each should pass.
#
# Bad.roc builds a record that leaves out a field whose default is a closure (`|| "!"`), inside a
# local function that captures `s` and is generalized (its argument `_` is unused). Foreign.roc is
# the same with the record type and its default in another module (Labels.roc). Number.roc is the
# same with a default that adds a number. Plain.roc is Bad.roc with the local function not
# generalized (`||`).
#
# On the fork's builds at 4674b5973d and c69cdc3fdf and on nightly-2026-11-18-a520eed, the
# specialized runs of Bad.roc, Foreign.roc and Number.roc fail: a debug compiler stops in
# `post-check monotype` at "postcheck invariant violated: root nested function site was lowered
# from a non-root evidence scope"; a release compiler doesn't check that and goes on, so what it
# does is chance (Bad.roc and Foreign.roc segfault; Number.roc, whose default is `|n| n + 1`,
# builds, and the program crashes at run time with "invalid numeric literal"). Plain.roc and the
# unspecialized runs pass. A release compiler's outcome could differ from run to run, so each mode
# runs RUNS times (1 unless set).
#
#     ROC=…/roc ./repro.sh
#     ROC=…/roc RUNS=3 ./repro.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
roc=${ROC:-$(ls -d "$here"/../../../.tools/roc/roc_nightly-*/roc 2>/dev/null | head -1)}
[ -x "$roc" ] || { echo "set ROC to a roc binary"; exit 2; }
runs=${RUNS:-1}
cd "$here"
"$roc" version
for file in Bad.roc Foreign.roc Number.roc Plain.roc; do
	for opts in "--opt=size --specialize=yes" "--opt=speed" "--opt=size --specialize=no" "--opt=dev"; do
		for _ in $(seq "$runs"); do
			# shellcheck disable=SC2086 # $opts is one or two flags
			out=$("$roc" test $opts --no-cache "$file" 2>&1)
			code=$?
			said=$(printf '%s\n' "$out" | grep -oE 'All \([0-9]+\) tests? passed|[0-9]+ failed|invariant violated: .*|Segmentation fault \(SIGSEGV\)|overflowed its stack|panic: .*' | head -1)
			stage=$(printf '%s\n' "$out" | grep -oE '^ +post-check +[a-z_]+' | sed -E 's/ +/ /g' | head -1)
			crash=$(printf '%s\n' "$out" | awk '/crashed with this message:/ { f = 1; next } f && NF { sub(/^[ \t]+/, ""); print; exit }')
			printf '%-12s %-28s exit %-3s %s%s%s\n' "$file" "$opts" "$code" "$said" "${stage:+ (in$stage)}" "${crash:+ (the program crashed: $crash)}"
		done
	done
done
