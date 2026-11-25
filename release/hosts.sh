#!/usr/bin/env bash
# What a release carries that is built per target (`just release-hosts`), put in
# release/out/hosts/<target>/ for release/pack.sh:
#   arm64mac, arm64musl, x64musl: `rocx`, bin/rocx built for the target, and `server/`, the server
#     platform's host (libhost.a, and a musl target's rcrt1.o, libunwind.a, libc.a), debug info
#     stripped;
#   wasm32: `host.wasm`, the browser's host.
# Each target's COMMIT names the commit that built it (with -dirty when tracked files had
# changes), so pack.sh doesn't mix builds of two commits.
#
# The hosts are built as the tests build them (server/build.mjs, with Node). A musl target needs
# rustup's target for it and Zig for its C. Stripping needs llvm-strip: LLVM_STRIP, else rustup's
# (`rustup component add llvm-tools`), else one on PATH.
#
# Usage: ROC=<compiler> [ZIG=<zig>] release/hosts.sh [arm64mac|arm64musl|x64musl|wasm32]...
#   With none, what this machine builds: a Mac all four, Linux all but arm64mac.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ROC:?ROC names the Roc compiler (just release-hosts passes it)}"
if [ $# -eq 0 ]; then
	if [ "$(uname -sm)" = "Darwin arm64" ]; then set -- arm64mac arm64musl x64musl wasm32; else set -- arm64musl x64musl wasm32; fi
fi

commit=$(git rev-parse --short=10 HEAD)
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then commit="$commit-dirty"; fi
out=release/out/hosts

size() { du -h "$1" | cut -f1; }

# llvm-strip, for any target's objects, on any machine: rustup's first, as its LLVM is the one
# the hosts were compiled with.
llvm_strip() {
	if [ -n "${LLVM_STRIP:-}" ]; then echo "$LLVM_STRIP"; return; fi
	local found
	found=$(ls "$(rustc --print sysroot)"/lib/rustlib/*/bin/llvm-strip 2>/dev/null | head -1 || true)
	if [ -n "$found" ]; then echo "$found"; return; fi
	if command -v llvm-strip >/dev/null; then command -v llvm-strip; return; fi
	echo "No llvm-strip: run \`rustup component add llvm-tools\`, set LLVM_STRIP, or put one on PATH." >&2
	exit 1
}

# Copies `from` to `to` without its debug info, and says how much smaller it got. llvm-strip for
# every target: Apple's `strip -S` leaves a host Roc's linker refuses (duplicate symbols). A Mac's
# executable is copied as it is: its debug info stays in the objects it was linked from.
stripped() {
	local target=$1 from=$2 to=$3
	cp "$from" "$to"
	chmod u+w "$to"
	case "$target:$to" in
		arm64mac:*.a | *musl:*) "$(llvm_strip)" --strip-debug "$to" ;;
	esac
	echo "  $(basename "$to"): $(size "$from") -> $(size "$to")"
}

for target in "$@"; do
	dir="$out/$target"
	rm -rf "$dir"
	mkdir -p "$dir"
	echo "== $target"
	case "$target" in
		wasm32)
			just web-host
			cp web/platform/targets/wasm32/host.wasm "$dir/host.wasm"
			echo "  host.wasm: $(size "$dir/host.wasm")"
			;;
		arm64mac | arm64musl | x64musl)
			if [ "$target" = arm64mac ] && [ "$(uname -sm)" != "Darwin arm64" ]; then
				echo "arm64mac is built on a Mac with Apple silicon" >&2
				exit 1
			fi
			# The server's host and the CLI platform's (which rocx is built on), with a musl target's C
			# runtime beside each.
			ROC="$ROC" node --input-type=module -e "
				const build = await import('./server/build.mjs');
				build.buildHost({ target: '$target' });
				build.buildCliHost({ target: '$target' });
			"
			# rocx, as just rocx-bootstrap builds it (2: warnings alone).
			"$ROC" build --opt=speed --target="$target" --output="$dir/rocx.unstripped" rocx-cli/main.roc || [ $? -eq 2 ]
			mkdir -p "$dir/server"
			stripped "$target" "$dir/rocx.unstripped" "$dir/rocx"
			rm "$dir/rocx.unstripped"
			files=libhost.a
			if [ "$target" != arm64mac ]; then files="libhost.a rcrt1.o libunwind.a libc.a"; fi
			for file in $files; do
				stripped "$target" "server/platform/targets/$target/$file" "$dir/server/$file"
			done
			;;
		*)
			echo "No target $target: arm64mac, arm64musl, x64musl or wasm32" >&2
			exit 2
			;;
	esac
	echo "$commit" > "$dir/COMMIT"
done
