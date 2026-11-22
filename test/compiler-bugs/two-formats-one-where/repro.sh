#!/usr/bin/env bash
# Runs both: Crash.roc crashes the compiler (exit 139: a where clause asking for two formats),
# Workaround.roc's expects pass (each format asked for by a function of its own).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
roc=${ROC:-$(ls -d "$here"/../../../.tools/roc/roc_nightly-*/roc 2>/dev/null | head -1)}
cd "$here"
echo "== roc test Crash.roc"
"$roc" test Crash.roc 2>&1 | head -5
echo "exit ${PIPESTATUS[0]}"
echo "== roc test Workaround.roc"
"$roc" test Workaround.roc 2>&1 | tail -4
echo "exit ${PIPESTATUS[0]}"
