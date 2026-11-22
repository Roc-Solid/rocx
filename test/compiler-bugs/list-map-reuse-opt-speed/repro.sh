#!/usr/bin/env bash
# Builds Bad.roc with --opt=dev and --opt=speed, starts each, and asks it for its cells. Both should
# answer "beta; gamma; delta; path: pressed /". See README.md for what the program is, and what the
# pinned compiler does with it.
#
# Needs the server platform's host (server/platform/targets/<arch>/libhost.a: `just test` or
# `node server/build.mjs` builds it), curl, and free ports from 18980.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
roc=${ROC:-$(ls -d "$here"/../../../.tools/roc/roc_nightly-*/roc 2>/dev/null | head -1)}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cd "$here"
port=18980
for opt in dev speed; do
	binary="$out/Bad-$opt"
	if ! "$roc" build --opt="$opt" --output="$binary" Bad.roc > "$out/build.log" 2>&1; then
		echo "Bad --opt=$opt: build failed"
		tail -20 "$out/build.log"
		continue
	fi
	port=$((port + 1))
	"$binary" --port "$port" --host 127.0.0.1 > "$out/run.log" 2>&1 &
	server=$!
	for _ in $(seq 30); do curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && break; kill -0 "$server" 2>/dev/null || break; sleep 0.1; done
	answer=$(curl -s -m 5 "http://127.0.0.1:$port/" || true)
	sleep 0.2
	if kill -0 "$server" 2>/dev/null; then
		printf 'Bad --opt=%-5s -> %s\n' "$opt" "$answer"
		kill "$server" 2>/dev/null
		wait "$server" 2>/dev/null
	else
		wait "$server" 2>/dev/null
		printf 'Bad --opt=%-5s -> crashed (exit %s)%s\n' "$opt" "$?" "${answer:+ after answering: $answer}"
	fi
done
