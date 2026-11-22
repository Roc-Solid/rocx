#!/usr/bin/env bash
# Builds each app with --opt=dev and --opt=speed, starts it, and asks GET and POST /doc. Every one
# should answer "get" and "post". See README.md for what each app is, and what the pinned compiler
# does with it.
#
# Needs the server platform's host (server/platform/targets/<arch>/libhost.a: `just test` or
# `node server/build.mjs` builds it), curl, and free ports from 18950.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
roc=${ROC:-$(ls -d "$here"/../../../.tools/roc/roc_nightly-*/roc 2>/dev/null | head -1)}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cd "$here"
port=18950
apps=${APPS:-"AppShape Bad NoCapture"}
for app in $apps; do
	for opt in dev speed; do
		binary="$out/$app-$opt"
		if ! "$roc" build --opt="$opt" --output="$binary" "$app.roc" > "$out/build.log" 2>&1; then
			echo "$app --opt=$opt: build failed"
			tail -20 "$out/build.log"
			continue
		fi
		port=$((port + 1))
		"$binary" --port "$port" --host 127.0.0.1 > "$out/run.log" 2>&1 &
		server=$!
		for _ in $(seq 30); do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; kill -0 "$server" 2>/dev/null || break; sleep 0.1; done
		if kill -0 "$server" 2>/dev/null; then
			printf '%-9s --opt=%-5s GET /doc -> %s, POST /doc -> %s\n' "$app" "$opt" "$(curl -s -m 5 "http://127.0.0.1:$port/doc")" "$(curl -s -m 5 -X POST "http://127.0.0.1:$port/doc")"
			kill "$server" 2>/dev/null
			wait "$server" 2>/dev/null
		else
			wait "$server" 2>/dev/null
			printf '%-9s --opt=%-5s exited (%s) before it listened\n' "$app" "$opt" "$?"
		fi
	done
done
