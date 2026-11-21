#!/bin/sh
# Builds the spike: the host, then the app with the dev backend and optimized (from the repo root).
set -e
roc=$(ls -d .tools/roc/roc_nightly-*/roc)
mkdir -p spike/suspense/platform/targets/wasm32
.tools/zig/zig build-obj spike/suspense/host/host.zig -target wasm32-freestanding -O ReleaseSmall -fcompiler-rt -femit-bin=spike/suspense/platform/targets/wasm32/host.wasm
"$roc" build --target=wasm32 --opt=dev --output=spike/suspense/app-dev.wasm spike/suspense/app/main.roc
"$roc" build --target=wasm32 --opt=size --output=spike/suspense/app-size.wasm spike/suspense/app/main.roc
