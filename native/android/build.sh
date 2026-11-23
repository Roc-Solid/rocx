#!/usr/bin/env bash
# Builds an app's Android APK (D-063's spike): native views, no JavaScript, no WebView.
#
#   native/android/build.sh spike/native-apps/phone-hello [--origin http://10.0.2.2:8095] [--label "Phone hello"]
#
# 1. The app's browser copy (rocx build --client), whose main.roc is the app on web/platform.
# 2. Its Roc for the phone: web/platform's arm64musl target, the app alone as an archive (Roc has no
#    Android target; its static Linux objects for arm64 are Android's ELF too).
# 3. The native host for Android (native/android with native/core), a Rust static library.
# 4. One library, lib/arm64-v8a/libapp.so: the two linked by the NDK's clang, exporting only JNI.
# 5. The Kotlin shell (native/android/app): kotlinc, then R8 (Kotlin's library shrunk to what is used).
# 6. The APK: aapt2 (the manifest), the dex and the library, zipalign, apksigner (a key of the spike's
#    own, made once in native/android/build/).
# 7. The app mounted once on the Mac (native/mac), which says what a phone ignores (CSS, tags).
#
# Tools: the Android SDK ($ANDROID_HOME, else ~/Library/Android/sdk: build-tools, platforms/android-36),
# the NDK ($ANDROID_NDK, else the repo's .tools/android-ndk from Nix, else the SDK's ndk/), Rust with
# the aarch64-linux-android std (the system's if it has it, else the repo's .tools/rust), Java
# ($JAVA_HOME, else Android Studio's) and kotlinc ($KOTLINC, else Android Studio's).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
app=""
origin="http://10.0.2.2:8080"
label=""
while [ $# -gt 0 ]; do
    case "$1" in
        --origin) origin="$2"; shift 2 ;;
        --label) label="$2"; shift 2 ;;
        -*) echo "build.sh: unknown option $1" >&2; exit 2 ;;
        *) app="$1"; shift ;;
    esac
done
[ -n "$app" ] || { echo "usage: native/android/build.sh <app dir> [--origin http://10.0.2.2:8080] [--label name]" >&2; exit 2; }
app="$(cd "$app" && pwd)"
name="$(basename "$app")"
[ -n "$label" ] || label="$name"
package="dev.rocx.example.$(echo "$name" | tr -cd 'a-zA-Z0-9' | tr 'A-Z' 'a-z')"
out="$here/build/$name"
started=$(date +%s)
step() { echo "build.sh: $*" >&2; }

# ---- Tools ----
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
build_tools="$sdk/build-tools/$(ls "$sdk/build-tools" | sort -V | tail -1)"
android_jar="$sdk/platforms/android-36/android.jar"
ndk="${ANDROID_NDK:-}"
if [ -z "$ndk" ]; then
    for candidate in "$repo"/.tools/android-ndk/libexec/android-sdk/ndk/* "$sdk"/ndk/*; do
        [ -d "$candidate/toolchains" ] && ndk="$candidate"
    done
fi
[ -n "$ndk" ] || { echo "build.sh: no NDK: see spike/native-apps/README.md (Setting up)" >&2; exit 1; }
llvm="$ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin"
[ -d "$llvm" ] || llvm="$(echo "$ndk"/toolchains/llvm/prebuilt/*/bin)"
clang="$llvm/aarch64-linux-android29-clang"
java_home="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
kotlinc="${KOTLINC:-/Applications/Android Studio.app/Contents/plugins/Kotlin/kotlinc/bin/kotlinc}"
kotlin_lib="$(cd "$(dirname "$kotlinc")/../lib" && pwd)"
roc="${ROC:-$(readlink -f "$repo/.tools/roc-active" 2>/dev/null || true)}"
[ -x "$roc" ] || { echo "build.sh: no Roc compiler: run \`just setup\` (or set ROC)" >&2; exit 1; }
# Rust with the Android std: the system's if it has it, else the repo's rustup toolchain.
rust_env=()
if ! [ -d "$(rustc --print sysroot 2>/dev/null)/lib/rustlib/aarch64-linux-android" ]; then
    rust_env=(RUSTUP_HOME="$repo/.tools/rust/rustup" CARGO_HOME="$repo/.tools/rust/cargo" PATH="$repo/.tools/rust/cargo/bin:$PATH")
fi
mkdir -p "$out"

# ---- 1. The app's browser copy ----
step "rocx build --client ($name)"
"$repo/bin/rocx" build --client "$out/client" "$app" >&2

# ---- 2. Its Roc, for the phone ----
step "roc build --target=arm64musl (an archive: the app alone)"
"$roc" build --target=arm64musl --opt=speed --output="$out/libapp-roc.a" "$out/client/main.roc" >&2 || [ $? -eq 2 ]

# ---- 3. The native host for Android ----
step "cargo build (native/android, aarch64-linux-android)"
(
    cd "$repo/native"
    env "${rust_env[@]}" \
        CC_aarch64_linux_android="$clang" \
        AR_aarch64_linux_android="$llvm/llvm-ar" \
        CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$clang" \
        cargo build --release --target aarch64-linux-android -p rocx-android >&2
)
host="$repo/native/target/aarch64-linux-android/release/librocx_android.a"

# ---- 4. libapp.so ----
step "link lib/arm64-v8a/libapp.so (the NDK's clang)"
stage="$out/apk"
rm -rf "$stage"
mkdir -p "$stage/lib/arm64-v8a"
cat > "$out/exports.map" <<'EOF'
{ global: JNI_OnLoad; Java_dev_rocx_phone_*; local: *; };
EOF
"$clang" -shared -o "$stage/lib/arm64-v8a/libapp.so" \
    -Wl,--undefined=JNI_OnLoad -Wl,--undefined=Java_dev_rocx_phone_Rocx_start -Wl,--undefined=Java_dev_rocx_phone_Rocx_send \
    "$host" "$out/libapp-roc.a" \
    -llog -landroid -ldl -lm \
    -Wl,--gc-sections -Wl,--version-script="$out/exports.map" -Wl,-z,max-page-size=16384 -Wl,--no-undefined -Wl,--build-id=none -s

# ---- 5. The Kotlin shell ----
# Built again only when its sources or R8's rules changed (kotlinc's start is most of a rebuild).
if [ ! -f "$out/dex/classes.dex" ] || [ -n "$(find "$here/app/src" "$here/app/rules.pro" -newer "$out/dex/classes.dex" -print -quit)" ]; then
    step "kotlinc + R8 (native/android/app)"
    rm -rf "$out/classes" "$out/dex"
    mkdir -p "$out/classes" "$out/dex"
    JAVA_HOME="$java_home" "$kotlinc" -nowarn -no-reflect -jvm-target 1.8 -classpath "$android_jar" -d "$out/classes/shell.jar" \
        $(find "$here/app/src" -name '*.kt') 2>&1 | grep -v "^warning: unable to find kotlin-stdlib" >&2 || true
    [ -f "$out/classes/shell.jar" ] || { echo "build.sh: kotlinc failed" >&2; exit 1; }
    "$java_home/bin/java" -cp "$build_tools/lib/d8.jar" com.android.tools.r8.R8 --release --min-api 29 \
        --lib "$android_jar" --pg-conf "$here/app/rules.pro" --output "$out/dex" \
        "$out/classes/shell.jar" "$kotlin_lib/kotlin-stdlib.jar" >&2
fi
cp "$out/dex/classes.dex" "$stage/classes.dex"

# ---- 6. The APK ----
step "aapt2 + zipalign + apksigner"
sed -e "s|@PACKAGE@|$package|" -e "s|@LABEL@|$label|" -e "s|@ORIGIN@|$origin|" "$here/app/AndroidManifest.xml" > "$out/AndroidManifest.xml"
"$build_tools/aapt2" link -o "$out/base.apk" -I "$android_jar" --manifest "$out/AndroidManifest.xml" >&2
(cd "$stage" && zip -q -D "$out/base.apk" classes.dex && zip -q -D -0 "$out/base.apk" lib/arm64-v8a/libapp.so)
"$build_tools/zipalign" -f -P 16 4 "$out/base.apk" "$out/aligned.apk"
key="$here/build/spike.keystore"
if [ ! -f "$key" ]; then
    "$java_home/bin/keytool" -genkeypair -keystore "$key" -storepass rocx-spike -keypass rocx-spike -alias spike \
        -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=rocx spike" >/dev/null 2>&1
fi
"$java_home/bin/java" --enable-native-access=ALL-UNNAMED -jar "$build_tools/lib/apksigner.jar" sign --ks "$key" --ks-pass pass:rocx-spike --key-pass pass:rocx-spike --ks-key-alias spike \
    --out "$out/$name.apk" "$out/aligned.apk"
rm -f "$out/base.apk" "$out/aligned.apk" "$out/$name.apk.idsig"

# ---- 7. What a phone ignores ----
step "the app on the native host, on the Mac (what a phone ignores)"
"$roc" build --target=arm64mac --opt=dev --output="$out/libapp-mac.a" "$out/client/main.roc" >/dev/null 2>&1 || [ $? -eq 2 ]
(cd "$repo/native" && ROCX_APP_ARCHIVE="$out/libapp-mac.a" cargo build -q -p rocx-native-mac 2>/dev/null)
"$repo/native/target/debug/rocx-native-mac" --origin http://127.0.0.1:9 2>&1 | grep '\[Warn\]' | sed 's/^\[Warn\] /build.sh: phone: /' >&2 || true

size=$(stat -f %z "$out/$name.apk" 2>/dev/null || stat -c %s "$out/$name.apk")
echo "build.sh: $out/$name.apk ($((size / 1024)) KB, $package, server $origin) in $(( $(date +%s) - started )) s" >&2
echo "$out/$name.apk"
