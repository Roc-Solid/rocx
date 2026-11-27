#!/usr/bin/env bash
# A where clause asking a type for two formats' `read` (or `parser_for`):
# two requirements of one method that no type can meet, which checking
# reports as a type error. An unfixed compiler then crashes in boxy_lowering
# (SIGSEGV; a debug compiler's "an erroneous checked type reached Boxy
# lowering") instead of reporting it and running the expects beside it.
#
#   Formats.roc + uses.roc: the definition, a use of it at a type with the
#     first format's `read`, and a function handing its argument on.
#     Crashes `roc check`, `roc test --no-cache` and `roc test`.
#   Crash.roc: the case as found (a format of the module's own and Json's,
#     no use that checks). Crashes `roc test` with a cache only: test
#     units lower every function a module defines.
#
# ROC picks the compiler. Each cached run gets a fresh cache of its own.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
roc=${ROC:-$(ls -d "$here"/../../../.tools/roc/roc_nightly-*/roc 2>/dev/null | head -1)}
cd "$here"
show() { grep -E 'Segmentation fault|invariant violated|no type can have more than one|errors and|passed$|tests passed|compiler errors$|Compilation failed' | sed 's/^ *//'; }
echo "== roc check uses.roc"
"$roc" check --no-cache uses.roc 2>&1 | show
echo "exit ${PIPESTATUS[0]}"
for file in uses.roc Crash.roc; do
	echo "== roc test --no-cache $file"
	"$roc" test --no-cache "$file" 2>&1 | show
	echo "exit ${PIPESTATUS[0]}"
	cache=$(mktemp -d)
	echo "== roc test $file (fresh cache)"
	ROC_CACHE_DIR=$cache "$roc" test "$file" 2>&1 | show
	echo "exit ${PIPESTATUS[0]}"
	rm -rf "$cache"
done
echo "== roc test Workaround.roc (each format asked for by a function of its own)"
"$roc" test --no-cache Workaround.roc 2>&1 | show
echo "exit ${PIPESTATUS[0]}"
