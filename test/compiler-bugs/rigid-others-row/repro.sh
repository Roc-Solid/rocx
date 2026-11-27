#!/usr/bin/env bash
# Type-checks each module. Callback.roc, Transaction.roc and TailCall.roc should pass: a `?` on a
# callback whose error row ends in the annotation's rigid `..others` (or the callback's call as
# the body's value) beside the function's own NotFound. Bare.roc and Closed.roc are controls that
# pass everywhere; Unlisted.roc must fail (its result lacks `..others`). On the fork at
# c69cdc3fdf the first three fail with "type mismatch".
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
roc=${ROC:-$(ls -d "$here"/../../../.tools/roc/roc_nightly-*/roc 2>/dev/null | head -1)}
cd "$here"
for app in Callback Transaction TailCall Bare Closed Unlisted; do
	echo "== roc check $app.roc"
	"$roc" check --no-cache "$app.roc" 2>&1 | grep -E "^── |No errors" | head -3
	echo "exit ${PIPESTATUS[0]}"
done
