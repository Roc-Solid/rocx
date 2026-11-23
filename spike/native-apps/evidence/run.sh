#!/usr/bin/env bash
# The Android spike's evidence (D-063), on a running emulator, against the app's server on the Mac
# (`bin/rocx dev examples/phone-hello --port 8095`; the emulator reaches it at 10.0.2.2:8095):
#
#   spike/native-apps/evidence/run.sh [path/to/phone-hello.apk]
#
# It installs the APK, launches it pointed at a proxy in front of that server which waits 2.5 s
# before passing each request on (slow-proxy.py: so the <Loading> fallback is on screen while the
# GET is on its way; the emulator's own `network delay` doesn't slow 10.0.2.2), and with adb alone
# taps, types and takes screenshots:
# 01 before any tap, 02 once the GET's answer is in, 03 after three taps on the counter, 04 after
# the POST's round trip, 05 after a POST the server refuses. Then the view hierarchy
# (uiautomator.xml: android.widget.* views, no WebView), the APK's native libraries and classes,
# and the launch timings (timings.txt).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
adb="$sdk/platform-tools/adb"
apk="${1:-$repo/native/android/build/phone-hello/phone-hello.apk}"
package="dev.rocx.example.phonehello"
activity="$package/dev.rocx.phone.RocxActivity"
build_tools="$sdk/build-tools/$(ls "$sdk/build-tools" | sort -V | tail -1)"

# The centre of the first view whose text (or class) is `$1`, from a fresh uiautomator dump.
centre() {
    "$adb" exec-out uiautomator dump /dev/tty | python3 -I -c '
import re, sys
want = sys.argv[1]
xml = sys.stdin.read()
for node in re.finditer(r"<node [^>]*>", xml):
    node = node.group(0)
    text = re.search(r" text=\"([^\"]*)\"", node).group(1)
    kind = re.search(r" class=\"([^\"]*)\"", node).group(1)
    if text == want or kind == want:
        a, b, c, d = map(int, re.search(r"bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", node).groups())
        print((a + c) // 2, (b + d) // 2)
        break
' "$1"
}

tap() {
    local at
    at="$(centre "$1")"
    [ -n "$at" ] || { echo "run.sh: nothing on screen says $1" >&2; exit 1; }
    echo "run.sh: tap $1 at $at" >&2
    "$adb" shell input tap $at
}

# Waits (up to a minute) until something on screen says `$1`.
until_shown() {
    for _ in $(seq 1 60); do
        if [ -n "$(centre "$1")" ]; then return 0; fi
        sleep 1
    done
    echo "run.sh: nothing said $1 within a minute" >&2
    exit 1
}

shot() {
    "$adb" exec-out screencap -p > "$here/$1.png"
    echo "run.sh: $1.png" >&2
}

"$adb" install -r "$apk" >&2
"$adb" shell am force-stop "$package"
"$adb" shell input keyevent KEYCODE_HOME
sleep 3
"$adb" logcat -c

# A cold start, timed by the activity manager (launch to first frame), on a normal network.
"$adb" shell am start -W -n "$activity" > "$here/timings.txt"
sleep 3
"$adb" logcat -d -s 'rocx:*' >> "$here/timings.txt"
"$adb" shell am force-stop "$package"

# The run: through the slow proxy, so the GET is seen on its way.
python3 -I "$here/slow-proxy.py" 8096 8095 2.5 &
proxy=$!
trap 'kill $proxy 2>/dev/null' EXIT
"$adb" logcat -c
"$adb" shell am start -n "$activity" --es origin http://10.0.2.2:8096 >/dev/null
until_shown "Asking the server…"
shot 01-before-taps
until_shown "Hello from the rocx server"
shot 02-get-answered
for _ in 1 2 3; do
    tap Tap
    sleep 0.7
done
sleep 1
shot 03-after-taps
tap android.widget.EditText
# Typed only once the keyboard is up: keys injected while it starts can come twice.
for _ in $(seq 1 30); do
    "$adb" shell dumpsys input_method | grep -q "mInputShown=true" && break
    sleep 0.5
done
sleep 1
"$adb" shell input text "hello%sphone"
until_shown "hello phone"
sleep 0.5
tap Send
until_shown "HELLO PHONE (11 characters)"
"$adb" shell input keyevent KEYCODE_ESCAPE
sleep 1
shot 04-post-answered
# A POST the server refuses (422: nothing typed): its refusal, as the typed answer's Err.
tap android.widget.EditText
sleep 1
"$adb" shell input keyevent KEYCODE_MOVE_END
for _ in $(seq 1 11); do "$adb" shell input keyevent KEYCODE_DEL; done
until_shown "Say something"
sleep 0.5
tap Send
until_shown "Not sent: Type something first"
"$adb" shell input keyevent KEYCODE_ESCAPE
sleep 1
shot 05-post-refused

# The views: Android's own widgets, no WebView.
"$adb" exec-out uiautomator dump /dev/tty | sed 's/UI hierchary dumped to: \/dev\/tty//' > "$here/uiautomator.xml"
python3 -I -c '
import re, sys, collections
xml = open(sys.argv[1]).read()
kinds = collections.Counter(re.findall(r" class=\"([^\"]*)\"", xml))
print("view classes in the hierarchy:")
for kind, count in sorted(kinds.items()):
    print(f"  {count:3} {kind}")
print("WebView in the hierarchy:", "yes" if "WebView" in xml else "no")
' "$here/uiautomator.xml" > "$here/views.txt"
"$adb" logcat -d -s 'rocx:*' > "$here/logcat.txt"

# What the APK holds: its native libraries, and its classes (no JS engine, no WebView).
{
    echo "APK: $(basename "$apk"), $(stat -f %z "$apk") bytes"
    echo
    echo "files:"
    (cd "$(dirname "$apk")" && unzip -l "$(basename "$apk")") | sed 's/^/  /'
    echo
    echo "native libraries' dependencies (readelf -d):"
    tmp="$(mktemp -d)"
    unzip -q -o "$apk" 'lib/*' -d "$tmp"
    llvm="$(ls -d "$repo"/.tools/android-ndk/libexec/android-sdk/ndk/*/toolchains/llvm/prebuilt/*/bin | head -1)"
    for lib in "$tmp"/lib/*/*.so; do
        echo "  $(basename "$lib"): $(stat -f %z "$lib") bytes"
        "$llvm/llvm-readelf" -d "$lib" | grep NEEDED | sed 's/^/    /'
        echo "    exported: $("$llvm/llvm-nm" -D --defined-only "$lib" | awk '{print $3}' | tr '\n' ' ')"
        echo "    JavaScript engines' symbols (v8, Hermes, JSC, QuickJS): $("$llvm/llvm-nm" -D "$lib" | grep -ciE 'v8::|hermes|JSContext|JSGlobal|quickjs' || true)"
    done
    rm -rf "$tmp"
    echo
    echo "classes (dexdump):"
    "$build_tools/dexdump" "$apk" 2>/dev/null | grep "Class descriptor" | sed "s/.*'\(.*\)'/  \1/" | sort
    echo
    echo "WebView or JavaScript in the classes: $("$build_tools/dexdump" -d "$apk" 2>/dev/null | grep -ciE 'android/webkit|javascript' || true)"
} > "$here/apk-contents.txt"
echo "run.sh: done: $here" >&2
