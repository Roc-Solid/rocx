#!/bin/sh
# Builds the echo app optimized (--opt=speed), starts it, and measures both its endpoints with
# bombardier at a few concurrency levels: POST /echo with the JSON string "hello" (simple), then
# POST /echo/json with order.json, sent compact (json). Usage, from the repo's root:
# examples/echo/bench.sh [seconds] [port]
set -eu
seconds=${1:-10}
port=${2:-18080}
root=$(cd "$(dirname "$0")/../.." && pwd)
out=${TMPDIR:-/tmp}/rocx-echo
mkdir -p "$out"
cd "$root"
rocx=$(node --input-type=module -e "import { rocxBinary } from './server/build.mjs'; console.log(rocxBinary())")
"$rocx" build examples/echo
node server/build.mjs examples/echo/main.roc "$out/echo" --opt=speed
"$out/echo" --port "$port" --host 127.0.0.1 > "$out/server.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null' EXIT INT TERM
until curl -s -o /dev/null "http://127.0.0.1:$port/"; do sleep 0.1; done
order=$(node -e 'process.stdout.write(JSON.stringify(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))))' examples/echo/order.json)
measure() { # name, path, body
	url="http://127.0.0.1:$port$2"
	bombardier -m POST -H 'content-type: application/json' -b "$3" -c 64 -d 3s -p r "$url" > /dev/null # warm up
	for connections in 1 16 64 256; do
		echo "=== echo ($1), $connections connections, ${seconds}s"
		bombardier -m POST -H 'content-type: application/json' -b "$3" -c "$connections" -d "${seconds}s" -l -p r "$url" |
			grep -E 'Reqs/sec|Latency  |50%|99%|2xx|others'
	done
}
measure simple /echo '"hello"'
measure json /echo/json "$order"
