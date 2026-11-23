#!/usr/bin/env bash
# Writes Bad.roc (gen.py: a page rendered as rocx's Root renders one, PAGES components of ITEMS list
# items each, picked by the path through a keyed part), builds it with --opt=dev and --opt=speed, and
# says the largest stack frame each binary's functions take (the stack probe a function's prologue
# runs: `sub x9, sp, #N, lsl #12`, N pages of 4 KiB). See README.md for what the docs site does
# with the same shape, at its size. arm64 macOS (otool); python3.
#
#     ROC=…/roc ./repro.sh            # 60 pages of 40 items: a minute or two with --opt=speed
#     ROC=…/roc ./repro.sh 60 120     # bigger: several minutes
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
roc=${ROC:-$(ls -d "$here"/../../../.tools/roc/roc_nightly-*/roc 2>/dev/null | head -1)}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cd "$here"
python3 gen.py "${1:-60}" "${2:-40}"
for opt in dev speed; do
	if ! "$roc" build --opt="$opt" --output="$out/Bad-$opt" Bad.roc > "$out/build.log" 2>&1; then
		echo "Bad --opt=$opt: build failed"
		tail -20 "$out/build.log"
		continue
	fi
	pages=$(otool -tv "$out/Bad-$opt" | grep -E 'sub[[:space:]]+x9, sp, #0x[0-9a-f]+, lsl #12' | sed -E 's/.*#(0x[0-9a-f]+), lsl #12/\1/' | while read -r hex; do echo $((hex)); done | sort -n | tail -1)
	printf 'Bad --opt=%-5s -> largest frame: %s KiB\n' "$opt" "$(( ${pages:-0} * 4 ))"
done
rm -f Bad.roc
