#!/usr/bin/env bash
# A top-level constant holds a function value made by a function with a where
# clause, whose closure captures a value of a nominal type over the function's
# type variable that only a function field mentions (`Holder(a) :: { name : Str,
# read : Str -> a }`). An unfixed compiler crashes in boxy_lowering restoring
# that stored function (SIGSEGV; a debug compiler's "a worker without a type
# table read an input-dependent recipe"); --specialize=yes passes. A fixed
# one passes everywhere.
#
# ROC picks the compiler. The cached run gets a fresh cache of its own.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
roc=${ROC:-$(ls -d "$here"/../../../.tools/roc/roc_nightly-*/roc 2>/dev/null | head -1)}
cd "$here"
run() {
	echo "== roc test $*"
	"$roc" test "$@" 2>&1 | grep -E 'Segmentation fault|invariant violated|passed|failed' | head -2 | sed 's/^ *//'
	echo "exit ${PIPESTATUS[0]}"
}
run --no-cache Capture.roc
run --no-cache --specialize=no --opt=interpreter Capture.roc
run --no-cache --specialize=yes Capture.roc
cache=$(mktemp -d)
echo "(fresh cache: test units)"
export ROC_CACHE_DIR=$cache
run --specialize=no --opt=dev Capture.roc
unset ROC_CACHE_DIR
rm -rf "$cache"
