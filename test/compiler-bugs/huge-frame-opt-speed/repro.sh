#!/usr/bin/env bash
# Writes Bad.roc (gen.py: a page rendered as rocx's Root renders one, PAGES components of ITEMS list
# items each, picked by the path through a keyed part), builds it with --opt=speed (OPTS= for others),
# and says the largest stack frame of its Roc procedures (frames.py reads each function's prologue: its
# register saves, `sub sp, sp, #N`, and a stack probe's `sub x9, sp, #P, lsl #12`) and of the whole
# binary (the host's Rust is in it too). See README.md for what the docs site does with the same
# shape, at its size. arm64 macOS (otool); python3.
#
#     ROC=…/roc ./repro.sh                      # 4 pages of 120 items, FANOUT=4 WIDE=96: the shape
#                                               # that shows c69cdc3fdf's regression (the default)
#     ROC=…/roc ./repro.sh 4 480                # four times the items (minutes on 4674b5973d)
#     FANOUT= WIDE=32 ROC=…/roc ./repro.sh 60 40  # 4674b5973d's dispatcher: one list per page
#     PLATFORM=…/server/platform/main.roc   # the server platform to build on (default: the repo's)
#     SHAPES=mixed                    # six kinds of hole body instead of one (gen.py)
#     WIDE=96                         # every Html value about 96 x 24 bytes, as the docs site's (gen.py;
#                                     # the default; WIDE= for none)
#     FANOUT=4                        # the items in a tree of lists of 4, not one list (gen.py; the
#                                     # default; FANOUT= for one list)
#     OPTS="dev speed"                # which --opt builds (default: speed; the dev backend's procedures
#                                     # have no _roc__p names, so only the whole binary's number shows)
#     KEEP=1                          # keep Bad.roc and the binaries (in ./out)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
roc=${ROC:-$(ls -d "$here"/../../../.tools/roc/roc_nightly-*/roc 2>/dev/null | head -1)}
if [ -n "${KEEP:-}" ]; then out="$here/out"; mkdir -p "$out"; else out=$(mktemp -d); trap 'rm -rf "$out"' EXIT; fi
cd "$here"
export WIDE=${WIDE-96} FANOUT=${FANOUT-4}
pages=${1:-4} items=${2:-120}
python3 gen.py "$pages" "$items"
for opt in ${OPTS:-speed}; do
	start=$(date +%s)
	if ! "$roc" build --opt="$opt" --output="$out/Bad-$opt" Bad.roc > "$out/build.log" 2>&1; then
		echo "Bad --opt=$opt: build failed"
		tail -20 "$out/build.log"
		continue
	fi
	took=$(( $(date +%s) - start ))
	roc_frame=$(python3 frames.py "$out/Bad-$opt" 1 _roc__p | awk '{print $1}')
	any_frame=$(python3 frames.py "$out/Bad-$opt" 1 | awk '{print $1}')
	printf 'Bad %sx%s --opt=%-5s -> largest Roc frame: %7s B, largest frame: %7s B (built in %ss)\n' "$pages" "$items" "$opt" "${roc_frame:-0}" "${any_frame:-0}" "$took"
done
[ -n "${KEEP:-}" ] || rm -f Bad.roc
