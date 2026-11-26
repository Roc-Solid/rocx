#!/usr/bin/env bash
# NOTICES for a release of rocx, on stdout: the licenses of what its binaries are built from, past
# the repository's own LICENSE. The Rust crates in the server's host and the CLI's (each crate
# linked in for the targets a release has, with its license files; a text met before is named, not
# repeated), Rust's standard library (its core and alloc in host.wasm too), musl and LLVM's
# libunwind (the Linux targets' C runtime), Zig (which compiles the hosts' C for Linux), and the Roc
# compiler (bin/roc: its LICENSE and legal_details, from the nightly the fork is of).
#
# Needs cargo (the crates are fetched for those targets, so the network once), jq, and the
# toolchain `just setup` puts in .tools. What it can't find it says on stderr, and exits 1 after
# writing the rest, unless --draft.
#
# Usage: release/notices.sh [--draft] > NOTICES
set -euo pipefail
cd "$(dirname "$0")/.."
draft=0
[ "${1:-}" = --draft ] && draft=1
missing=0
miss() {
	echo "release/notices.sh: $*" >&2
	missing=1
}

triples=(aarch64-apple-darwin aarch64-unknown-linux-musl x86_64-unknown-linux-musl)
hash_of() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -c1-64; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/seen"
# Fields of cargo metadata's rows, apart even when empty (a crate may have no license field).
sep=$'\x1f'

rule() { printf '\n%s\n%s\n\n' "$1" "================================================================================"; }

# A file's text, or the name of the crate whose same text came first.
text() {
	local label=$1 file=$2 hash first
	hash=$(hash_of "$file")
	first=$(awk -v h="$hash" '$1 == h { $1 = ""; sub(/^ /, ""); print; exit }' "$tmp/seen")
	if [ -n "$first" ]; then
		echo "-- $label: the same text as $first's, above."
	else
		echo "$hash $label" >> "$tmp/seen"
		echo "-- $label:"
		echo
		cat "$file"
		echo
	fi
}

cat <<'EOF'
Third-party notices for Roc Solid's rocx.

rocx itself is under the LICENSE beside this file. Its binaries are built from the software
below, under the licenses that follow.
EOF

# The crates: those linked into each host for a release's targets (normal dependencies only),
# by name and version, with where cargo keeps their sources.
for host in server/host cli/host; do
	targets=()
	for triple in "${triples[@]}"; do targets+=(--target "$triple"); done
	cargo fetch --locked --manifest-path "$host/Cargo.toml" "${targets[@]}" >&2
	cargo tree --locked --offline --manifest-path "$host/Cargo.toml" -e normal,no-proc-macro "${targets[@]}" --prefix none --format '{p}' |
		sed -e 's/ (\*)$//' -e 's/ (proc-macro)$//' | awk 'NF >= 2 { print $1, $2 }' >> "$tmp/crates"
	filters=()
	for triple in "${triples[@]}"; do filters+=(--filter-platform "$triple"); done
	cargo metadata --locked --offline --format-version 1 --manifest-path "$host/Cargo.toml" "${filters[@]}" |
		jq -r '.packages[] | [.name, "v" + .version, (.license // ""), (.manifest_path | sub("/Cargo.toml$"; "")), (.source // "path")] | join("\u001f")' >> "$tmp/metadata"
done
sort -u "$tmp/crates" > "$tmp/crates.sorted"
sort -u "$tmp/metadata" > "$tmp/metadata.sorted"

rule "Rust crates"
echo "Linked into the server platform's host (server/platform/targets/*/libhost.a) and into bin/rocx."
echo
while read -r name version; do
	row=$(awk -F"$sep" -v n="$name" -v v="$version" '$1 == n && $2 == v { print; exit }' "$tmp/metadata.sorted")
	[ -n "$row" ] || { miss "no metadata for the crate $name $version"; continue; }
	IFS=$sep read -r _ _ license dir source <<< "$row"
	# rocx's own hosts are under its LICENSE.
	if [ "$source" = path ] && [ "$name" != iana-time-zone ]; then continue; fi
	echo "$name $version: ${license:-see its files}"
done < "$tmp/crates.sorted"

rule "Rust crates' license files"
while read -r name version; do
	row=$(awk -F"$sep" -v n="$name" -v v="$version" '$1 == n && $2 == v { print; exit }' "$tmp/metadata.sorted")
	[ -n "$row" ] || continue
	IFS=$sep read -r _ _ license dir source <<< "$row"
	if [ "$source" = path ] && [ "$name" != iana-time-zone ]; then continue; fi
	shopt -s nocaseglob nullglob
	files=("$dir"/{licen[cs]e,copying,notice,copyright,unlicense}*)
	shopt -u nocaseglob nullglob
	if [ ${#files[@]} -eq 0 ]; then
		# A crate with no file of its own (iana-time-zone's patch here, some small crates): its
		# license's text is among the others' (MIT, Apache-2.0).
		echo "-- $name $version: no license file in the crate; its license is $license."
		continue
	fi
	for file in "${files[@]}"; do
		[ -f "$file" ] && text "$name $version, ${file##*/}" "$file"
	done
done < "$tmp/crates.sorted"

rule "Rust's standard library"
echo "Linked into the hosts (host.wasm: its core, alloc and compiler_builtins) and bin/rocx: MIT OR"
echo "Apache-2.0, with parts under the licenses below"
echo "(LLVM's libunwind: Apache-2.0 WITH LLVM-exception; Unicode's data: Unicode-3.0)."
echo
licenses="$(rustc --print sysroot)/share/doc/rust/licenses"
for name in MIT Apache-2.0 LLVM-exception Unicode-3.0; do
	if [ -f "$licenses/$name.txt" ]; then text "Rust, $name" "$licenses/$name.txt"; else miss "no $licenses/$name.txt"; fi
done

rule "musl"
echo "The Linux targets' C library (server/platform/targets/{arm64musl,x64musl}/libc.a, rcrt1.o) and"
echo "the Linux bin/rocx and bin/roc are built with musl:"
echo
lib_dir=$( (zig env 2>/dev/null || "${ZIG:-.tools/zig/zig}" env) | sed -n -e 's/.*"lib_dir": *"\([^"]*\)".*/\1/p' -e 's/.*\.lib_dir = "\([^"]*\)".*/\1/p' | head -1)
if [ -n "$lib_dir" ] && [ -f "$lib_dir/libc/musl/COPYRIGHT" ]; then text "musl, COPYRIGHT" "$lib_dir/libc/musl/COPYRIGHT"; else miss "no musl COPYRIGHT (Zig's lib/libc/musl)"; fi

rule "Zig"
echo "Zig compiles the hosts' C for Linux, and its wasm-ld makes host.wasm from Rust's library for it:"
echo
zig_license=""
for candidate in "$lib_dir/../../LICENSE" "$lib_dir/../LICENSE" .tools/zig/LICENSE; do
	if [ -f "$candidate" ]; then zig_license=$candidate; break; fi
done
if [ -n "$zig_license" ]; then text "Zig, LICENSE" "$zig_license"; else miss "no Zig LICENSE (Zig's folder, or .tools/zig)"; fi

rule "Roc"
echo "bin/roc is the Roc compiler, built from a fork of Roc's nightly with fixes rocx needs. Roc's"
echo "LICENSE, and its legal details (what the compiler is built from):"
echo
nightly=$(ls -d .tools/roc/roc_nightly-* 2>/dev/null | head -1 || true)
for file in LICENSE legal_details; do
	if [ -n "$nightly" ] && [ -f "$nightly/$file" ]; then text "Roc, $file" "$nightly/$file"; else miss "no Roc $file (.tools/roc/roc_nightly-*/, from just setup)"; fi
done

if [ "$missing" = 1 ] && [ "$draft" = 0 ]; then exit 1; fi
exit 0
