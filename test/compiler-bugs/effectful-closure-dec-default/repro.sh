#!/usr/bin/env bash
# Type-checks the three callers of ErrorPage.roc, each passing a U16 status. Each should pass. On
# nightly-2026-11-18-a520eed, Bad.roc fails (ErrorPage.view! wants a Dec: a closure checked
# against `() => Str` defaults the number it reads), while Pure.roc (the same body against
# `() -> Str`) and Hoisted.roc (to_str called outside the closure) pass.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
roc=${ROC:-$(ls -d "$here"/../../../.tools/roc/roc_nightly-*/roc 2>/dev/null | head -1)}
cd "$here"
for app in Bad Pure Hoisted; do
	echo "== roc check $app.roc"
	"$roc" check "$app.roc" 2>&1 | grep -E "^── |No errors|^    \{" | head -4
	echo "exit ${PIPESTATUS[0]}"
done
