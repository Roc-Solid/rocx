#!/usr/bin/env bash
# Builds each app with --opt=dev and --opt=speed and asks each for /doc. Every one should answer
# "doc". On nightly-2026-11-18-a520eed, Bad.roc and Middleware.roc answer "fell through" when built
# with --opt=speed: a chain of three effectful closures composed by `then` skips its last step.
# TwoSteps.roc (the same, two steps) answers "doc" both ways.
#
# Needs the server platform's host (server/platform/targets/<arch>/libhost.a: `just test` or
# `node server/build.mjs` builds it), curl, and a free port from 18900.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
roc=${ROC:-$(ls -d "$here"/../../../.tools/roc/roc_nightly-*/roc 2>/dev/null | head -1)}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cd "$here"
port=18900
for app in Bad Middleware TwoSteps; do
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
		for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.1; done
		printf '%-10s --opt=%-5s GET /doc -> %s\n' "$app" "$opt" "$(curl -s -m 5 "http://127.0.0.1:$port/doc")"
		kill "$server" 2>/dev/null
		wait "$server" 2>/dev/null
	done
done
