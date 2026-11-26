#!/usr/bin/env bash
# spike/wasm-engine: the keyed js-framework-benchmark page twice, for spike/wasm-engine/time.mjs to
# compare: on today's browser platform (web/host and runtime.js), and on native/core's engine as
# the browser's host (web.rs, engine.js), rendered afresh.
#
#   spike/wasm-engine/build.sh [out]     (default /tmp/wasm-engine: out/today, out/engine)
#
# NAMES=1 links the engine's wasm with --debug: its functions named, for profile.mjs. OPT sets the
# engine's optimization (below).
# The engine's page is linked with the web platform's exports swapped for the engine's for the
# length of its build (web/platform/main.roc and its host.wasm are put back after, as they were).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=${1:-/tmp/wasm-engine}
base=/frameworks/keyed/roc-solid/
today="$out/today$base"
engine="$out/engine$base"
rm -rf "$out"
bin/rocx build benchmarks/jsframework/keyed --static "$today" --base "$base" >/dev/null
client=benchmarks/jsframework/keyed/build/static/client/main.roc

# OPT: the engine's optimization for the browser (default s: for size, as web/host's; the phone's
# release is 3).
(cd native && CARGO_PROFILE_RELEASE_OPT_LEVEL=${OPT:-s} cargo rustc -q -p rocx-native-core --target wasm32-unknown-unknown --release --crate-type staticlib)
platform=web/platform/main.roc
host=web/platform/targets/wasm32/host.wasm
saved=$(mktemp -d)
cp -p "$platform" "$saved/main.roc"
cp -p "$host" "$saved/host.wasm"
trap 'cp -p "$saved/main.roc" "$platform"; cp -p "$saved/host.wasm" "$host"; rm -rf "$saved"' EXIT
zig wasm-ld -r --whole-archive native/target/wasm32-unknown-unknown/release/librocx_native_core.a -o "$host"
sed -i '' -e 's/exports: \["mount", [^]]*\]/exports: ["rocx_start", "rocx_event", "rocx_scratch", "rocx_call"]/' "$platform"
grep -q '"rocx_start"' "$platform"

mkdir -p "$engine/rocx"
cp "$today/index.html" "$engine/index.html"
.tools/roc-active build --target=wasm32 --opt=size --specialize=yes ${NAMES:+--debug} --output="$engine/rocx/app.wasm" "$client" >/dev/null
cp spike/wasm-engine/engine.js "$engine/rocx/engine.js"
cat > "$engine/rocx/start.js" <<'EOF'
// spike/wasm-engine: the page started by the Rust engine (engine.js), rendered afresh.
import { start } from "./engine.js";
const started = performance.now();
const ex = await start(fetch(new URL("app.wasm", import.meta.url)), "/");
window.engine = ex;
document.dispatchEvent(new CustomEvent("rocx:ready", { detail: { ms: performance.now() - started } }));
EOF

size() {
	echo "$1: wasm $(wc -c < "$2/rocx/app.wasm" | tr -d ' ') bytes ($(brotli -c -q 11 "$2/rocx/app.wasm" | wc -c | tr -d ' ') br)"
}
size today "$today"
size engine "$engine"
