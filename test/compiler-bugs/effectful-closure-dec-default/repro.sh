#!/usr/bin/env bash
# Type-checks the three callers of ErrorPage.roc, each passing a U16 status, and the one-module
# reductions Shared.roc and SharedPure.roc. Each should pass. Before the fix, Bad.roc fails
# (ErrorPage.view! wants a Dec: a closure checked against `() => Str` keeps its effect formula on
# that type and the number it reads is defaulted) and Shared.roc fails (`show` isn't generic, so
# its U8 and U16 callers disagree), while Pure.roc, Hoisted.roc and SharedPure.roc pass.
# ROC=<path to roc> ./repro.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
roc=${ROC:-$(ls -d "$here"/../../../.tools/roc/roc_nightly-*/roc 2>/dev/null | head -1)}
cd "$here"
for app in Bad Pure Hoisted Shared SharedPure; do
	echo "== roc check $app.roc"
	"$roc" check --no-cache "$app.roc" 2>&1 | grep -E "^── |No errors|^    \{|^    [A-Z(]" | head -4
	echo "exit ${PIPESTATUS[0]}"
done
