// Builds for the server platform: its host (server/host, Rust) into the platform's targets, and an
// app on it, as one native executable.
//
//   node server/build.mjs <app.roc> <output> [--opt=dev|speed] [--target=arm64mac|x64mac|arm64musl|x64musl]
//
// The host is built with the cargo on PATH (the system's, e.g. from Nix), or else the one `just
// setup` put in .tools/rust; Roc links the app against it (server/platform/targets/<target>/
// libhost.a). A musl target is a static Linux executable; the C runtime it links (rcrt1.o, libc.a,
// and libunwind.a, which Rust's std needs) comes from Rust's own musl target, which rustup adds,
// and Zig compiles the host's C for it.
import { spawn, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, realpathSync, renameSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const hostDir = join(root, "server", "host");
const targetsDir = join(root, "server", "platform", "targets");

/** Rust's name for each of Roc's targets. */
const RUST_TARGETS = {
	arm64mac: "aarch64-apple-darwin",
	x64mac: "x86_64-apple-darwin",
	arm64musl: "aarch64-unknown-linux-musl",
	x64musl: "x86_64-unknown-linux-musl",
};

/** The Roc target of the machine this runs on. */
export function nativeTarget() {
	const arch = process.arch === "arm64" ? "arm64" : "x64";
	return process.platform === "darwin" ? `${arch}mac` : `${arch}musl`;
}

/** The Roc compiler: the one `just setup` links in .tools (the fork rocx builds with), else $ROC. */
export function roc() {
	// The fork rocx builds with, which `just setup` builds and links (the Justfile says why), as the
	// file it links to: a new pin is a new path. Else $ROC; never the `roc` on PATH, which may lack
	// the fork's fixes.
	const active = join(root, ".tools", "roc-active");
	if (existsSync(active)) return realpathSync(active);
	if (process.env.ROC) return process.env.ROC;
	throw new Error("no Roc compiler: run `just setup` (or set ROC)");
}

let zigFound;

/** Zig, for the browser's host and the C in a musl host: the system's (`zig` on PATH, e.g. from
 * Nix) when it is the Justfile's `zig_version`, else the one `just setup` put in .tools. */
export function zig() {
	if (zigFound) return zigFound;
	const pinned = /^zig_version := "(.*)"$/m.exec(readFileSync(join(root, "Justfile"), "utf8"))?.[1];
	const system = spawnSync("zig", ["version"], { encoding: "utf8" });
	zigFound = system.status === 0 && system.stdout.trim() === pinned ? "zig" : join(root, ".tools", "zig", "zig");
	return zigFound;
}

/** Whether there is a Rust toolchain to build the host with: the system's, or the one `just setup`
 * puts in .tools. */
export function hasRust() {
	return run("cargo", ["--version"], { env: rustEnv(), check: false }).status === 0;
}

const onPath = (command) => spawnSync(command, ["--version"], { stdio: "ignore" }).status === 0;

/** cargo's environment: the system's toolchain (the cargo on PATH) if there is one, else the one in
 * .tools/rust. A musl target takes the system's only with rustup on PATH too, to add the target. */
function rustEnv({ musl = false } = {}) {
	const tools = join(root, ".tools", "rust");
	if ((onPath("cargo") && (!musl || onPath("rustup"))) || !existsSync(join(tools, "cargo", "bin", "cargo"))) return { ...process.env };
	return {
		...process.env,
		RUSTUP_HOME: join(tools, "rustup"),
		CARGO_HOME: join(tools, "cargo"),
		PATH: `${join(tools, "cargo", "bin")}:${process.env.PATH}`,
	};
}

function run(command, args, { check = true, ...options } = {}) {
	const result = spawnSync(command, args, { stdio: ["ignore", "pipe", "pipe"], encoding: "utf8", ...options });
	if (check && result.status !== 0) throw new Error(`${command} ${args.join(" ")} failed:\n${result.stdout}${result.stderr}`);
	return result;
}

function copyIfChanged(from, to) {
	if (existsSync(to)) {
		const [a, b] = [statSync(from), statSync(to)];
		if (a.size === b.size && a.mtimeMs <= b.mtimeMs) return false;
	}
	mkdirSync(dirname(to), { recursive: true });
	// Whole or not at all: another build may be linking against it right now.
	const partial = `${to}.${process.pid}.tmp`;
	copyFileSync(from, partial);
	renameSync(partial, to);
	return true;
}

/** The modules both platforms have: the browser's platform's (web/platform), copied into the server
 * platform, so the same code compiles on both. The ones components are written with (`Router`,
 * `Submission`, `Title` and `HttpStatusCode` among them), and HTTP's (`Server`, `Endpoint`, `Channel`,
 * `Middleware`, `Events`, `OpenApi`). */
export const SHARED_MODULES = ["Html", "Solid", "Show", "For", "Loading", "Errored", "Call", "Server", "Context", "Endpoint", "Middleware", "Events", "OpenApi", "Router", "HttpStatusCode", "Transition", "Browser", "Audio", "Submission", "Title", "Channel"];

/** Copies the shared modules into the server platform where they differ. */
export function syncShared() {
	for (const name of SHARED_MODULES) {
		const from = join(root, "web", "platform", `${name}.roc`);
		const to = join(root, "server", "platform", `${name}.roc`);
		const text = readFileSync(from, "utf8");
		if (!existsSync(to) || readFileSync(to, "utf8") !== text) writeFileSync(to, text);
	}
}

/** The host for `target`, built (cargo does nothing when nothing changed) and put where Roc looks. */
export function buildHost({ target = nativeTarget() } = {}) {
	syncShared();
	const triple = RUST_TARGETS[target];
	if (!triple) throw new Error(`no host for the target ${target}: one of ${Object.keys(RUST_TARGETS).join(", ")}`);
	const env = rustEnv({ musl: target.endsWith("musl") });
	if (target.endsWith("musl")) {
		// A C compiler for the guard (src/guard.c) and for crates with C in them: Zig's, for any
		// target.
		const cc = `${zig()} cc -target ${triple.replace("-unknown-", "-")}`;
		env[`CC_${triple.replaceAll("-", "_")}`] = cc;
		env[`AR_${triple.replaceAll("-", "_")}`] = `${zig()} ar`;
		// cc-rs would add clang's `--target=…`, which Zig spells `-target`, given above; without its
		// defaults, the flags are these (Zig's own default would sanitize, needing a runtime).
		env.CRATE_CC_NO_DEFAULTS = "1";
		env[`CFLAGS_${triple.replaceAll("-", "_")}`] = "-O2 -fPIC -fno-sanitize=all";
		run("rustup", ["target", "add", triple], { env });
	}
	run("cargo", ["build", "--release", "--target", triple], { cwd: hostDir, env });
	const built = join(hostDir, "target", triple, "release", "librocx_server_host.a");
	const dir = join(targetsDir, target);
	copyIfChanged(built, join(dir, "libhost.a"));
	if (target.endsWith("musl")) {
		const sysroot = run("rustc", ["--print", "sysroot"], { env }).stdout.trim();
		const crt = join(sysroot, "lib", "rustlib", triple, "lib", "self-contained");
		for (const file of ["rcrt1.o", "libunwind.a", "libc.a"]) copyIfChanged(join(crt, file), join(dir, file));
	}
}

/** The unit tests of a host module that uses only Rust's standard library (`kv.rs`), compiled on
 * their own (`rustc --test` into `out`) and run: the host's crate defines `main` for Roc, so `cargo
 * test` can't run them. Its status and what it printed. */
export function hostUnitTests(module, out) {
	const edition = /^edition = "(\d+)"/m.exec(readFileSync(join(hostDir, "Cargo.toml"), "utf8"))?.[1] ?? "2024";
	run("rustc", ["--edition", edition, "--test", join(hostDir, "src", module), "-o", out], { env: rustEnv() });
	return spawnSync(out, [], { encoding: "utf8" });
}

/** Starts a server built on the platform, with `flags`; resolves when it listens: its URL, what it
 * has logged, and how to stop it (SIGTERM; resolves to its exit code). */
export async function start(executable, flags = []) {
	const child = spawn(executable, ["--port", "0", ...flags], { stdio: ["ignore", "ignore", "pipe"] });
	let said = "";
	const url = await new Promise((resolve, reject) => {
		child.stderr.on("data", (chunk) => {
			said += chunk;
			// The whole line: the address may arrive in pieces.
			const match = /rocx server: (http:\/\/\S+) /.exec(said);
			if (match) resolve(match[1]);
		});
		child.on("exit", (code) => reject(new Error(`${executable} exited (${code}):\n${said}`)));
	});
	return {
		url,
		child,
		said: () => said,
		stop: () => new Promise((resolve) => (child.exitCode !== null ? resolve(child.exitCode) : (child.once("exit", resolve), child.kill("SIGTERM")))),
	};
}

/** `app` on the server platform, built into the executable `output`. */
export function buildApp(app, output, { target = nativeTarget(), opt = "dev" } = {}) {
	mkdirSync(dirname(output), { recursive: true });
	run(roc(), ["build", `--target=${target}`, `--opt=${opt}`, `--output=${output}`, app]);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
	const args = process.argv.slice(2);
	const option = (name, otherwise) => args.find((arg) => arg.startsWith(`--${name}=`))?.split("=")[1] ?? otherwise;
	const [app, output] = args.filter((arg) => !arg.startsWith("--"));
	if (!app || !output) {
		console.error(readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").slice(0, 8).join("\n"));
		process.exit(2);
	}
	const target = option("target", nativeTarget());
	buildHost({ target });
	buildApp(app, output, { target, opt: option("opt", "dev") });
	console.error(`built ${output} (${target})`);
}
