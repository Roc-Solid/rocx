#!/usr/bin/env bash
# Builds the docs site's browser wasm the ways the re-baseline needs (2026-11-24). Run from the
# worktree root, after `node site/build.mjs --prepare` and mark.py (site/build/client-marked).
#   spec.wasm          as shipped: --opt=size --specialize=yes
#   boxy.wasm          --opt=size --specialize=no
#   marked.wasm        boxy, each page's level marked (rocx-chunk:<Page>)
#   marked-debug.wasm  the same with --debug (names), --keep-temp; caught/ = the scratch dir's objects
#   marked.a           the same, the platform's wasm32 output an Archive (a copy, --replace-dep)
set -euo pipefail
ROC=$(readlink -f .tools/roc-active)
O=${O:-/tmp/rocx-split-2/out}
export ROC_CACHE_DIR=${ROC_CACHE_DIR:-/tmp/rocx-split-2/roc-cache}
mkdir -p "$O" "$ROC_CACHE_DIR"
C=site/build/client/main.roc
M=site/build/client-marked/main.roc
PF=$PWD/web/platform/main.roc  # resolved from the cwd now (the parked code passed the header's text)
ARCH=/tmp/rocx-split-2/platform-archive/main.roc
b() { local name=$1; shift; local t=$SECONDS; "$ROC" build --target=wasm32 "$@" > "$O/$name.log" 2>&1 || { echo "FAILED $name"; tail -30 "$O/$name.log"; return 1; }; echo "$name: $((SECONDS - t)) s"; }
what=${1:-all}
if [[ $what == all || $what == debug ]]; then
  rm -rf "$ROC_CACHE_DIR/tmp" "$O/caught"; mkdir -p "$O/caught"
  ( while :; do for d in "$ROC_CACHE_DIR"/tmp/*/; do [ -f "$d/roc_app_unsealed_wasm32.o" ] && cp -R "$d" "$O/caught/" 2>/dev/null; done; sleep 0.05; done ) & poller=$!
  b marked-debug --opt=size --specialize=no --debug --keep-temp --output="$O/marked-debug.wasm" "$M" || true
  kill $poller
  echo "kept after --keep-temp:"; find "$ROC_CACHE_DIR/tmp" -name "*.o" 2>/dev/null | head || true; echo "caught:"; ls -la "$O/caught" || true
fi
if [[ $what == all || $what == archive ]]; then b marked-archive --opt=size --specialize=no --debug --replace-dep "$PF" "$ARCH" --output="$O/marked.a" "$M"; fi
if [[ $what == all || $what == plain ]]; then
  b marked --opt=size --specialize=no --output="$O/marked.wasm" "$M"
  b boxy --opt=size --specialize=no --output="$O/boxy.wasm" "$C"
  b spec --opt=size --specialize=yes --output="$O/spec.wasm" "$C"
fi
ls -la "$O"
