#!/usr/bin/env bash
# A release of rocx (`just release-pack`), as spike/install/DESIGN.md §3 has it. For each archive
# asked for, the folder rocx-<version>/ in the repo's own layout, packed as rocx-<os>_<arch>.tar.xz;
# then SHA256SUMS, and install.sh with the version and the archives' SHA-256s in it. All of it in
# release/out/dist/, the release's assets. The folders stay in release/out/stage/<archive>/ to
# look at. A candidate nix/release.json (the archives' URLs on GitHub and their hashes) goes to
# release/out/nix/release.json; the release workflow commits it.
#
# From what is built here: release/out/hosts/<target>/ (`just release-hosts`), the fork's
# compilers (release/out/compilers/<os>/bin/roc from `just release-compilers`, else the ones in
# .tools, checked to be the pinned commit's), and the files git tracks. Nothing is left out
# quietly: an archive asked for whose host or compiler is missing fails the pack.
#
# Usage: ROC_FORK_COMMIT=<commit> release/pack.sh [version] [--targets <archive>,...] [--draft]
#   version: a date, 2026.11.25 (today's by default; 2026.11.25.2 for a second that day).
#   --targets: of macos_arm64, linux_arm64, linux_x86_64; by default each whose bin/rocx and
#     compiler are here.
#   --draft: for a local test: any version (0.0.0-test), a tree with changes, hosts built at
#     another commit, no LICENSE at the root, and no templates/app/.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ROC_FORK_COMMIT:?ROC_FORK_COMMIT is roc_fork_commit in the Justfile (just release-pack passes it)}"

version="" targets="" draft=0
while [ $# -gt 0 ]; do
	case "$1" in
		--targets) targets=${2:?--targets needs a list}; shift 2 ;;
		--targets=*) targets=${1#--targets=}; shift ;;
		--draft) draft=1; shift ;;
		-*) echo "release/pack.sh: no option $1" >&2; exit 2 ;;
		*) [ -z "$version" ] || { echo "release/pack.sh: one version" >&2; exit 2; }; version=${1#v}; shift ;;
	esac
done
version=${version:-$(date +%Y.%m.%d)}

fail() {
	echo "release/pack.sh: $*" >&2
	exit 1
}
# What a draft allows, a release doesn't.
strict() {
	if [ "$draft" = 1 ]; then echo "release/pack.sh: (draft) $*" >&2; else fail "$*"; fi
}

date_version='^[0-9]{4}[.][0-9]{2}[.][0-9]{2}([.][0-9]+)?$'
any_version='^[0-9A-Za-z][0-9A-Za-z.+-]*$'
if ! [[ "$version" =~ $date_version ]]; then
	[[ "$version" =~ $any_version ]] || fail "no version $version"
	strict "the version $version isn't a date (2026.11.25, or 2026.11.25.2)"
fi
pin=${ROC_FORK_COMMIT:0:10}
commit=$(git rev-parse --short=10 HEAD)
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	strict "the tree has changes git hasn't committed"
	commit="$commit-dirty"
fi
out=release/out
hosts=$out/hosts
dist=$out/dist

case "$(uname -sm)" in
	"Darwin arm64") here=macos_apple_silicon ;;
	"Linux aarch64" | "Linux arm64") here=linux_arm64 ;;
	"Linux x86_64") here=linux_x86_64 ;;
	*) here="" ;;
esac

# Each archive: the target bin/rocx is built for, the fork's compiler's name for it, and the server
# platform's targets it carries (a Mac's carries the Linux ones too: it builds what it deploys).
rocx_target() { case "$1" in macos_arm64) echo arm64mac ;; linux_arm64) echo arm64musl ;; linux_x86_64) echo x64musl ;; esac; }
roc_os() { case "$1" in macos_arm64) echo macos_apple_silicon ;; *) echo "$1" ;; esac; }
server_targets() { case "$1" in macos_arm64) echo "arm64mac arm64musl x64musl" ;; *) echo "arm64musl x64musl" ;; esac; }
nix_system() { case "$1" in macos_arm64) echo aarch64-darwin ;; linux_arm64) echo aarch64-linux ;; linux_x86_64) echo x86_64-linux ;; esac; }

# The pinned fork's compiler for an archive: downloaded (just release-compilers), else this
# machine's (.tools/roc-active), else one cross-built here (just roc-fork-linux). It must say it is
# the pinned commit's (its version string, rocx-fork-<pin>).
compiler() {
	local os candidate
	os=$(roc_os "$1")
	for candidate in "$out/compilers/$os/bin/roc" \
		"$([ "$os" = "$here" ] && [ -e .tools/roc-active ] && echo .tools/roc-active)" \
		".tools/roc-fork/$ROC_FORK_COMMIT-$os/bin/roc"; do
		if [ -n "$candidate" ] && [ -x "$candidate" ]; then
			LC_ALL=C grep -q -a -F "rocx-fork-$pin" "$candidate" || fail "$candidate isn't the pinned fork's compiler (no rocx-fork-$pin in it)"
			echo "$candidate"
			return
		fi
	done
}

if [ -z "$targets" ]; then
	for archive in macos_arm64 linux_arm64 linux_x86_64; do
		if [ -x "$hosts/$(rocx_target "$archive")/rocx" ] && [ -n "$(compiler "$archive")" ]; then
			targets="$targets${targets:+,}$archive"
		else
			echo "release/pack.sh: no $archive archive: its bin/rocx (just release-hosts $(rocx_target "$archive")) or its compiler (just release-compilers) isn't here" >&2
		fi
	done
	[ -n "$targets" ] || fail "nothing to pack: just release-hosts, then just release-compilers"
fi

# Everything an archive needs, checked before anything is written.
need() { [ -e "$1" ] || fail "missing $1 ($2)"; }
checked=" "
built_at() {
	local stamp
	case "$checked" in *" $1 "*) return ;; esac
	checked="$checked$1 "
	stamp=$(cat "$1/COMMIT" 2>/dev/null || echo "nothing")
	[ "$stamp" = "$commit" ] || strict "$1 was built at $stamp, this is $commit (just release-hosts again)"
}
IFS=, read -r -a archives <<< "$targets"
for archive in "${archives[@]}"; do
	case "$archive" in macos_arm64 | linux_arm64 | linux_x86_64) ;; *) fail "no archive $archive: macos_arm64, linux_arm64 or linux_x86_64" ;; esac
	need "$hosts/$(rocx_target "$archive")/rocx" "just release-hosts $(rocx_target "$archive")"
	[ -n "$(compiler "$archive")" ] || fail "no fork compiler for $archive ($(roc_os "$archive")): just release-compilers, or just roc-fork-linux"
	for target in $(server_targets "$archive"); do
		need "$hosts/$target/server/libhost.a" "just release-hosts $target"
		if [ "$target" != arm64mac ]; then
			for file in rcrt1.o libunwind.a libc.a; do need "$hosts/$target/server/$file" "just release-hosts $target"; done
		fi
		built_at "$hosts/$target"
	done
	built_at "$hosts/$(rocx_target "$archive")"
done
need "$hosts/wasm32/host.wasm" "just release-hosts wasm32"
built_at "$hosts/wasm32"
if [ -f LICENSE ]; then license=LICENSE; else strict "no LICENSE at the repo's root: the release needs its text"; license=""; fi
if [ -z "$(git ls-files templates/app)" ]; then
	strict "no templates/app/ in git: the archives have no template for rocx new"
fi

sha256() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -c1-64; }

# The files from git, for every archive alike.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
{
	echo web/start.js
	echo web/runtime.js
	git ls-files web/platform | grep '\.roc$'
	git ls-files server/platform | grep '\.roc$'
	git ls-files packages | grep -v -E '^packages/[^/]+/(example|test)/' | grep -v '\.mjs$'
	git ls-files templates/app
} > "$tmp/files"

echo "release/pack.sh: NOTICES" >&2
if [ "$draft" = 1 ]; then notices=(release/notices.sh --draft); else notices=(release/notices.sh); fi
"${notices[@]}" > "$tmp/NOTICES" || fail "NOTICES couldn't be written whole (above)"

rm -rf "$out/stage" "$dist"
mkdir -p "$dist"
for archive in "${archives[@]}"; do
	echo "release/pack.sh: rocx-$archive.tar.xz" >&2
	top="rocx-$version"
	stage="$out/stage/$archive/$top"
	mkdir -p "$stage/bin"
	echo "$version $commit rocx-fork-$pin" > "$stage/VERSION"
	if [ -n "$license" ]; then
		cp "$license" "$stage/LICENSE"
	else
		echo "(draft) No LICENSE yet: the repository has none." > "$stage/LICENSE"
	fi
	cp "$tmp/NOTICES" "$stage/NOTICES"
	cp "$hosts/$(rocx_target "$archive")/rocx" "$stage/bin/rocx"
	cp "$(compiler "$archive")" "$stage/bin/roc"
	while IFS= read -r file; do
		mkdir -p "$stage/$(dirname "$file")"
		cp "$file" "$stage/$file"
	done < "$tmp/files"
	mkdir -p "$stage/web/platform/targets/wasm32"
	cp "$hosts/wasm32/host.wasm" "$stage/web/platform/targets/wasm32/host.wasm"
	for target in $(server_targets "$archive"); do
		mkdir -p "$stage/server/platform/targets/$target"
		cp "$hosts/$target/server/"* "$stage/server/platform/targets/$target/"
	done
	# What rocx looks for: no host sources (it would run cargo) and no rocx-cli/ (it would take the
	# install for a clone); packages/dbcheck for check --sql.
	for absent in server/host rocx-cli cli; do [ ! -e "$stage/$absent" ] || fail "$absent/ is in the archive"; done
	[ -f "$stage/packages/dbcheck/main.roc" ] || fail "no packages/dbcheck/main.roc in the archive"
	chmod -R u+rwX,go+rX,go-w "$stage"
	chmod 755 "$stage/bin/rocx" "$stage/bin/roc"
	# No owner, no macOS metadata (extended attributes, ._ files): a Linux tar would warn of them.
	if tar --version 2>/dev/null | grep -q 'GNU tar'; then
		flags=(--owner=0 --group=0 --numeric-owner --sort=name)
	else
		flags=(--uid 0 --gid 0 --uname root --gname root --no-xattrs --no-mac-metadata)
	fi
	(cd "$out/stage/$archive" && COPYFILE_DISABLE=1 tar "${flags[@]}" -cf - "$top") | xz -T0 -9 > "$dist/rocx-$archive.tar.xz"
done

# The sums, install.sh with the version and the sums in it, then install.sh's own sum.
(cd "$dist" && for file in rocx-*.tar.xz; do echo "$(sha256 "$file")  $file"; done) > "$dist/SHA256SUMS"
sum_of() { [ -f "$dist/rocx-$1.tar.xz" ] && sha256 "$dist/rocx-$1.tar.xz" || true; }
sed -e "s/@VERSION@/$version/" \
	-e "s/@SHA256_MACOS_ARM64@/$(sum_of macos_arm64)/" \
	-e "s/@SHA256_LINUX_ARM64@/$(sum_of linux_arm64)/" \
	-e "s/@SHA256_LINUX_X86_64@/$(sum_of linux_x86_64)/" \
	release/install.sh.in > "$dist/install.sh"
chmod 755 "$dist/install.sh"
grep -q '@[A-Z0-9_]*@' "$dist/install.sh" && fail "install.sh has a placeholder left"
echo "$(sha256 "$dist/install.sh")  install.sh" >> "$dist/SHA256SUMS"

# The candidate nix/release.json: each archive's URL on GitHub and its hash (SRI).
mkdir -p "$out/nix"
{
	echo "{"
	echo "  \"version\": \"$version\","
	echo "  \"systems\": {"
	first=1
	for archive in "${archives[@]}"; do
		[ "$first" = 1 ] || echo ","
		first=0
		sri="sha256-$(openssl dgst -sha256 -binary "$dist/rocx-$archive.tar.xz" | base64 | tr -d '\n')"
		printf '    "%s": {\n      "url": "https://github.com/Roc-Solid/rocx/releases/download/v%s/rocx-%s.tar.xz",\n      "hash": "%s"\n    }' \
			"$(nix_system "$archive")" "$version" "$archive" "$sri"
	done
	printf '\n  }\n}\n'
} > "$out/nix/release.json"

echo
echo "rocx $version ($commit, rocx-fork-$pin), in $dist:"
megabytes() { awk '{ printf "%.1f MB", $1 / 1000000 }'; }
for archive in "${archives[@]}"; do
	packed=$(wc -c < "$dist/rocx-$archive.tar.xz" | megabytes)
	unpacked=$(find "$out/stage/$archive" -type f -exec cat {} + | wc -c | megabytes)
	echo "  rocx-$archive.tar.xz: $packed ($unpacked unpacked)"
done
echo "  SHA256SUMS, install.sh"
echo "  and $out/nix/release.json, for nix/release.json"
