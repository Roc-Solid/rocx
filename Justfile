# rocx: the transpiler (rocx-cli/, bin/), the web platform (web/, wasm, in the browser), the server
# platform (server/, native, in a Rust host), and the docs site (site/), which is written in rocx
# and runs on them.

# The toolchain is pinned: Roc's new compiler changes fast, and the glue the host is built
# with (web/host/roc_platform_abi.zig) must match the compiler that links against it.
roc_nightly := "nightly-2026-11-18-a520eed"
roc_commit := "a520eeda6c3745f2543fcdd0fb836d3d1336c5ac"
zig_version := "0.17.1"
# Rust: any 1.85 or newer builds the server's host (edition 2024). The system's, on PATH (e.g. from
# Nix), when it is; else rustup installs rust_version into .tools/rust.
rust_minimum := "1.85"
rust_version := "1.100.0"

# Until the compiler fixes rocx needs are in a nightly, rocx builds with a fork of the nightly's
# commit that has them: the `rocx` branch of the fork in ~/roc-fork (ROC_FORK names another),
# local only until they are upstream. `just setup` builds its commit into .tools/roc-fork/<commit>/
# and links it as .tools/roc-active: the compiler every script uses (`roc` here; site/build.mjs,
# server/build.mjs and the tests), or, without it, the one ROC names; never the `roc` on PATH,
# which may lack the fixes. test/compiler-bugs/ has each bug it fixes, and `just compiler-bugs`
# shows which the nightly still has. The nightly stays in .tools/roc/.
roc_fork := env_var_or_default("ROC_FORK", env_var("HOME") + "/roc-fork")
roc_fork_commit := "4674b5973d4cea3875c2d33c6a63c95ff1d26843"

# Variables are worked out when a recipe uses them: `just setup` needs no compiler yet.
set lazy

roc := if path_exists(".tools/roc-active") == "true" { ".tools/roc-active" } else if env("ROC", "") != "" { env("ROC") } else { error("no Roc compiler: run `just setup` (or set ROC)") }
# Zig: the system's, on PATH (e.g. from Nix), when it is zig_version; else the one in .tools.
zig := if `zig version 2>/dev/null || true` == zig_version { "zig" } else { justfile_directory() / ".tools/zig/zig" }
# rocx itself: bin/rocx, built from its Roc (rocx-cli/*.roc, on the CLI platform in cli/) when that
# changed, by rocx (`rocx self-build`, as server/build.mjs's rocxBinary does for the JavaScript);
# by the shell when there is none yet, or it is one from before `self-build` (`just rocx-bootstrap`).
rocx := `bin/rocx self-build 2>/dev/null || { just rocx-bootstrap >&2 && bin/rocx self-build; }`

default:
    @just --list

# The toolchain, into .tools/: Zig and Rust, unless the system's (on PATH, e.g. from Nix) will do;
# the pinned Roc nightly and the glue spec for `just glue`; then the Roc fork rocx builds with
# (`roc_fork_commit`), built and linked as .tools/roc-active; then bin/rocx.
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    case "$(uname -s)-$(uname -m)" in
        Darwin-arm64) roc_os=macos_apple_silicon; zig_os=aarch64-macos; rust_os=aarch64-apple-darwin ;;
        Darwin-x86_64) roc_os=macos_x86_64; zig_os=x86_64-macos; rust_os=x86_64-apple-darwin ;;
        Linux-x86_64) roc_os=linux_x86_64; zig_os=x86_64-linux; rust_os=x86_64-unknown-linux-gnu ;;
        Linux-aarch64) roc_os=linux_arm64; zig_os=aarch64-linux; rust_os=aarch64-unknown-linux-gnu ;;
        *) echo "No pinned toolchain for $(uname -s) $(uname -m)" >&2; exit 1 ;;
    esac
    if [ "{{ zig }}" = zig ]; then
        echo "Zig {{ zig_version }}: the system's, $(command -v zig)"
    elif [ ! -x .tools/zig/zig ]; then
        mkdir -p .tools/download .tools/zig
        curl -fsSL -o .tools/download/zig.tar.xz "https://ziglang.org/download/{{ zig_version }}/zig-$zig_os-{{ zig_version }}.tar.xz"
        expected=$(curl -fsSL https://ziglang.org/download/index.json | python3 -I -c "import json, sys; print(json.load(sys.stdin)['{{ zig_version }}']['$zig_os']['shasum'])")
        echo "$expected  .tools/download/zig.tar.xz" | shasum -a 256 -c -
        tar -xJf .tools/download/zig.tar.xz -C .tools/zig --strip-components 1
    fi
    if ! ls .tools/roc/roc_nightly-*/roc >/dev/null 2>&1; then
        mkdir -p .tools/download .tools/roc
        nightly={{ roc_nightly }}
        curl -fsSL -o .tools/download/roc.tar.gz "https://github.com/roc-lang/nightlies/releases/download/$nightly/roc_nightly-$roc_os-${nightly#nightly-}.tar.gz"
        tar -xzf .tools/download/roc.tar.gz -C .tools/roc
    fi
    if [ ! -f .tools/glue/src/ZigGlue.roc ]; then
        rm -rf .tools/roc-src
        git clone -q --depth 1 --filter=blob:none --sparse https://github.com/roc-lang/roc.git .tools/roc-src
        git -C .tools/roc-src sparse-checkout set src/glue
        git -C .tools/roc-src fetch -q --depth 1 origin {{ roc_commit }}
        git -C .tools/roc-src checkout -q {{ roc_commit }}
        mkdir -p .tools/glue
        cp -R .tools/roc-src/src/glue/src .tools/roc-src/src/glue/platform .tools/glue/
        rm -rf .tools/roc-src
    fi
    # The server platform's host (server/host) is Rust: the system's cargo and rustc when both are
    # rust_minimum or newer, else rustup's rust_version, kept in .tools, not on PATH.
    system_rust() {
        IFS=. read -r least_major least_minor <<< "{{ rust_minimum }}"
        for tool in cargo rustc; do
            version=$("$tool" --version 2>/dev/null | awk '{ print $2 }')
            IFS=. read -r major minor _ <<< "${version:-0.0}"
            [ "$major" -gt "$least_major" ] || { [ "$major" -eq "$least_major" ] && [ "$minor" -ge "$least_minor" ]; } || return 1
        done
    }
    if system_rust; then
        echo "Rust $(rustc --version | awk '{ print $2 }'): the system's, $(command -v cargo)"
    elif [ ! -x .tools/rust/cargo/bin/cargo ]; then
        mkdir -p .tools/download
        curl -fsSL -o .tools/download/rustup-init "https://static.rust-lang.org/rustup/dist/$rust_os/rustup-init"
        echo "$(curl -fsSL "https://static.rust-lang.org/rustup/dist/$rust_os/rustup-init.sha256" | cut -d' ' -f1)  .tools/download/rustup-init" | shasum -a 256 -c -
        chmod +x .tools/download/rustup-init
        RUSTUP_HOME="$PWD/.tools/rust/rustup" CARGO_HOME="$PWD/.tools/rust/cargo" .tools/download/rustup-init -y --no-modify-path --profile minimal --default-toolchain {{ rust_version }}
    fi
    rm -rf .tools/download
    commit={{ roc_fork_commit }}
    if [ ! -x ".tools/roc-fork/$commit/bin/roc" ]; then
        # The fork's compiler, from a clone that shares the fork's objects (its checkouts are left
        # as they are), built as the nightlies are: 10 to 20 minutes, and the network once, for Zig
        # to fetch LLVM.
        if ! git -C "{{ roc_fork }}" cat-file -e "$commit^{commit}" 2>/dev/null; then
            echo "rocx builds with a fork of Roc: no commit $commit in {{ roc_fork }} (ROC_FORK)" >&2
            exit 1
        fi
        rm -rf .tools/roc-fork/src
        mkdir -p .tools/roc-fork
        git clone -q --shared --no-checkout "{{ roc_fork }}" .tools/roc-fork/src
        git -C .tools/roc-fork/src checkout -q "$commit"
        (cd .tools/roc-fork/src && "{{ zig }}" build build-release -Dcompiler-version="rocx-fork-${commit:0:10}" --prefix "$OLDPWD/.tools/roc-fork/$commit")
        rm -rf .tools/roc-fork/src
    fi
    ln -sfn "roc-fork/$commit/bin/roc" .tools/roc-active
    .tools/roc-active version
    # rocx itself, bin/rocx, from its Roc (rocx-cli/) on the CLI platform (cli/): `rocx dev` for an
    # app, and every script here.
    bin/rocx self-build 2>/dev/null || { just rocx-bootstrap && bin/rocx self-build; }

# Each Roc compiler bug rocx has met (test/compiler-bugs/*/repro.sh), with the pinned nightly and
# with the fork rocx builds with: what the fork fixes, and, with a newer nightly, what it still needs.
compiler-bugs:
    #!/usr/bin/env bash
    set -uo pipefail
    nightly="$PWD/$(ls -d .tools/roc/roc_nightly-*/roc)"
    for repro in test/compiler-bugs/*/repro.sh; do
        echo "== ${repro%/repro.sh}"
        echo "-- the nightly ($("$nightly" version))"
        ROC="$nightly" "$repro"
        echo "-- the fork ($(.tools/roc-active version))"
        ROC="$PWD/.tools/roc-active" "$repro"
    done

# The docs site at http://localhost:8080: its server (site/main.roc, native, on the server
# platform) answering every page as it is asked for, rebuilt, restarted and reloaded on save. With
# DATABASE_URL set (`just db`), its Postgres.
dev port="8080":
    {{ rocx }} site dev --port {{ port }}

# bin/rocx from nothing, without Node: the CLI platform's host (cli/host, Rust) where Roc links it,
# then rocx (rocx-cli/main.roc) on it, optimized. Once there, rocx builds itself again when it
# changed (`rocx self-build`; `just dev` does it as it starts, and runs the new one).
rocx-bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    case "$(uname -sm)" in
        "Darwin arm64") target=arm64mac triple=aarch64-apple-darwin ;;
        "Darwin x86_64") target=x64mac triple=x86_64-apple-darwin ;;
        *aarch64) target=arm64musl triple=aarch64-unknown-linux-musl ;;
        *) target=x64musl triple=x86_64-unknown-linux-musl ;;
    esac
    dir="cli/platform/targets/$target"
    mkdir -p "$dir" bin
    if [[ "$target" == *musl ]]; then
        rustup target add "$triple"
        crt="$(rustc --print sysroot)/lib/rustlib/$triple/lib/self-contained"
        cp "$crt/rcrt1.o" "$crt/libunwind.a" "$crt/libc.a" "$dir/"
    fi
    (cd cli/host && cargo build --release --target "$triple")
    cp "cli/host/target/$triple/release/librocx_cli_host.a" "$dir/libhost.a"
    # 2: warnings alone.
    {{ roc }} build --opt=speed --output=bin/rocx rocx-cli/main.roc || [ $? -eq 2 ]
    printf speed > bin/.rocx-opt

# A Postgres for the server platform, in Docker; prints its URL (for DATABASE_URL).
db:
    #!/usr/bin/env bash
    set -euo pipefail
    if docker ps -a --format '{{{{.Names}}' | grep -qx rocx-postgres; then
        docker start rocx-postgres >/dev/null
    else
        docker run -d --name rocx-postgres -e POSTGRES_USER=rocx -e POSTGRES_PASSWORD=rocx -e POSTGRES_DB=rocx -p 127.0.0.1:55432:5432 postgres:18-alpine >/dev/null
    fi
    until docker exec rocx-postgres pg_isready -U rocx -q; do sleep 0.5; done
    echo "postgres://rocx:rocx@127.0.0.1:55432/rocx"

# The docs site as static files in site/dist, every page as its server answers it (and the
# comparison of build options it shows).
site:
    node site/build.mjs

# Publishes the site to https://roc-solid.github.io/, from this machine only: `just site`, then
# site/dist alone, no source and no history, as the one commit of the main branch of
# Roc-Solid/roc-solid.github.io, force-pushed. GitHub Pages serves that branch at the domain's root.
# Never a gh-pages branch of this repo: its Pages would take over /rocx/* of the site. Nothing is
# pushed if a file holds this machine's home directory, or matches a pattern in
# .git/info/private-words (one extended regex a line, matched without case; kept out of the repo, so
# the words aren't published either). Nor is a dev build's site (`just dev`'s, Roc's dev backend):
# its wasm is four times the size, and its pages say what it is.
deploy-pages: site
    #!/usr/bin/env bash
    set -euo pipefail
    # What is published is checked, site/dist itself: its wasm, and its pages' footers.
    wasm=site/dist/rocx/app.wasm
    if [ ! -s site/dist/index.html ] || [ ! -s "$wasm" ]; then
        echo "Not published: site/dist has no site in it (no index.html, or no rocx/app.wasm). Run just site." >&2
        exit 1
    fi
    bytes=$(wc -c < "$wasm" | tr -d ' ')
    if [ "$bytes" -gt 1500000 ]; then
        echo "Not published: site/dist/rocx/app.wasm is $((bytes / 1024)) KB, a dev build's (just site's is about 700 KB)." >&2
        echo "A dev build (just dev) wrote site/build while just site copied it: stop just dev, or restart it, then try again." >&2
        exit 1
    fi
    if dev=$(grep -rlE 'class="meta[^"]*">[[:space:]]*A development build' site/dist --include='*.html'); then
        echo "Not published: these pages are a dev build's (site/build/context.txt said dev=yes when they were rendered):" >&2
        echo "$dev" | head -5 >&2
        exit 1
    fi
    remote=https://github.com/Roc-Solid/roc-solid.github.io.git
    words="$(git rev-parse --git-common-dir)/info/private-words"
    leaks=$( { grep -rlF "${HOME:?}" site/dist; [ ! -s "$words" ] || grep -rliE -f "$words" site/dist; } | sort -u || true)
    if [ -n "$leaks" ]; then
        echo "Not published: these files hold what must stay private:" >&2
        echo "$leaks" >&2
        exit 1
    fi
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -R site/dist/. "$tmp"
    touch "$tmp/.nojekyll"
    git -C "$tmp" init -q -b main
    git -C "$tmp" add -A
    git -C "$tmp" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" commit -q -m "The site, built from $(git describe --always --dirty)"
    git fetch -q "$tmp" main
    git push -f "$remote" FETCH_HEAD:refs/heads/main
    echo "Published: https://roc-solid.github.io/ (Pages takes a minute to update)"

# Everything: the transpiler and the routes; every Roc module's expects (rocx's own, rocx-cli/; the
# platform's modules, the pages and their components, the highlighter: site/main.roc imports them
# all; and every package's, packages/*/main.roc); the web platform in Node and a browser; the site
# in a browser, served by the native server; the server platform; packages/testing's and
# packages/posthog's own tests, and packages/guard's example's, against an app each builds (once
# the server's host is). One file at a time: the web platform's tests and the site's both build its
# host. The browser tests need Chromium (see web/test/browser.mjs); the server platform's Postgres,
# jobs, cron and actors tests, and packages/testing's and packages/posthog's database tests,
# DATABASE_URL (`just db`).
test:
    ROC={{ roc }} node --test 'test/*.test.mjs'
    {{ roc }} test rocx-cli/main.roc
    {{ rocx }} site prepare
    {{ roc }} test site/main.roc
    for package in packages/*/main.roc; do echo "$package"; {{ roc }} test "$package" || exit 1; done
    ROC={{ roc }} node --test --test-concurrency=1 'web/test/*.test.mjs' 'site/test/*.test.mjs'
    ROC={{ roc }} node --test 'server/test/*.test.mjs'
    ROC={{ roc }} node --test 'packages/testing/test/*.test.mjs' 'packages/posthog/test/*.test.mjs' 'packages/guard/example/test/*.test.mjs' 'packages/push/example/test/*.test.mjs'

# Type-checks the site, both programs, with reports pointed into .rocx files, and lints its markup:
# the server's, and the browser's, built from the copy of the site in which a route file has no
# middleware and a <NoHydration> no children (site/build/client, whose main.roc rocx build writes).
# Then each package's modules for the server (packages/*/server/main.roc, a package that names the
# server platform), which no app here imports, and the example apps' two programs
# (`examples-check`; `just examples` builds and tests them too). First, that everything is
# formatted (`just fmt` formats it).
check: (fmt "--check")
    {{ rocx }} site prepare
    {{ rocx }} lint site web/test/app
    {{ rocx }} check -- {{ roc }} check site/main.roc
    {{ rocx }} check -- {{ roc }} check site/build/client/main.roc
    for package in packages/*/server/main.roc; do {{ roc }} check "$package" || exit 1; done
    just examples-check

# Formats the Roc of the site, the packages (packages/*), the platforms and the example apps
# (`examples`, below) with roc fmt: each .rocx file's (its markup kept as written) and each
# hand-written .roc file. `just fmt --check` only says which aren't formatted.
fmt *args:
    ROC={{ roc }} {{ rocx }} fmt {{ args }} rocx-cli cli/platform site packages web/platform server/platform {{ examples }}

# Checks the editor support (editors/): every .rocx file git tracks, tokenized by VS Code's
# TextMate engine with the grammar in editors/grammars, must end with its markup closed, or the
# grammar took a `<` for markup that wasn't; then the VS Code extension's tests (its reading of
# rocx's reports, its tasks against a stand-in for VS Code). The engine (vscode-textmate and
# vscode-oniguruma, from npm) is installed once into .tools/grammar.
grammar-check:
    test -d .tools/grammar/node_modules/vscode-textmate || npm install --silent --no-save --no-package-lock --prefix .tools/grammar vscode-textmate@9 vscode-oniguruma@2
    git ls-files -z '*.rocx' | xargs -0 node editors/check-grammar.cjs .tools/grammar/node_modules editors/grammars
    node --test 'editors/vscode/test/*.test.mjs'

# The VS Code extension (editors/vscode, with the rocx grammar from editors/grammars), packaged
# into editors/build/rocx-<version>.vsix by vsce (from npm) and installed into VS Code (`code` on
# the PATH), for every workspace. Again after a pull, to update it.
vscode-extension:
    rm -rf editors/build/vscode && mkdir -p editors/build/vscode/syntaxes
    cp editors/vscode/package.json editors/vscode/extension.js editors/vscode/reports.js editors/vscode/README.md editors/build/vscode/
    cp editors/grammars/rocx.tmLanguage.json editors/grammars/rocx.language-configuration.json editors/build/vscode/syntaxes/
    cd editors/build/vscode && npx --yes @vscode/vsce@3 package --no-dependencies --skip-license --out ../rocx.vsix
    code --install-extension editors/build/rocx.vsix --force

# The Orca plugin (editors/orca, with every grammar from editors/grammars: Orca colours only what a
# plugin ships), put together in editors/build/orca and installed into Orca. Again after a pull.
orca-plugin:
    rm -rf editors/build/orca && mkdir -p editors/build/orca/syntaxes
    cp editors/orca/orca-plugin.json editors/orca/README.md editors/build/orca/
    cp editors/grammars/* editors/build/orca/syntaxes/
    orca plugin validate editors/build/orca
    orca plugin install "$PWD/editors/build/orca"

# The example apps: each examples/<name>/main.roc that git tracks, by its directory. Only tracked
# ones: an untracked directory under examples/ (a private repo of one's own, say) is never built,
# formatted or tested.
examples := `git ls-files 'examples/*/main.roc' | xargs -n1 dirname | tr '\n' ' '`

# Builds, checks and tests every example app (or the ones named: `just examples tasks echo`), as
# each one's README says to: `rocx build` (and the browser's copy), its server program type-checked,
# and its browser program when it has one (component pages: the build writes the copy's main.roc;
# an app of endpoints alone, as echo is, has none, and the build says so), each with reports at .rocx lines;
# `rocx lint`; its SQL, checked by its database engine (`rocx check --sql`, D-058); its expects
# (`roc test`); and its node tests, examples/<name>/test/*.test.mjs, when
# it has them (a glob: `node --test <dir>` doesn't find them on Node 24; helper modules there
# don't end in .test.mjs). They need nothing for their database, all on SQLite (each test makes a
# file of its own), and Chromium for their browser tests, which skip without it. Every example is
# run, and those that
# failed are named at the end.
#
# Not part of `just test`: each example's tests build its wasm and its server (about a minute for
# the five here, more as examples come), and `just test` is already the long one. `just check` does
# the quick half (`examples-check`: build, type-check both programs, lint), so a change to the
# platform that breaks an example's code fails `just check`; run `just examples` before landing a
# change to the platforms, the packages or an example, to see each app still work.
examples *names:
    #!/usr/bin/env bash
    set -uo pipefail
    failed=()
    for dir in {{ if names == "" { examples } else { names } }}; do
        dir="examples/${dir#examples/}"
        name=$(basename "$dir")
        echo "== $name"
        if just examples-check "$name" \
            && ROC={{ roc }} {{ rocx }} check --sql "$dir" \
            && {{ rocx }} check -- {{ roc }} test "$dir/main.roc" \
            && { ! compgen -G "$dir/test/*.test.mjs" >/dev/null || ROC={{ roc }} node --test "$dir/test/*.test.mjs"; }; then
            echo "== $name: ok"
        else
            echo "== $name: FAILED" >&2
            failed+=("$name")
        fi
    done
    if [ ${#failed[@]} -gt 0 ]; then
        echo "Examples that failed: ${failed[*]}" >&2
        exit 1
    fi

# The quick half of `examples` (every one, or those named): rocx build with the browser's copy
# (examples/<name>/build/client), both programs type-checked with reports at .rocx lines (the
# browser's when the build wrote one), and rocx lint. No wasm, no server, no tests.
examples-check *names:
    #!/usr/bin/env bash
    set -euo pipefail
    for dir in {{ if names == "" { examples } else { names } }}; do
        dir="examples/${dir#examples/}"
        client="$dir/build/client"
        ROC={{ roc }} {{ rocx }} build "$dir" --client "$client"
        {{ rocx }} check -- {{ roc }} check "$dir/main.roc"
        if [ -f "$client/main.roc" ]; then
            {{ rocx }} check -- {{ roc }} check "$client/main.roc"
        fi
        {{ rocx }} lint "$dir"
    done

# Measures the example apps for the docs' examples page (/examples) into site/example-apps.json:
# each one's browser half (its wasm, --opt=size) raw, gzipped and brotli'd, and what it is made of.
# `just example-apps tasks plate` measures those alone; `just example-apps --bench` also runs echo's
# server under bombardier (a minute or so; best on a quiet machine). Run it after a change that
# moves the sizes, and commit the file: the site's build reads it, and doesn't measure.
example-apps *args:
    ROC={{ roc }} node site/example-apps.mjs {{ args }}

# Runs examples/sqlite-vs-turso's benchmark for its docs page (/examples/sqlite-vs-turso) into
# site/sqlite-vs-turso.json: the app built with --opt=speed, then on SQLite, on Turso (MVCC) and on
# Turso in WAL mode, each on files kept for the whole of it, POST /bench at size 100 ten times in a
# row (after a warm-up) and POST /bench/big at a million orders ten times in a row on another, every
# run's times kept, with the machine they ran on (eight minutes or so; best on a quiet machine,
# plugged in). `just db-bench --size 10 --orders 100000 --series 3` for a quick look. Commit the
# file: the site's build reads it, and doesn't measure.
db-bench *args:
    ROC={{ roc }} node site/sqlite-vs-turso.mjs {{ args }}

# Takes the example apps' screenshots for their docs pages (/examples/<app>) into
# site/static/shots/<app>/, as site/AppNotes.roc names them: each app built and started as its tests
# start it (DATABASE_URL for those on Postgres), given something to show, and each scene taken in
# Chromium, dark, wide or on a phone, as WebP. `just example-shots tasks` takes one app's. Commit
# them: the site's test checks every one AppNotes names is there.
example-shots *names:
    ROC={{ roc }} node site/example-shots.mjs {{ names }}

# Regenerates the platforms' glue after a change to a header: web/host/roc_platform_abi.zig,
# server/host/src/roc_platform_abi.rs, cli/host/src/roc_platform_abi.rs (rocx's platform) and
# native/core/src/roc_platform_abi.rs (the web platform's native host, D-063's spike).
glue:
    {{ roc }} glue .tools/glue/src/ZigGlue.roc web/host/ web/platform/main.roc
    {{ roc }} glue .tools/glue/src/RustGlue.roc server/host/src/ server/platform/main.roc
    {{ roc }} glue .tools/glue/src/RustGlue.roc cli/host/src/ cli/platform/main.roc
    {{ roc }} glue .tools/glue/src/RustGlue.roc native/core/src/ web/platform/main.roc
