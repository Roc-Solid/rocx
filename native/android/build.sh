#!/usr/bin/env bash
# Builds an app's Android APK (D-063's spike): native views, no JavaScript, no WebView.
#
#   native/android/build.sh spike/native-apps/phone-hello [--origin http://10.0.2.2:8095] [--label "Phone hello"] [--opt dev] [--stories]
#   native/android/build.sh --dev-client
#   native/android/build.sh <app dir> --host-only   (the host and shell again, the app's last Roc kept)
#
# The dev client (`--dev-client`, for `rocx dev --android`): no app in it, but the host as
# libhost.so (native/android-dev), which loads each build of an app rocx dev serves; steps 3, 5 and
# 6 alone, into native/android/build/dev-client/rocx-dev.apk (dev.rocx.devclient, "rocx dev").
#
# 1. The app's browser copy (rocx generate --client), whose main.roc is the app on web/platform.
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
opt="speed"
dev_client=""
host_only=""
# --stories: the browser copy as `rocx generate --dev` writes it (the components' stories in it), so
# the phone asks for the stylesheet a server built that way (`rocx build --dev`, an app's own dev
# build) has: the stylesheet's name is a hash of what it holds, and the stories' styles are in it.
generate_dev=""
while [ $# -gt 0 ]; do
    case "$1" in
        --origin) origin="$2"; shift 2 ;;
        --label) label="$2"; shift 2 ;;
        --opt) opt="$2"; shift 2 ;;
        --dev-client) dev_client=1; shift ;;
        --host-only) host_only=1; shift ;;
        --stories) generate_dev="--dev"; shift ;;
        -*) echo "build.sh: unknown option $1" >&2; exit 2 ;;
        *) app="$1"; shift ;;
    esac
done
if [ -n "$dev_client" ]; then
    name="dev-client"
    label="rocx dev"
    package="dev.rocx.devclient"
    origin=""
else
    [ -n "$app" ] || { echo "usage: native/android/build.sh <app dir> [--origin http://10.0.2.2:8080] [--label name] [--opt dev], or --dev-client" >&2; exit 2; }
    app="$(cd "$app" && pwd)"
    name="$(basename "$app")"
    [ -n "$label" ] || label="$name"
    package="dev.rocx.example.$(echo "$name" | tr -cd 'a-zA-Z0-9' | tr 'A-Z' 'a-z')"
fi
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

if [ -n "$host_only" ] && [ -f "$out/libapp-roc.a" ]; then
    step "the app's Roc as last built (--host-only)"
elif [ -z "$dev_client" ]; then
    # ---- 1. The app's browser copy ----
    step "rocx generate --client ($name)"
    "$repo/bin/rocx" generate --client "$out/client" $generate_dev "$app" >&2

    # ---- 2. Its Roc, for the phone ----
    step "roc build --target=arm64musl --opt=$opt (an archive: the app alone)"
    "$roc" build --target=arm64musl --opt="$opt" --output="$out/libapp-roc.a" "$out/client/main.roc" >&2 || [ $? -eq 2 ]
fi

# ---- 3. The native host for Android ----
crate="rocx-android"
[ -z "$dev_client" ] || crate="rocx-android-dev"
step "cargo build ($crate, aarch64-linux-android)"
(
    cd "$repo/native"
    env "${rust_env[@]}" \
        CC_aarch64_linux_android="$clang" \
        AR_aarch64_linux_android="$llvm/llvm-ar" \
        CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$clang" \
        cargo build --release --target aarch64-linux-android -p "$crate" >&2
)
host="$repo/native/target/aarch64-linux-android/release/librocx_android.a"

# ---- 4. libapp.so ----
stage="$out/apk"
rm -rf "$stage"
mkdir -p "$stage/lib/arm64-v8a"
if [ -n "$dev_client" ]; then
    step "lib/arm64-v8a/libhost.so (native/android-dev)"
    cp "$repo/native/target/aarch64-linux-android/release/libhost.so" "$stage/lib/arm64-v8a/libhost.so"
    cp "$stage/lib/arm64-v8a/libhost.so" "$out/libhost.so"
else
step "link lib/arm64-v8a/libapp.so (the NDK's clang)"
cat > "$out/exports.map" <<'EOF'
{ global: JNI_OnLoad; Java_dev_rocx_phone_*; local: *; };
EOF
"$clang" -shared -o "$stage/lib/arm64-v8a/libapp.so" \
    -Wl,--undefined=JNI_OnLoad -Wl,--undefined=Java_dev_rocx_phone_Rocx_start -Wl,--undefined=Java_dev_rocx_phone_Rocx_send -Wl,--undefined=Java_dev_rocx_phone_Rocx_viewport \
    -Wl,--undefined=Java_dev_rocx_phone_Rocx_back -Wl,--undefined=Java_dev_rocx_phone_Rocx_files -Wl,--undefined=Java_dev_rocx_phone_Rocx_ask -Wl,--undefined=Java_dev_rocx_phone_Rocx_fetch \
    "$host" "$out/libapp-roc.a" \
    -llog -landroid -ldl -lm \
    -Wl,--gc-sections -Wl,--version-script="$out/exports.map" -Wl,-z,max-page-size=16384 -Wl,--no-undefined -Wl,--build-id=none -s
fi

# ---- 5. The Kotlin shell ----
# The app's phone halves of its custom elements (D-139): the Kotlin in its android/ folder, built
# with the shell, and their list (each `object <Name> : ElementHalf("<tag>")`), written as
# AppHalves.kt (an empty list for an app with none, and for the dev client).
gen="$out/gen"
mkdir -p "$gen"
app_kt=()
if [ -z "$dev_client" ] && [ -d "$app/android" ]; then
    while IFS= read -r file; do app_kt+=("$file"); done < <(find "$app/android" -name '*.kt' | sort)
fi
halves=""
for file in ${app_kt[@]+"${app_kt[@]}"}; do
    pkg="$(sed -n 's/^package[[:space:]]\{1,\}\([A-Za-z0-9_.]*\).*/\1/p' "$file" | head -1)"
    for half in $(sed -n 's/^[[:space:]]*object[[:space:]]\{1,\}\([A-Za-z0-9_]*\)[[:space:]]*:[[:space:]]*ElementHalf(.*/\1/p' "$file"); do
        halves="$halves${halves:+, }${pkg:+$pkg.}$half"
    done
done
printf 'package dev.rocx.phone\n\n// Written by native/android/build.sh: the app'"'"'s phone halves (D-139), from its android/ folder.\ninternal val appHalves: List<ElementHalf> = listOf(%s)\n' "$halves" > "$gen/AppHalves.kt.new"
if cmp -s "$gen/AppHalves.kt.new" "$gen/AppHalves.kt"; then rm "$gen/AppHalves.kt.new"; else mv "$gen/AppHalves.kt.new" "$gen/AppHalves.kt"; fi
[ -z "$halves" ] || step "the app's phone halves: $halves"
# Built again only when its sources, the app's halves or R8's rules changed (kotlinc's start is most
# of a rebuild).
if [ ! -f "$out/dex/classes.dex" ] || [ -n "$(find "$here/app/src" "$here/app/rules.pro" "$gen/AppHalves.kt" ${app_kt[@]+"${app_kt[@]}"} -newer "$out/dex/classes.dex" -print -quit)" ]; then
    step "kotlinc + R8 (native/android/app)"
    rm -rf "$out/classes" "$out/dex"
    mkdir -p "$out/classes" "$out/dex"
    JAVA_HOME="$java_home" "$kotlinc" -nowarn -no-reflect -jvm-target 1.8 -classpath "$android_jar" -d "$out/classes/shell.jar" \
        $(find "$here/app/src" -name '*.kt') "$gen/AppHalves.kt" ${app_kt[@]+"${app_kt[@]}"} 2>&1 | grep -v "^warning: unable to find kotlin-stdlib" >&2 || true
    [ -f "$out/classes/shell.jar" ] || { echo "build.sh: kotlinc failed" >&2; exit 1; }
    "$java_home/bin/java" -cp "$build_tools/lib/d8.jar" com.android.tools.r8.R8 --release --min-api 29 \
        --lib "$android_jar" --pg-conf "$here/app/rules.pro" --output "$out/dex" \
        "$out/classes/shell.jar" "$kotlin_lib/kotlin-stdlib.jar" >&2
fi
cp "$out/dex/classes.dex" "$stage/classes.dex"

# ---- 6. The APK ----
step "aapt2 + zipalign + apksigner"
# The dev client opens from rocx dev's page (`rocx-dev://connect?origin=…`, `rocx dev --android --lan`).
dev_link=""
if [ -n "$dev_client" ]; then
    dev_link='<intent-filter><action android:name="android.intent.action.VIEW" /><category android:name="android.intent.category.DEFAULT" /><category android:name="android.intent.category.BROWSABLE" /><data android:scheme="rocx-dev" android:host="connect" /></intent-filter>'
fi
sed -e "s|@PACKAGE@|$package|" -e "s|@LABEL@|$label|" -e "s|@ORIGIN@|$origin|" -e "s|@DEV_LINK@|$dev_link|" "$here/app/AndroidManifest.xml" > "$out/AndroidManifest.xml"
"$build_tools/aapt2" link -o "$out/base.apk" -I "$android_jar" --manifest "$out/AndroidManifest.xml" >&2
(cd "$stage" && zip -q -D "$out/base.apk" classes.dex && zip -q -D -0 "$out/base.apk" lib/arm64-v8a/*.so)
"$build_tools/zipalign" -f -P 16 4 "$out/base.apk" "$out/aligned.apk"
key="$here/build/spike.keystore"
if [ ! -f "$key" ]; then
    "$java_home/bin/keytool" -genkeypair -keystore "$key" -storepass rocx-spike -keypass rocx-spike -alias spike \
        -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=rocx spike" >/dev/null 2>&1
fi
"$java_home/bin/java" --enable-native-access=ALL-UNNAMED -jar "$build_tools/lib/apksigner.jar" sign --ks "$key" --ks-pass pass:rocx-spike --key-pass pass:rocx-spike --ks-key-alias spike \
    --out "$out/$name.apk" "$out/aligned.apk"
rm -f "$out/base.apk" "$out/aligned.apk" "$out/$name.apk.idsig"

if [ -n "$dev_client" ]; then
    mv "$out/$name.apk" "$out/rocx-dev.apk"
    size=$(stat -f %z "$out/rocx-dev.apk" 2>/dev/null || stat -c %s "$out/rocx-dev.apk")
    echo "build.sh: $out/rocx-dev.apk ($((size / 1024)) KB, the dev client $package) in $(( $(date +%s) - started )) s" >&2
    echo "$out/rocx-dev.apk"
    exit 0
fi

# ---- 7. What a phone ignores ----
step "the app on the native host, on the Mac (what a phone ignores)"
# Built as the APK's is (`--opt`, speed by default): the dev backend's arm64mac code can put a long
# string literal at an address that isn't a multiple of 8, where Roc's refcounting looks for its
# count in the wrong word and writes to read-only memory (seen on rebasing onto D-040's routes).
[ -n "$host_only" ] && [ -f "$out/libapp-mac.a" ] || "$roc" build --target=arm64mac --opt="$opt" --output="$out/libapp-mac.a" "$out/client/main.roc" >/dev/null 2>&1 || [ $? -eq 2 ]
(cd "$repo/native" && ROCX_APP_ARCHIVE="$out/libapp-mac.a" cargo build -q -p rocx-native-mac 2>/dev/null)
"$repo/native/target/debug/rocx-native-mac" --origin http://127.0.0.1:9 2>&1 | grep '\[Warn\]' | sed 's/^\[Warn\] /build.sh: phone: /' >&2 || true

size=$(stat -f %z "$out/$name.apk" 2>/dev/null || stat -c %s "$out/$name.apk")
echo "build.sh: $out/$name.apk ($((size / 1024)) KB, $package, server $origin) in $(( $(date +%s) - started )) s" >&2
echo "$out/$name.apk"
