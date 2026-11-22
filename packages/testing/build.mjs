// Builds a Roc Solid app for its tests, the three steps a deploy takes: `rocx build` (its
// Generated/, and the browser's copy of it), the browser's wasm, and the server, natively. The
// platforms' hosts must be built already (`just setup`, then `just test` once, builds both).
//
//   const { server, statics } = await buildForTests("examples/notes");
//   const app = await startServer(server, { statics });
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

/** The Roc Solid repository: the one this package is in, or `ROCX_ROOT`. */
export const repo = process.env.ROCX_ROOT ?? join(dirname(fileURLToPath(import.meta.url)), "..", "..");

/** The server platform's build (server/build.mjs): its Roc compiler, its target, its app build. */
export const serverBuild = () => import(pathToFileURL(join(repo, "server", "build.mjs")).href);

function run(command, args, options = {}) {
	const done = spawnSync(command, args, { encoding: "utf8", maxBuffer: 1 << 28, ...options });
	if (done.status !== 0) throw new Error(`${[command, ...args].join(" ")} failed (${done.status ?? done.signal}):\n${done.stdout}${done.stderr}`);
	return done;
}

/** `roc build` with `args`, its reports pointed into the .rocx files (`rocx check`). An error throws
 * them (Roc exits 1, though it says it built: what it wrote crashes where the error is), and so do
 * warnings alone (2), which would hide the app's own (D-044). */
function rocBuild(rocx, compiler, args) {
	const done = spawnSync(rocx, ["check", "--", compiler, "build", ...args], { encoding: "utf8", maxBuffer: 1 << 28 });
	if (done.status !== 0) throw new Error(`roc build ${args.join(" ")} failed (${done.status ?? done.signal}):\n${done.stdout}${done.stderr}`);
}

/**
 * The app in `dir` built into `out` (`<dir>/build/test`): `server`, its executable, and `statics`, the
 * directories it serves (`startServer(server, { statics })`). `client: false` skips the browser's
 * half (no wasm: pages aren't hydrated), as an app of endpoints alone has none; `dev: true` adds the stories (`rocx build --dev`), each a page
 * at `storyPath(…)`; `opt` is the server's optimization (`dev`, quick to build, or `speed`). A
 * markup problem, a type error or a warning throws, said at its line in the .rocx file.
 */
export async function buildForTests(dir, { out = join(dir, "build", "test"), client = true, dev = false, opt = "dev" } = {}) {
	const { nativeTarget, roc, rocxBinary } = await serverBuild();
	const compiler = roc();
	const rocx = rocxBinary();
	const clientDir = join(out, "client");
	run(rocx, ["build", dir, ...(client ? ["--client", clientDir] : []), ...(dev ? ["--dev"] : [])], { env: { ...process.env, ROC: compiler } });
	// An app of endpoints alone has no browser's half: rocx build wrote no main.roc for it.
	const browser = client && existsSync(join(clientDir, "main.roc"));
	if (browser) {
		const host = join(repo, "web", "platform", "targets", "wasm32", "host.wasm");
		if (!existsSync(host)) throw new Error(`the browser's host isn't built (${host}): \`just test\` builds it`);
		rocBuild(rocx, compiler, ["--target=wasm32", "--opt=size", `--output=${join(clientDir, "static", "rocx", "app.wasm")}`, join(clientDir, "main.roc")]);
	}
	const host = join(repo, "server", "platform", "targets", nativeTarget(), "libhost.a");
	if (!existsSync(host)) throw new Error(`the server's host isn't built (${host}): \`node server/build.mjs\` or \`just test\` builds it`);
	mkdirSync(out, { recursive: true });
	rocBuild(rocx, compiler, [`--target=${nativeTarget()}`, `--opt=${opt}`, `--output=${join(out, "server")}`, join(dir, "main.roc")]);
	return { server: join(out, "server"), statics: browser ? [join(clientDir, "static")] : [] };
}
