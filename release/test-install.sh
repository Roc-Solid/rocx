#!/bin/sh
# Tests a release's install.sh against its own archives, without GitHub (`just release-test`, and
# the release workflow's smoke jobs, on macOS and in bare Alpine with curl, xz and tar alone). The
# release folder (release/out/dist by default) is laid out as GitHub has releases, at
# <base>/download/v<version>/<asset>, and served over HTTP with python3 when there is one (a free
# port, never 8080), else given to install.sh as a folder (ROCX_RELEASES may be either). Everything goes into a temporary HOME and ROCX_HOME, so no real start-up
# file or ~/.rocx is touched.
#
# What it checks: the install (current, bin/rocx, a read-only version, the PATH line once); rocx
# --version says the archive's version; with PATH only ~/.rocx/bin, /usr/bin and /bin, rocx reads
# the template's routes, and the installed roc says the pinned fork, checks a package, and builds
# a server against the installed platform (an app outside the install, reaching it through a .rocx
# link), which answers; on a Mac it also builds that server for the Linux targets the archive
# carries. A newcomer's first app: rocx new, rocx check, check --sql and test, a release build
# that starts under --dev and is signed in to through /auth/dev, /account showing who. Then:
# installing again
# changes nothing, --no-modify-path writes no start-up file, --no-current leaves current, a corrupt
# download installs nothing, and a version that isn't there fails.
#
# Usage: release/test-install.sh [release folder]
#   ROCX_TEST_VERSION_FLAG=optional: a rocx without --version yet passes (it says so).
set -eu

dist=${1:-$(dirname "$0")/out/dist}
dist=$(cd "$dist" && pwd)
[ -f "$dist/install.sh" ] || { echo "No install.sh in $dist: just release-pack first" >&2; exit 1; }
version=$(sed -n 's/^version=//p' "$dist/install.sh")

tmp=$(mktemp -d)
server_pid=""
app_pid=""
cleanup() {
	[ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
	[ -z "$app_pid" ] || kill "$app_pid" 2>/dev/null || true
	chmod -R u+w "$tmp" 2>/dev/null || true
	rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

failures=0
pass() { echo "ok: $*"; }
fail() {
	echo "FAILED: $*" >&2
	failures=$((failures + 1))
}

# The releases, as GitHub lays them out.
mkdir -p "$tmp/releases/download/v$version" "$tmp/corrupt/download/v$version"
for file in "$dist"/*; do ln -s "$file" "$tmp/releases/download/v$version/$(basename "$file")"; done
if command -v python3 >/dev/null 2>&1; then
	port=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
	[ "$port" != 8080 ] || port=$((port + 1))
	python3 -I -m http.server --bind 127.0.0.1 --directory "$tmp/releases" "$port" > "$tmp/http.log" 2>&1 &
	server_pid=$!
	base="http://127.0.0.1:$port"
	tries=0
	until curl -fsS -o /dev/null "$base/download/v$version/install.sh" 2>/dev/null; do
		tries=$((tries + 1))
		[ "$tries" -lt 50 ] || { echo "The test's HTTP server didn't start:" >&2; cat "$tmp/http.log" >&2; exit 1; }
		sleep 0.1
	done
else
	base="$tmp/releases"
fi
echo "rocx $version from $base"

case "$(uname -s)-$(uname -m)" in
	Darwin-*) archive=macos_arm64 target=arm64mac ;;
	Linux-aarch64 | Linux-arm64) archive=linux_arm64 target=arm64musl ;;
	*) archive=linux_x86_64 target=x64musl ;;
esac

# An install as a user runs it: install.sh from the release, piped into sh, bash the login shell.
home=$tmp/home
rocx_home=$tmp/rocx-home
mkdir -p "$home"
run_install() {
	h=$1 r=$2 releases=$3
	shift 3
	case "$base" in
		http://*) curl -fsSL "$base/download/v$version/install.sh" ;;
		*) cat "$base/download/v$version/install.sh" ;;
	esac | HOME=$h ROCX_HOME=$r ROCX_RELEASES=$releases SHELL=/bin/bash sh -s -- "$@"
}

if run_install "$home" "$rocx_home" "$base" > "$tmp/install.log" 2>&1; then
	pass "install.sh installed rocx $version"
else
	cat "$tmp/install.log" >&2
	fail "install.sh exited $?"
fi
sed 's/^/  | /' "$tmp/install.log"

installed=$rocx_home/versions/$version
[ "$(readlink "$rocx_home/current")" = "versions/$version" ] && pass "current points at versions/$version" || fail "current: $(readlink "$rocx_home/current" || echo none)"
[ -x "$rocx_home/bin/rocx" ] && pass "bin/rocx runs from \$ROCX_HOME/bin" || fail "no \$ROCX_HOME/bin/rocx"
expected=$(cat "$installed/VERSION" 2>/dev/null || echo "")
case "$expected" in
	"$version "[0-9a-f]*" rocx-fork-"*) pass "VERSION: $expected" ;;
	*) fail "VERSION: '$expected', not '<version> <commit> rocx-fork-<pin>'" ;;
esac
pin=${expected##* }
# Read-only: no file or folder the owner may write (root writes anyway, so the modes are checked).
writable=$(find "$installed" -perm -200 | head -3)
[ -z "$writable" ] && pass "the install is read-only" || fail "writable in the install: $writable"
[ ! -e "$rocx_home/versions/$version.partial" ] && pass "no .partial left" || fail "versions/$version.partial left behind"
path_lines() { grep -c -F "$rocx_home/bin" "$home/.bashrc" 2>/dev/null || true; }
lines=$(path_lines)
[ "$lines" = 1 ] && pass ".bashrc has the PATH line" || fail ".bashrc has ${lines:-no} PATH lines"

# Nothing but the install on PATH.
bare_path="$rocx_home/bin:/usr/bin:/bin"
said=$(env HOME="$home" PATH="$bare_path" rocx --version 2>&1) && status=0 || status=$?
if [ "$status" = 0 ] && case "$said" in *"$version"*) true ;; *) false ;; esac; then
	pass "rocx --version: $said"
elif [ "${ROCX_TEST_VERSION_FLAG:-}" = optional ] && [ "$status" != 0 ] && [ "$status" -lt 126 ]; then
	echo "skipped: rocx --version (this rocx has no --version yet: exit $status)"
else
	fail "rocx --version: exit $status, '$said', without $version (VERSION: $expected)"
fi
if [ -d "$installed/templates/app" ]; then
	if env HOME="$home" PATH="$bare_path" rocx routes "$installed/templates/app" > "$tmp/routes.log" 2>&1 && grep -q "/sign-in" "$tmp/routes.log"; then
		pass "rocx routes reads templates/app in the install"
	else
		sed 's/^/  | /' "$tmp/routes.log" >&2
		fail "rocx routes templates/app"
	fi
else
	fail "no templates/app in the install"
fi
roc=$installed/bin/roc
said=$(env HOME="$home" PATH="$bare_path" "$roc" version 2>&1) || true
case "$said" in
	*"$pin"*) pass "bin/roc version: $said" ;;
	*) fail "bin/roc version: '$said', not $pin" ;;
esac
if env HOME="$home" PATH="$bare_path" "$roc" check "$installed/packages/crypto/main.roc" > "$tmp/check.log" 2>&1; then
	pass "bin/roc checks packages/crypto in the install"
else
	sed 's/^/  | /' "$tmp/check.log" >&2
	fail "bin/roc check packages/crypto"
fi

# A server, outside the install, on its platform through a .rocx link, as an app has it.
app=$tmp/app
mkdir -p "$app"
ln -s "$installed" "$app/.rocx"
cat > "$app/main.roc" <<'EOF'
app [program] { pf: platform "./.rocx/server/platform/main.roc" }

import pf.Server

program = {
	init!: |started| Ok(started),
	respond!: |request, _context| Server.response(200, [{ name: "content-type", value: "text/plain; charset=utf-8" }], "installed: ${request.path}"),
	database: Postgres,
	migrations: [],
	actors: [],
	logs: { format: Pretty },
	plugins: [],
	routes: [],
}
EOF
build() {
	(cd "$app" && env HOME="$home" PATH="$bare_path" "$roc" build "$@" main.roc) > "$tmp/build.log" 2>&1 || [ $? -eq 2 ]
}
# This machine's target named: on an x86_64 CPU without x86-64-v3 (an emulator's), Roc's own pick
# is x64v1musl, which the platform has no host for.
if build --target=$target --output=server; then
	pass "bin/roc builds a server against the installed platform ($target)"
	(cd "$app" && exec ./server --port 0) 2> "$tmp/app.log" &
	app_pid=$!
	url=""
	tries=0
	while [ -z "$url" ] && [ "$tries" -lt 100 ]; do
		url=$(sed -n 's/.*rocx server: \(http:[^ ]*\).*/\1/p' "$tmp/app.log" | head -1)
		[ -n "$url" ] || { tries=$((tries + 1)); sleep 0.1; }
	done
	answer=$(curl -fsS "$url/hello" 2>&1) || true
	[ "$answer" = "installed: /hello" ] && pass "the server answers: $answer" || { sed 's/^/  | /' "$tmp/app.log" >&2; fail "the server answered '$answer' at '$url'"; }
	kill "$app_pid" 2>/dev/null || true
	app_pid=""
else
	sed 's/^/  | /' "$tmp/build.log" >&2
	fail "bin/roc build of a server against the installed platform"
fi
if [ "$archive" = macos_arm64 ]; then
	for linux in arm64musl x64musl; do
		if build --target=$linux --output=server-$linux; then
			pass "bin/roc builds the server for $linux"
		else
			sed 's/^/  | /' "$tmp/build.log" >&2
			fail "bin/roc build --target=$linux"
		fi
	done
fi

# A newcomer's first app, with nothing but the install on PATH: rocx new, its checks and its
# expects, a release build, that server started under --dev and signed in to.
apps=$tmp/apps
mkdir -p "$apps"
newcomer() { (cd "$1" && shift && env HOME="$home" PATH="$bare_path" rocx "$@" < /dev/null) > "$tmp/newcomer.log" 2>&1; }
if newcomer "$apps" new shop --db sqlite && [ -f "$apps/shop/.rocx-version" ] && [ -L "$apps/shop/.rocx" ] && grep -q "$version" "$apps/shop/.rocx-version"; then
	pass "rocx new shop: .rocx-version $(cat "$apps/shop/.rocx-version"), .rocx linked"
	shop=$apps/shop
	for step in "check ." "check --sql ." "test ."; do
		# shellcheck disable=SC2086
		if newcomer "$shop" $step; then pass "rocx $step in the new app"; else sed 's/^/  | /' "$tmp/newcomer.log" >&2; fail "rocx $step in the new app"; fi
	done
	if newcomer "$shop" build . --release dist --target "$target" && [ -x "$shop/dist/server" ]; then
		pass "rocx build . --release dist ($target)"
		(cd "$shop" && exec ./dist/server --port 0 --static dist/static --dev) 2> "$tmp/shop.log" &
		app_pid=$!
		url=""
		tries=0
		while [ -z "$url" ] && [ "$tries" -lt 300 ]; do
			url=$(sed -n 's/.*rocx server: \(http:[^ ]*\).*/\1/p' "$tmp/shop.log" | head -1)
			[ -n "$url" ] || { tries=$((tries + 1)); sleep 0.1; }
		done
		home_status=$(curl -s -o /dev/null -w '%{http_code}' "$url/") || true
		[ "$home_status" = 200 ] && pass "the new app's / answers 200" || fail "the new app's / answered $home_status"
		away=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -H 'accept: text/html' "$url/account") || true
		case "$away" in "303 "*"/sign-in?then=%2Faccount") pass "signed out, /account goes to sign in" ;; *) fail "signed out, /account answered '$away'" ;; esac
		signed=$(curl -s -c "$tmp/jar" -o /dev/null -w '%{http_code} %{redirect_url}' -H "origin: $url" -d 'email=ada@example.com&then=/account' "$url/auth/dev") || true
		case "$signed" in "303 "*"/account") pass "the dev sign-in goes on to /account" ;; *) fail "the dev sign-in answered '$signed'" ;; esac
		if curl -s -b "$tmp/jar" -H 'accept: text/html' "$url/account" | grep -q "ada@example.com"; then
			pass "/account shows who signed in"
		else
			sed 's/^/  | /' "$tmp/shop.log" >&2
			fail "/account doesn't show ada@example.com"
		fi
		kill "$app_pid" 2>/dev/null || true
		app_pid=""
	else
		sed 's/^/  | /' "$tmp/newcomer.log" >&2
		fail "rocx build . --release dist"
	fi
else
	sed 's/^/  | /' "$tmp/newcomer.log" >&2
	fail "rocx new shop"
fi

# Again: only current is pointed, and no second PATH line.
if run_install "$home" "$rocx_home" "$base" > "$tmp/again.log" 2>&1 && grep -q "installed already" "$tmp/again.log"; then
	pass "installing again: installed already"
else
	sed 's/^/  | /' "$tmp/again.log" >&2
	fail "installing again"
fi
lines=$(path_lines)
[ "$lines" = 1 ] && pass "still one PATH line" || fail ".bashrc has ${lines:-no} PATH lines after a second install"

# --no-modify-path, as rocx runs it for a version an app names: installed, current at it, no
# start-up file.
mkdir -p "$tmp/home2"
if run_install "$tmp/home2" "$tmp/rocx-home2" "$base" --no-modify-path > "$tmp/quiet.log" 2>&1 && [ -z "$(ls -A "$tmp/home2")" ] \
	&& [ "$(readlink "$tmp/rocx-home2/current")" = "versions/$version" ] && [ -x "$tmp/rocx-home2/versions/$version/bin/rocx" ]; then
	pass "--no-modify-path: installed, current at it, no start-up file written"
else
	sed 's/^/  | /' "$tmp/quiet.log" >&2
	fail "--no-modify-path: $(ls -A "$tmp/home2" | tr '\n' ' ')"
fi

# --no-current, as rocx installs a version an app names: beside current, which stays.
mv "$rocx_home/versions/$version" "$rocx_home/versions/0.0.0-current"
ln -sfn versions/0.0.0-current "$rocx_home/current"
if run_install "$home" "$rocx_home" "$base" --no-modify-path --no-current > "$tmp/beside.log" 2>&1 \
	&& [ "$(readlink "$rocx_home/current")" = versions/0.0.0-current ] && [ -f "$rocx_home/versions/$version/VERSION" ]; then
	pass "--no-current: installed beside, current kept"
else
	sed 's/^/  | /' "$tmp/beside.log" >&2
	fail "--no-current: current is $(readlink "$rocx_home/current")"
fi

# A corrupt archive: refused, nothing installed.
head -c 100000 "$dist/rocx-$archive.tar.xz" > "$tmp/corrupt/download/v$version/rocx-$archive.tar.xz"
if HOME="$tmp/home3" ROCX_HOME="$tmp/rocx-home3" ROCX_RELEASES="$tmp/corrupt" sh "$dist/install.sh" --no-modify-path > "$tmp/corrupt.log" 2>&1; then
	fail "a corrupt archive was installed"
elif grep -q "SHA-256" "$tmp/corrupt.log" && [ ! -e "$tmp/rocx-home3/versions/$version" ]; then
	pass "a corrupt archive is refused: $(grep SHA-256 "$tmp/corrupt.log")"
else
	sed 's/^/  | /' "$tmp/corrupt.log" >&2
	fail "a corrupt archive: not refused by its SHA-256"
fi

# Another version, not released: its install.sh isn't there.
if HOME="$tmp/home4" ROCX_HOME="$tmp/rocx-home4" ROCX_RELEASES="$base" sh "$dist/install.sh" --no-modify-path 1999.01.01 > "$tmp/other.log" 2>&1; then
	fail "an unreleased version installed"
else
	pass "an unreleased version: $(tail -1 "$tmp/other.log")"
fi

if [ "$failures" -gt 0 ]; then
	echo "$failures failed" >&2
	exit 1
fi
echo "all passed"
