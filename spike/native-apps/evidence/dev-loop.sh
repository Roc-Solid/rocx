#!/usr/bin/env bash
# The dev mode's evidence (D-063: `rocx dev --android`), on a running emulator, with rocx dev running
# beside it and its output in a file:
#
#   bin/rocx dev spike/native-apps/phone-hello --port 8095 --android > /tmp/rocx-dev-android.log 2>&1 &
#   spike/native-apps/evidence/dev-loop.sh /tmp/rocx-dev-android.log
#
# With adb alone it taps the counter twice and types into the field; then edits the page's .rocx
# (its heading) and waits for the phone to show the new build, timed on the Mac from the file's
# write to the dev client's "shown" line in rocx dev's output (logcat's, so a little late); then
# saves a mistake and waits for the red screen; then the fix. The page is put back as it was.
# Screenshots: dev-01-before.png, dev-02-reloaded.png (the new heading, and a fresh start: the
# counter back at 0, the field empty), dev-03-error.png, dev-04-fixed.png; timings in dev-loop.txt.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
log="${1:?usage: dev-loop.sh <the file rocx dev writes its output to>}"
adb="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
page="$repo/spike/native-apps/phone-hello/routes/+page.rocx"
original="$(mktemp)"
cp "$page" "$original"
trap 'cp "$original" "$page"; rm -f "$original"' EXIT

now() { python3 -I -c 'import time; print(int(time.time() * 1000))'; }

centre() {
    "$adb" exec-out uiautomator dump /dev/tty | python3 -I -c '
import re, sys
want = sys.argv[1]
for node in re.finditer(r"<node [^>]*>", sys.stdin.read()):
    node = node.group(0)
    text = re.search(r" text=\"([^\"]*)\"", node).group(1)
    kind = re.search(r" class=\"([^\"]*)\"", node).group(1)
    if text == want or kind == want:
        a, b, c, d = map(int, re.search(r"bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", node).groups())
        print((a + c) // 2, (b + d) // 2)
        break
' "$1"
}

tap() { "$adb" shell input tap $(centre "$1"); }
shot() { "$adb" exec-out screencap -p > "$here/$1.png"; echo "dev-loop.sh: $1.png" >&2; }

# Waits until rocx dev's output has more than `$1` lines matching `$2`; prints when (ms).
until_logged() {
    for _ in $(seq 1 1500); do
        if [ "$(grep -c "$2" "$log" || true)" -gt "$1" ]; then now; return 0; fi
        sleep 0.02
    done
    echo "dev-loop.sh: rocx dev's output never said $2" >&2
    exit 1
}

shown='dev: build .* shown'
failed='dev: The build failed'
{
    echo "rocx dev --android, $(date '+%Y-%m-%d %H:%M'), load average $(sysctl -n vm.loadavg | tr -d '{}')"
    echo
} > "$here/dev-loop.txt"

# The page as rocx dev last built it, with two taps and something typed.
tap Tap
sleep 0.5
tap Tap
tap android.widget.EditText
for _ in $(seq 1 30); do "$adb" shell dumpsys input_method | grep -q "mInputShown=true" && break; sleep 0.5; done
sleep 1
"$adb" shell input text "typed%sbefore%sthe%sedit"
"$adb" shell input keyevent KEYCODE_ESCAPE
sleep 1
shot dev-01-before

# 1. An edit: the heading.
for round in 1 2 3; do
    before=$(grep -c "$shown" "$log" || true)
    saved=$(now)
    sed -i '' "s|<h1>[^<]*</h1>|<h1>Edited on the Mac, round $round</h1>|" "$page"
    at=$(until_logged "$before" "$shown")
    built=$(grep "rocx dev: built" "$log" | tail -1)
    line=$(grep "$shown" "$log" | tail -1 | sed 's/^.*rocx *: //')
    echo "edit $round: on the phone $((at - saved)) ms after the save ($built; $line)" >> "$here/dev-loop.txt"
    sleep 1.5
done
shot dev-02-reloaded

# 2. A mistake: the red screen.
before=$(grep -c "$failed" "$log" || true)
saved=$(now)
sed -i '' 's|{count!().to_str()}|{count!().to_strr()}|' "$page"
at=$(until_logged "$before" "$failed")
echo "a mistake: on the phone's red screen $((at - saved)) ms after the save" >> "$here/dev-loop.txt"
sleep 1
shot dev-03-error

# 3. The fix.
before=$(grep -c "$shown" "$log" || true)
saved=$(now)
sed -i '' 's|{count!().to_strr()}|{count!().to_str()}|' "$page"
at=$(until_logged "$before" "$shown")
echo "the fix: on the phone $((at - saved)) ms after the save" >> "$here/dev-loop.txt"
sleep 1.5
shot dev-04-fixed
"$adb" exec-out uiautomator dump /dev/tty | grep -o 'text="[^"]\+"' >> "$here/dev-loop.txt"
cat "$here/dev-loop.txt"
