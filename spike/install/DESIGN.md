# A one-command install, and `rocx new` (design, 2026-11-25; built: D-078)

The user asked for both (2026-11-24: the three things Roc Solid needs next are a one-command
install, `rocx new`, and sign-in, which is packages/auth). This is the design the work follows; the
decision is D-078 once it lands. File references are as of master 96bfe3a.

## Decisions taken (the user can change any)

1. **Versions are dates**: tag `v2026.11.25`, `2026.11.25.2` for a second release that day. One
   version is one fork pin and one repo commit.
2. **`rocx test` and `rocx build --release` come now**, so a new app needs no Node and no `roc` on
   PATH to test and deploy.
3. **The macOS archive carries the Linux deploy targets** (arm64musl, x64musl): a Mac builds the
   server it deploys.
4. **The template's sign-in mail limit trusts one proxy** (`Hops(1)`): the server speaks plain HTTP
   and goes behind a TLS proxy in production; the template's README says to change it to `Direct`
   with no proxy in front.

## 1. What a machine needs today

| Needed | Where (file:line) | Who provides it |
|---|---|---|
| The fork compiler | every build; `Hosts.roc!` takes `<clone>/.tools/roc-active`, else `$ROC` (`rocx-cli/Hosts.roc:22-32`, `server/build.mjs:43-52`) | `just setup` (`Justfile:106-142`), macOS arm64 and Linux arm64 only |
| Rust (and rustup's musl target on Linux) | the server's `libhost.a` on the first `rocx dev`/`check --sql`/`build --static` (`Hosts.roc:143-177`); on Linux cargo runs on every build (the skip at :164 is for non-musl only) | `just setup:86-104` |
| Zig 0.17.1 | the browser's `host.wasm` (`Dev.roc:817-828`, `Justfile:478-486`); `zig cc` for the server host's C on Linux (`Hosts.roc:150-158`) | `just setup:61-69` |
| Node | not by `rocx dev/build/check/--static` (D-062, D-073); still the documented production build (`node server/build.mjs`, `server/build.mjs:306-309`, README:920) and every HTTP test | the user |
| A clone of this repo | `rocx_home!` is the parent of the real binary's folder (`rocx-cli/main.roc:59-63`); the build reads `web/start.js`, `web/runtime.js`, `web/platform`, `server/platform` from it (`Build.roc:937,970,1026`); headers reach the platform by relative paths; `write_main!` writes a path back to the clone (`Dev.roc:366`) | |
| NDK, SDK, Java, kotlinc, cargo | `rocx dev --android` only (`Dev.roc:478-520,734-766`) | the user |

CI doesn't publish the fork compiler: `just publish-roc-fork` (`Justfile:176-219`) uploads it from
the Mac that has the fork; CI downloads it by its pinned SHA-256.

Prebuilt artifacts, measured: `arm64mac/libhost.a` 273 MB (49 MB zstd; 191 MB of it debug info,
`debug = 1` in `server/host/Cargo.toml`), `arm64musl/libhost.a` 159 MB (20 MB zstd) plus `libc.a`
6.5 MB, `libunwind.a`, `rcrt1.o`; `host.wasm` 247 KB; the fork `roc` 289 MB (44 MB xz); `bin/rocx`
6.6 MB; platforms, packages and runtime sources 3.6 MB.

## 2. How an app names the platform and packages

- **(a) Roc URL bundles: not now.** The fork has them (`roc bundle`, https + BLAKE3), but rocx's
  build reads packages from disk (components, `browser.roc`, server-only modules: `Build.roc:1132-1345`),
  bundles leave out `.rocx` and `browser.roc`, nothing outside a package's root may go in one
  (every `../crypto/main.roc` would need a URL), a platform bundle carries every target's hosts
  (512 MB cap: `src/base/mod.zig:83`), and it doesn't pin the compiler.
- **(b) A copy in each app: no.** Hundreds of MB per app, gitignored anyway; `check --sql` copies
  the app's tree.
- **(c) Chosen: a link and a version file.** `.rocx-version` (committed) names the version;
  `.rocx` (gitignored) links to `~/.rocx/versions/<v>`, made and repaired by every rocx command;
  headers say `./.rocx/…` (the fork refuses absolute platform paths: `compile_build.zig:1068-1077`).
  Same header everywhere, hosts beside the platform (`targets/` through the link), `--static`
  unchanged, hidden entries already skipped by rocx's walk (`Fs.roc:221`) and the watcher, `check
  --sql` copies a link as a link (`cli/host/src/lib.rs:271-275`), and the fork resolves paths
  without following links (`compile_build.zig:1743-1746`), so app and packages name the same
  platform.

Changes in rocx: an "app root" (the app's `.rocx` if it has one, else rocx's own home, so the
examples are unchanged) passed to Dev, Build, Static, CheckSql and fmt in place of `rocx_home!`;
the compiler at `<root>/bin/roc`, then `.tools/roc-active`, then `$ROC`; `server_host!` skips cargo
when `server/host/` is absent (macOS and Linux); `Build.roc:1239` counts `./.rocx/…` package paths
as packages, not only `..`; `write_main!` writes `./.rocx/…`; `rocx fmt` uses the root's compiler.

## 3. Release, install, versions

Release assets (a full release, as `releases/latest` skips pre-releases):
`rocx-macos_arm64.tar.xz`, `rocx-linux_arm64.tar.xz`, `rocx-linux_x86_64.tar.xz`, `SHA256SUMS`,
`install.sh` (that release's version and SHA-256s baked in).

```
rocx-2026.11.25/
  VERSION                 "2026.11.25 <commit> rocx-fork-<pin>"; `rocx --version` reads it
  LICENSE, NOTICES        crates', musl's, Roc's legal details
  bin/rocx   bin/roc
  web/start.js  web/runtime.js  web/platform/*.roc  web/platform/targets/wasm32/host.wasm
  server/platform/*.roc
  server/platform/targets/arm64mac/libhost.a                          (macOS archive)
  server/platform/targets/{arm64musl,x64musl}/{libhost.a,rcrt1.o,libunwind.a,libc.a}
  packages/<each>/        (git ls-files, without example/, test/, *.mjs)
  templates/app/
```

The repo's own layout, so no header is rewritten. Host libraries stripped of debug info. About
80–95 MB to download on macOS, 65–80 MB on Linux; 450–500 MB unpacked.

```
~/.rocx/                  ($ROCX_HOME)
  bin/rocx -> ../current/bin/rocx      (on PATH)
  current  -> versions/2026.11.25
  versions/<v>/                        (read-only)
```

`install.sh` (POSIX sh; `curl -fsSL https://github.com/Roc-Solid/rocx/releases/latest/download/install.sh | sh`,
or `sh -s -- <version>`): map OS and CPU to an archive (refuse Intel Macs and the rest), check for
curl, tar, xz, a sha256 tool; download to a temp dir, check the baked-in SHA-256, unpack to
`versions/<v>.partial`, rename into place, make it read-only; point `current`, add `~/.rocx/bin` to
bash/zsh/fish rc files (print the line for others; `--no-modify-path`), run `rocx --version`.

Every app command (`dev`, `build`, `check`, `test`, `routes`, `lint`) reads the app's
`.rocx-version`: if it isn't rocx's own, rocx runs that version's binary in its place (`Cmd.exec!`),
installing it first if missing (as rustup does), then makes sure `.rocx` points at its home. From a
clone (no `VERSION`), `.rocx` links to the clone. `rocx upgrade [v]` installs and moves `current`;
in an app it also rewrites `.rocx-version` and the link. Uninstall: `rm -rf ~/.rocx` and the PATH line.

Nix: `flake.nix` at the root reads `nix/release.json` (version; per system the file and hash);
`packages.default` per `aarch64-darwin`, `aarch64-linux`, `x86_64-linux` is a `stdenvNoCC`
derivation (fetchurl, copy to `$out/lib/rocx`, link `$out/bin/rocx`, `dontFixup`: the Linux binaries
are static musl); `apps.default`, `devShells.default`. Under `/nix/store` rocx never downloads; a
version mismatch names the flake input to bump; `rocx upgrade` says Nix manages it.

## 4. `rocx new`

`rocx new <dir> [--db sqlite|postgres|turso]`: refuses a non-empty directory; without `--db` on a
terminal asks "1. SQLite [default] 2. Postgres 3. Turso" (off a terminal: SQLite, said); copies
`<home>/templates/app/` filling in the name and the `database:` line (one migration SQL for all
three: text ids, `bigint`); writes `.rocx-version`, makes the link, prints `cd <dir> && rocx dev`.
The template is files under `templates/app/` (the same path in a clone and an install), not
embedded. The CLI platform needs `Stdin.line!`, a terminal check and `File.symlink!`.

The generated app:

```
.rocx-version  .rocx -> ~/.rocx/versions/<v>  .gitignore (/.rocx Generated/ build/ data/ components/*.roc *.db*)
README.md        run, mail (SMTP_URL, PUBLIC_URL), database, deploy (build --release, a TLS proxy), CI, upgrade
main.roc
Middlewares.roc  default (same_origin + guard's security headers), signed_in (Auth.required_with), anyone, mail_limit
Accounts.roc     User, admit! (known user, else made by address), user!
components/Nav.rocx               a pure component, with an expect
migrations/0001_users.sql
routes/+layout.rocx  +error.rocx  +page.rocx
routes/api/me/+server.roc         who is signed in, for the layout
routes/sign-in/+page.rocx  +server.roc (GET: providers, dev sign-in; the page reads auth.SignInError)
routes/sign-in/mail/+server.roc   POST: Auth.link! + Email.send!; middleware = mail_limit
routes/sign-in/link/+page.rocx  +server.roc
routes/account/+page.rocx  +server.roc (middleware = signed_in)
```

The sign-in mail has its own route so its rate limit counts mails, not page loads.

```roc
app [program] { auth: "./.rocx/packages/auth/main.roc", crypto: "./.rocx/packages/crypto/main.roc", email: "./.rocx/packages/email/main.roc", guard: "./.rocx/packages/guard/main.roc", pf: platform "./.rocx/server/platform/main.roc", testing: "./.rocx/packages/testing/main.roc" }

program = App.program({
	init!: |_started| Ok({}),
	middleware: Middlewares.default,
	plugins: [Email.plugin({ from: "My app <hello@example.com>" }), Auth.plugin({ admit!: Accounts.admit!, link_page: "/sign-in/link", cookie: "my_app_session" })],
	database: Sqlite("data/app.db"),
})
```

## 5. CLI surface

`rocx new <dir> [--db …]`; `rocx upgrade [<version>]`; `rocx --version`; `rocx test [dir]`
(`rocx build`, then the root's `roc test main.roc`, reports at `.rocx` lines); `rocx build <dir>
--release <out> [--target arm64mac|arm64musl|x64musl]` (the server `--opt=speed --specialize=no`,
D-064; the wasm `--opt=size --specialize=yes`, as `Static.roc:243-250`), replacing `node
server/build.mjs` for deploys. Every app command honours `.rocx-version`. `self-build` and `site`
refuse to run outside a clone.

## 6. CI

New `.github/workflows/release.yml` on tag `v*` (and a manual dry run): `hosts-linux`
(`ubuntu-24.04-arm`: server and CLI hosts for arm64musl and x64musl via `zig cc`, `bin/rocx` for
both, `host.wasm`, stripped), `hosts-macos` (`macos-15`), `pack` (pinned compilers from
`roc-fork-<sha>`, `just release-pack`: archives, `SHA256SUMS`, `install.sh`), `smoke` (macOS, and
bare `alpine` on arm64 and x86_64 with only curl, xz, tar: install read-only, `rocx new` each
database, `check`, `test`, `check --sql`, `build --static`, `build --release`, start under `--dev`,
sign in through `/auth/dev`, `/account` 200), `publish` (`gh release create`, commit
`nix/release.json`; `contents: write`). `ci.yml`: `just new-check` in `check`; `test/new.test.mjs`
in `test-rocx` (its Postgres case in `test-server`). The fork compiler gains linux_x86_64
(`-Dtarget=x86_64-linux-musl`, built on the Mac) and a pin.

## 7. Steps

1. Spike: a release folder by hand from a clone, an app outside the repo linked to it; build, run,
   sign in with an empty PATH and a read-only install; measure the stripped hosts.
2. App root, compiler lookup, `server_host!` skip, the `Build.roc:1239` fix, `write_main!`, fmt's
   compiler, `--version`.
3. CLI platform: `Stdin.line!`, a terminal check, `File.symlink!` (Rust, `just glue`).
4. The template (from `packages/auth/example`) and `New.roc`.
5. `rocx test` and `build --release`.
6. Version dispatch and `rocx upgrade`.
7. Justfile release recipes, `install.sh`, the x86_64 compiler.
8. `release.yml`, `ci.yml`, `test/new.test.mjs`.
9. `flake.nix`, `nix/release.json`.
10. Docs: README's Getting started, the tooling page, D-078, the D-045/D-046 `rocx new` items,
    `cli/README`, TODO.

Risks: the x86_64 server host has never been built (the smoke job is its first run); packages/auth
on Turso is untested (the smoke matrix covers it). The fork's binary needs macOS 15 or newer.
Publishing a release to GitHub is the user's call, each time.
