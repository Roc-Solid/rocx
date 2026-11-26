// An app outside the repo, on an installed rocx (D-078): its `.rocx` links to a version of rocx (a
// release folder, read-only, made here from this clone as a release lays it out: VERSION, bin/rocx,
// bin/roc, web/, server/platform/ with its built host, packages/), its headers say `./.rocx/…`, and
// its `.rocx-version` names the version. With nothing on PATH but /usr/bin and /bin, and no ROC,
// that rocx checks it, tests it and builds it to deploy (`--release`: a server that starts and
// answers). `rocx --version` says which rocx it is; an app that wants another version is run by
// that version (installed first from ROCX_RELEASES, here a directory and a local HTTP server, never
// GitHub), and its link is mended; `rocx upgrade` moves an app to another version. ROCX_HOME is a
// directory of the test's own: ~/.rocx is never touched.
//
// Needs the toolchain (`just setup`) and both hosts built (`just server-host`, `just web-host`).
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { nativeTarget, roc, root, rocxBinary } from "../server/build.mjs";

const VERSION = "2026.11.25";
const OTHER = "2026.11.26";

const hosts = [join(root, "server", "platform", "targets", nativeTarget(), "libhost.a"), join(root, "web", "platform", "targets", "wasm32", "host.wasm")];
let compiler = null;
try {
	compiler = roc();
} catch {}
const skip = (!compiler && "no roc (run `just setup`, or set ROC)") || (!hosts.every(existsSync) && "the hosts aren't built (just server-host, just web-host)");

let work;
let release;
let rocx;

/** A release folder of rocx `version` at `dir`, from this clone, as a release lays it out; the big
 * files (the compiler, the server's host) linked, not copied. Read-only, as an install is. */
function makeRelease(dir, version) {
	mkdirSync(join(dir, "bin"), { recursive: true });
	copyFileSync(rocxBinary(), join(dir, "bin", "rocx"));
	spawnSync("chmod", ["+x", join(dir, "bin", "rocx")]);
	symlinkSync(compiler, join(dir, "bin", "roc"));
	const files = spawnSync("git", ["ls-files", "web/start.js", "web/runtime.js", "web/platform", "server/platform", "packages", "templates/app"], { cwd: root, encoding: "utf8" }).stdout.split("\n");
	for (const file of files.filter((file) => file && !/\/(example|test)\/|\.mjs$/.test(file))) {
		mkdirSync(dirname(join(dir, file)), { recursive: true });
		copyFileSync(join(root, file), join(dir, file));
	}
	mkdirSync(join(dir, "web", "platform", "targets", "wasm32"), { recursive: true });
	copyFileSync(hosts[1], join(dir, "web", "platform", "targets", "wasm32", "host.wasm"));
	// The server's host and, for a musl target, the C runtime beside it.
	const built = dirname(hosts[0]);
	const targets = join(dir, "server", "platform", "targets", nativeTarget());
	mkdirSync(targets, { recursive: true });
	for (const file of readdirSync(built).filter((name) => !name.endsWith(".tmp"))) symlinkSync(join(built, file), join(targets, file));
	// Last: a file newer than it was written into the install after.
	writeFileSync(join(dir, "VERSION"), `${version} test rocx-fork-test\n`);
	spawnSync("chmod", ["-R", "a-w", dir]);
	return dir;
}

/** A small app at `dir` whose `.rocx` links to `to` and whose `.rocx-version` says `version`: a
 * page, an endpoint, a module with an expect, and a package (crypto) through the link. */
function makeApp(dir, { to, version = VERSION }) {
	const files = {
		"main.roc": `app [program] { crypto: "./.rocx/packages/crypto/main.roc", pf: platform "./.rocx/server/platform/main.roc" }

import Generated/App

program = App.program({
	init!: |_started| Ok({}),
})
`,
		"Greeting.roc": `import crypto.Hex

## A greeting, and a name's bytes in hexadecimal.
Greeting := [].{
	## "Hello, <name>".
	text : Str -> Str
	text = |name| "Hello, \${name}"

	## The name's UTF-8 bytes in hexadecimal.
	hex : Str -> Str
	hex = |name| Hex.encode(name.to_utf8())
}

expect Greeting.text("you") == "Hello, you"
expect Greeting.hex("A") == "41"
`,
		"routes/+page.rocx": `import pf.Html
import ../Greeting

view! = |_| {
	<main>
		<h1>{Greeting.text("installed")}</h1>
	</main>
}
`,
		"routes/hello/+server.roc": `import pf.Server
import pf.Endpoint
import ../../Greeting

## GET /hello: the greeting, as a JSON string.
get! : { request : Server.Request, params : {}, context : c } => Try(Str, Endpoint.Refusal)
get! = |_| Ok(Greeting.text("endpoint"))
`,
		".rocx-version": `${version}\n`,
	};
	for (const [path, content] of Object.entries(files)) {
		mkdirSync(dirname(join(dir, path)), { recursive: true });
		writeFileSync(join(dir, path), content);
	}
	if (to) symlinkSync(to, join(dir, ".rocx"));
	return dir;
}

/** `rocx` (a path) with `args` in `cwd`, with nothing on PATH but /usr/bin and /bin, no ROC, and
 * `env` besides: its exit code and what it said. */
function bare(binary, args, { cwd = work, env = {} } = {}) {
	const ran = spawnSync(binary, args, { cwd, encoding: "utf8", maxBuffer: 1 << 28, env: { HOME: process.env.HOME, PATH: "/usr/bin:/bin", NO_COLOR: "1", ...env } });
	return { code: ran.status, said: `${ran.stdout}${ran.stderr}`, stdout: ran.stdout };
}

/** As `bare`, but not blocking this process (a local HTTP server answers it meanwhile). */
function bareAsync(binary, args, { cwd = work, env = {} } = {}) {
	return new Promise((resolve) => {
		const child = spawn(binary, args, { cwd, env: { HOME: process.env.HOME, PATH: "/usr/bin:/bin", NO_COLOR: "1", ...env } });
		let said = "";
		child.stdout.on("data", (chunk) => (said += chunk));
		child.stderr.on("data", (chunk) => (said += chunk));
		child.on("close", (code) => resolve({ code, said }));
	});
}

/** A releases directory (what ROCX_RELEASES names) with `install.sh` for `version` (at
 * download/v<version>/, and as the latest's), a stand-in for a release's own: it puts `from` into
 * $ROCX_HOME/versions/<version> and makes it `current`, refusing to run without --no-modify-path. */
function makeReleases(dir, version, from) {
	const script = `#!/bin/sh
set -eu
[ "\${1:-}" = "--no-modify-path" ] || { echo "install.sh: expected --no-modify-path" >&2; exit 2; }
mkdir -p "$ROCX_HOME/versions" "$ROCX_HOME/bin"
cp -R "${from}" "$ROCX_HOME/versions/${version}.partial"
mv "$ROCX_HOME/versions/${version}.partial" "$ROCX_HOME/versions/${version}"
ln -sfn "versions/${version}" "$ROCX_HOME/current"
ln -sfn ../current/bin/rocx "$ROCX_HOME/bin/rocx"
echo "install.sh: installed rocx ${version}"
`;
	for (const at of [join(dir, "download", `v${version}`), join(dir, "latest", "download")]) {
		mkdirSync(at, { recursive: true });
		writeFileSync(join(at, "install.sh"), script);
	}
	return dir;
}

/** Another version of rocx, for dispatch: this clone's rocx with another VERSION (what a command on
 * an app needs of it: none of the platform). */
function otherVersion(dir, version) {
	mkdirSync(join(dir, "bin"), { recursive: true });
	writeFileSync(join(dir, "VERSION"), `${version} test rocx-fork-test\n`);
	copyFileSync(rocxBinary(), join(dir, "bin", "rocx"));
	spawnSync("chmod", ["+x", join(dir, "bin", "rocx")]);
	return dir;
}

/** An install root (ROCX_HOME) with `versions` installed (each `[version, folder]`, linked), the
 * first `current`. */
function installRoot(dir, versions) {
	mkdirSync(join(dir, "versions"), { recursive: true });
	for (const [version, folder] of versions) symlinkSync(folder, join(dir, "versions", version));
	symlinkSync(join("versions", versions[0][0]), join(dir, "current"));
	return dir;
}

const real = (path) => realpathSync(path);

before(() => {
	if (skip) return;
	work = realpathSync(mkdtempSync(join(tmpdir(), "rocx-install-")));
	release = makeRelease(join(work, `rocx-${VERSION}`), VERSION);
	rocx = join(release, "bin", "rocx");
});

after(() => {
	if (!work) return;
	spawnSync("chmod", ["-R", "u+w", work]);
	rmSync(work, { recursive: true, force: true });
});

test("rocx --version: an installed rocx says its VERSION; a clone, its commit", { skip }, () => {
	const installed = bare(rocx, ["--version"]);
	assert.equal(installed.code, 0, installed.said);
	assert.equal(installed.stdout.trim(), `rocx ${VERSION} test rocx-fork-test`);
	const clone = spawnSync(rocxBinary(), ["--version"], { encoding: "utf8" });
	assert.equal(clone.status, 0, clone.stderr);
	assert.match(clone.stdout, /^rocx from a clone at /);
});

test("an app outside the repo, linked to a read-only install: rocx check and rocx test, with no roc and no .tools", { skip }, () => {
	const app = makeApp(join(work, "checked"), { to: release });
	const checked = bare(rocx, ["check", "."], { cwd: app });
	assert.equal(checked.code, 0, checked.said);
	// The browser's copy names the install's web platform and package, by the link's real path.
	assert.match(readFileSync(join(app, "build", "client", "main.roc"), "utf8"), /pf: platform "[./]+rocx-2026\.11\.25\/web\/platform\/main\.roc"/);
	const tested = bare(rocx, ["test"], { cwd: app });
	assert.equal(tested.code, 0, tested.said);
	assert.match(tested.said, /All \(\d+\) tests passed/);
	// A failing expect: exit 1, said at its line.
	writeFileSync(join(app, "Greeting.roc"), readFileSync(join(app, "Greeting.roc"), "utf8").replace(`== "41"`, `== "42"`));
	const failed = bare(rocx, ["test", app]);
	assert.equal(failed.code, 1, failed.said);
	assert.match(failed.said, /Greeting\.roc/);
	// Nothing was written into the install.
	assert.equal(spawnSync("find", [release, "-newer", join(release, "VERSION"), "-type", "f"], { encoding: "utf8" }).stdout.trim(), "");
});

test("an app with no main.roc gets one that names the platform through its link", { skip }, () => {
	const app = makeApp(join(work, "no-main"), { to: release });
	rmSync(join(app, "main.roc"));
	rmSync(join(app, "Greeting.roc"));
	writeFileSync(join(app, "routes", "+page.rocx"), `import pf.Html\n\nview! = |_| <main>Hi</main>\n`);
	rmSync(join(app, "routes", "hello"), { recursive: true });
	const built = bare(rocx, ["build", ".", "--release", "dist"], { cwd: app });
	assert.equal(built.code, 0, built.said);
	assert.match(readFileSync(join(app, "main.roc"), "utf8"), /pf: platform "\.\/\.rocx\/server\/platform\/main\.roc"/);
});

test("rocx build --release: the server and what it serves, which starts and answers", { skip }, async () => {
	const app = makeApp(join(work, "released"), { to: release });
	const built = bare(rocx, ["build", ".", "--release", "dist"], { cwd: app });
	assert.equal(built.code, 0, built.said);
	assert.match(built.said, /dist\/server --static dist\/static/);
	const dist = join(app, "dist");
	assert.ok(existsSync(join(dist, "static", "rocx", "app.wasm")), "the wasm is served");
	assert.ok(existsSync(join(dist, "static", "rocx", "start.js")), "start.js is served");
	// A directory that isn't a build of rocx's is never replaced.
	mkdirSync(join(app, "kept"));
	writeFileSync(join(app, "kept", "notes.txt"), "mine");
	const refused = bare(rocx, ["build", ".", "--release", "kept"], { cwd: app });
	assert.equal(refused.code, 1, refused.said);
	assert.ok(existsSync(join(app, "kept", "notes.txt")));
	const server = spawn(join(dist, "server"), ["--port", "0", "--static", join(dist, "static")], { cwd: app, stdio: ["ignore", "ignore", "pipe"] });
	try {
		const url = await new Promise((resolve, reject) => {
			let said = "";
			server.stderr.on("data", (chunk) => {
				said += chunk;
				const found = /rocx server: (http:\/\/\S+) /.exec(said);
				if (found) resolve(found[1]);
			});
			server.on("exit", (code) => reject(new Error(`the server exited (${code}):\n${said}`)));
		});
		const page = await fetch(`${url}/`);
		assert.equal(page.status, 200);
		assert.match(await page.text(), /Hello, installed/);
		const hello = await fetch(`${url}/hello`);
		assert.equal(hello.status, 200);
		assert.match(await hello.text(), /Hello, endpoint/);
		assert.equal((await fetch(`${url}/rocx/app.wasm`)).status, 200);
	} finally {
		server.kill("SIGTERM");
	}
});

test("an app's .rocx is made, and mended when it points elsewhere or at nothing", { skip }, () => {
	const app = makeApp(join(work, "linked"), { to: null });
	const made = bare(rocx, ["routes", "."], { cwd: app });
	assert.equal(made.code, 0, made.said);
	assert.equal(real(join(app, ".rocx")), real(release));
	for (const wrong of [join(work, "nowhere"), work]) {
		rmSync(join(app, ".rocx"));
		symlinkSync(wrong, join(app, ".rocx"));
		const mended = bare(rocx, ["routes", app]);
		assert.equal(mended.code, 0, mended.said);
		assert.ok(lstatSync(join(app, ".rocx")).isSymbolicLink());
		assert.equal(real(join(app, ".rocx")), real(release), `mended from ${wrong}`);
	}
	// From a clone (no VERSION), the link is to the clone, whatever the version says.
	const clone = spawnSync(rocxBinary(), ["routes", app], { encoding: "utf8" });
	assert.equal(clone.status, 0, clone.stderr);
	assert.equal(real(join(app, ".rocx")), real(root));
});

test("an app that wants another version is run by it: installed, or installed first from ROCX_RELEASES", { skip }, async () => {
	const other = otherVersion(join(work, `rocx-${OTHER}`), OTHER);
	// Installed already: run in this one's place, which links the app to it.
	const home = installRoot(join(work, "home-installed"), [[VERSION, release], [OTHER, other]]);
	const app = makeApp(join(work, "wants-other"), { to: release, version: OTHER });
	const ran = bare(rocx, ["routes", "."], { cwd: app, env: { ROCX_HOME: home } });
	assert.equal(ran.code, 0, ran.said);
	assert.match(ran.said, /\/hello/);
	assert.equal(real(join(app, ".rocx")), real(other));
	// Not installed: its install.sh, from a releases directory, installs it; `current` stays.
	const fresh = installRoot(join(work, "home-fresh"), [[VERSION, release]]);
	const releases = makeReleases(join(work, "releases"), OTHER, other);
	const installed = bare(rocx, ["routes", app], { env: { ROCX_HOME: fresh, ROCX_RELEASES: releases } });
	assert.equal(installed.code, 0, installed.said);
	assert.match(installed.said, /install\.sh: installed rocx 2026\.11\.26/);
	assert.ok(existsSync(join(fresh, "versions", OTHER, "bin", "rocx")));
	assert.equal(readlinkSync(join(fresh, "current")), join("versions", VERSION));
	assert.equal(real(join(app, ".rocx")), real(join(fresh, "versions", OTHER)));
	// Over HTTP (curl), from a local server.
	const served = installRoot(join(work, "home-http"), [[VERSION, release]]);
	const server = createServer((request, response) => {
		const path = join(releases, decodeURIComponent(new URL(request.url, "http://x").pathname));
		if (!path.startsWith(releases) || !existsSync(path)) return response.writeHead(404).end();
		response.writeHead(200).end(readFileSync(path));
	});
	await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
	try {
		const url = `http://127.0.0.1:${server.address().port}`;
		const fetched = await bareAsync(rocx, ["routes", app], { env: { ROCX_HOME: served, ROCX_RELEASES: url } });
		assert.equal(fetched.code, 0, fetched.said);
		assert.ok(existsSync(join(served, "versions", OTHER, "bin", "rocx")));
		// A version no release has: said, exit 1.
		writeFileSync(join(app, ".rocx-version"), "2026.1.1\n");
		const missing = await bareAsync(rocx, ["routes", app], { env: { ROCX_HOME: served, ROCX_RELEASES: url } });
		assert.equal(missing.code, 1, missing.said);
		assert.match(missing.said, /download\/v2026\.1\.1\/install\.sh/);
	} finally {
		server.close();
	}
	// A version that isn't one is refused before anything is run.
	writeFileSync(join(app, ".rocx-version"), "../../etc\n");
	const refused = bare(rocx, ["routes", app], { env: { ROCX_HOME: served } });
	assert.equal(refused.code, 2, refused.said);
});

test("rocx upgrade: a version installed and made the default; an app moved onto it", { skip }, () => {
	const other = otherVersion(join(work, `upgrade-${OTHER}`), OTHER);
	const home = installRoot(join(work, "home-upgrade"), [[VERSION, release]]);
	const releases = makeReleases(join(work, "releases-upgrade"), OTHER, other);
	const app = makeApp(join(work, "upgraded"), { to: release });
	const upgraded = bare(rocx, ["upgrade"], { cwd: app, env: { ROCX_HOME: home, ROCX_RELEASES: releases } });
	assert.equal(upgraded.code, 0, upgraded.said);
	assert.equal(readlinkSync(join(home, "current")), join("versions", OTHER));
	assert.equal(readFileSync(join(app, ".rocx-version"), "utf8"), `${OTHER}\n`);
	assert.equal(real(join(app, ".rocx")), real(join(home, "versions", OTHER)));
	// Back to one installed already: no download (no ROCX_RELEASES), current moved.
	const back = bare(rocx, ["upgrade", VERSION], { cwd: app, env: { ROCX_HOME: home } });
	assert.equal(back.code, 0, back.said);
	assert.equal(readlinkSync(join(home, "current")), join("versions", VERSION));
	assert.equal(readFileSync(join(app, ".rocx-version"), "utf8"), `${VERSION}\n`);
	assert.equal(real(join(app, ".rocx")), real(release));
});

test("rocx new from an install: the template copied and filled in, its version pinned, its link made; it checks and tests with no roc on PATH", { skip }, () => {
	const made = bare(rocx, ["new", "my-shop", "--db", "sqlite"], { cwd: work });
	assert.equal(made.code, 0, made.said);
	assert.match(made.said, /Made my-shop, on rocx 2026\.11\.25 \(\.rocx-version\), on SQLite/);
	const app = join(work, "my-shop");
	assert.equal(readFileSync(join(app, ".rocx-version"), "utf8").trim(), VERSION);
	assert.equal(real(join(app, ".rocx")), real(release));
	const main = readFileSync(join(app, "main.roc"), "utf8");
	assert.match(main, /pf: platform "\.\/\.rocx\/server\/platform\/main\.roc"/);
	assert.match(main, /database: Sqlite\("data\/app\.db"\),/);
	assert.match(main, /"my_shop_session"/);
	assert.ok(existsSync(join(app, ".gitignore")), "the template's dotfiles too");
	assert.equal(spawnSync("grep", ["-rl", "{{", app, "--exclude-dir=.rocx"], { encoding: "utf8" }).stdout.trim(), "", "no placeholder left");
	const checked = bare(rocx, ["check", "."], { cwd: app });
	assert.equal(checked.code, 0, checked.said);
	const tested = bare(rocx, ["test"], { cwd: app });
	assert.equal(tested.code, 0, tested.said);
	assert.match(tested.said, /All \(\d+\) tests passed/);
	// Not into a directory with something in it.
	const again = bare(rocx, ["new", "my-shop"], { cwd: work });
	assert.equal(again.code, 1, again.said);
	assert.match(again.said, /isn't empty/);
});

test("an installed rocx refuses the commands that work on rocx itself", { skip }, () => {
	for (const args of [["self-build"], ["site", "prepare"]]) {
		const ran = bare(rocx, args);
		assert.equal(ran.code, 2, ran.said);
		assert.match(ran.said, /in a clone of its repo/);
	}
});
