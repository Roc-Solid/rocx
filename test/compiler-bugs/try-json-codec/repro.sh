#!/usr/bin/env bash
# Runs both: Fails.roc doesn't compile on the nightly (the builtin Try has no encoder_for or
# parser_for) and passes on the fork since 4674b5973d; Workaround.roc's expects pass on both (the same
# union as a nominal type of the app's own).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
roc=${ROC:-$(ls -d "$here"/../../../.tools/roc/roc_nightly-*/roc 2>/dev/null | head -1)}
cd "$here"
echo "== roc test Fails.roc"
"$roc" test Fails.roc 2>&1 | grep -E 'does not have a method|passed|failed' | head -4
echo "exit ${PIPESTATUS[0]}"
echo "== roc test Workaround.roc"
"$roc" test Workaround.roc 2>&1 | tail -4
echo "exit ${PIPESTATUS[0]}"
