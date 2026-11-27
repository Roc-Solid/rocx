#!/usr/bin/env bash
# Type-checks the repros. Each should pass. Before the fix, Caller.roc fails (Nested.v and
# Nested.v! want a `Dec -> _ret`: the numeral a local closure passes to `v`'s parameter was
# defaulted at the closure's boundary) and Shared.roc fails (its U8 and U16 callers both meet
# `Dec`), while Nested.roc and Direct.roc pass.
# ROC=<path to roc> ./repro.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
roc=${ROC:-$(ls -d "$here"/../../../.tools/roc/roc_nightly-*/roc 2>/dev/null | head -1)}
cd "$here"
for app in Nested Caller Shared Direct; do
	echo "== roc check $app.roc"
	"$roc" check --no-cache "$app.roc" 2>&1 | grep -E "^── |No errors|^    [A-Z(]" | head -12
	echo "exit ${PIPESTATUS[0]}"
done
