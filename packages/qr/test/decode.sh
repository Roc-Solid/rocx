#!/usr/bin/env bash
# Reads back every code codes.roc makes (versions 1 to 40, four levels, each full) with zbar, and says
# which don't read back as their text. zbar from Nix: `nix shell nixpkgs#zbar`.
#
#   packages/qr/test/decode.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
roc="${ROC:-$(readlink -f "$repo/.tools/roc-active")}"
"$roc" build --opt=speed --output="$work/codes" "$here/codes.roc" >/dev/null
"$work/codes" > "$work/all.txt"
python3 -I "$here/split.py" "$work/all.txt" "$work"
nix shell nixpkgs#zbar -c bash -c '
    failed=0; read=0
    for png in "$1"/*.png; do
        want="$(cat "${png%.png}.txt")"
        got="$(zbarimg --raw -q "$png" 2>/dev/null || true)"
        if [ "$got" = "$want" ]; then read=$((read + 1)); else failed=$((failed + 1)); echo "not read back: $(basename "$png" .png)"; fi
    done
    echo "decode.sh: $read read back, $failed not"
    [ "$failed" -eq 0 ]
' _ "$work"
