// What the browser's copy of an app (`rocx build --client`) can't compile: a module it reaches that
// imports what only the server platform has (`pf.Db`, `pf.Env`, `pf.Job`: a module the server
// platform exposes and the browser's doesn't). The browser's build would fail on it, far from the
// import that pulled it in; rocx build says where that import is instead.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";

/** The modules a platform's main.roc exposes (`exposes [Audio, Browser, …]`). */
export function exposedBy(platformMain) {
	const found = /^\s*exposes\s*\[([^\]]*)\]/m.exec(readFileSync(platformMain, "utf8"));
	return found ? found[1].split(",").map((name) => name.trim()).filter(Boolean) : [];
}

/** The modules only the server's platform has: exposed by `server`, not by `web` (main.roc paths). */
export function serverOnlyModules(server, web) {
	const browser = new Set(exposedBy(web));
	return exposedBy(server).filter((name) => !browser.has(name));
}

/**
 * A module's imports, each with its line (1-based): `{ line, written, platform }` for `import
 * pf.Db` (the platform's module), `{ line, written, path }` for a module of the app's (`import
 * ../Db/Users`: the file it names, relative to the importing file). A package's module
 * (`import charts.BarChart`) and an embedded file (`import "notes.sql" as notes : Str`) are left
 * out.
 */
export function importsOf(file, code, alias = "pf") {
	const imports = [];
	code.split("\n").forEach((text, i) => {
		const found = /^import\s+((?:\.{1,2}\/)*(?:[A-Za-z0-9_]+\/)*[A-Za-z0-9_.]+)/.exec(text);
		if (!found) return;
		const written = found[1];
		const dotted = /^([a-z_][a-z0-9_]*)\.([A-Z][A-Za-z0-9_]*)$/.exec(written);
		if (dotted) {
			if (dotted[1] === alias) imports.push({ line: i + 1, written, platform: dotted[2] });
			return;
		}
		if (/^(?:\.{1,2}\/)*(?:[A-Za-z0-9_]+\/)*[A-Z][A-Za-z0-9_]*$/.test(written)) imports.push({ line: i + 1, written, path: resolve(dirname(file), `${written}.roc`) });
	});
	return imports;
}

/**
 * Every module of the browser's copy in `target` that its `roots` (files in it: its main.roc, the
 * modules made from .rocx files) reach, and that imports a platform module in `serverOnly`: each
 * `{ module, platform, chain }`, where `chain` is the imports that reach it from a root, root first
 * (`[{ file, line, written }]`; empty when the root itself imports it). Each such module once, by
 * the shortest chain.
 */
export function serverOnlyReached(target, roots, serverOnly, alias = "pf") {
	const only = new Set(serverOnly);
	const parsed = new Map();
	const importsAt = (file) => {
		if (!parsed.has(file)) parsed.set(file, existsSync(file) ? importsOf(file, readFileSync(file, "utf8"), alias) : []);
		return parsed.get(file);
	};
	const inside = (file) => !relative(target, file).split(sep).includes("..");
	const via = new Map(roots.map((root) => [resolve(root), null]));
	const queue = [...via.keys()];
	const found = [];
	while (queue.length) {
		const file = queue.shift();
		const imports = importsAt(file);
		const platform = imports.find((each) => each.platform && only.has(each.platform));
		if (platform) {
			const chain = [];
			for (let at = via.get(file); at; at = via.get(at.file)) chain.unshift(at);
			found.push({ module: file, platform: platform.platform, line: platform.line, chain });
		}
		for (const each of imports) {
			if (!each.path || via.has(each.path) || !inside(each.path) || !existsSync(each.path)) continue;
			via.set(each.path, { file, line: each.line, written: each.written });
			queue.push(each.path);
		}
	}
	return found;
}

/** The apps in `dir` (the browser's copy) whose header names the platform at `web` (its main.roc):
 * an app of components with no routes (a test's), whose browser build is one of them. */
export function webApps(dir, web) {
	const apps = [];
	const walk = (at) => {
		for (const entry of readdirSync(at)) {
			const path = join(at, entry);
			if (statSync(path).isDirectory()) {
				if (!/^(build|dist|static|node_modules)$/.test(entry)) walk(path);
			} else if (entry.endsWith(".roc")) {
				const header = /^app\s*\[[^\]]*\]\s*\{[^}]*\bplatform\s+"([^"]+)"/m.exec(readFileSync(path, "utf8"));
				if (header && resolve(dirname(path), header[1]) === resolve(web)) apps.push(path);
			}
		}
	};
	if (existsSync(dir)) walk(dir);
	return apps.sort();
}

/** The source a file of the browser's copy was written from, relative to the app: a .rocx file's
 * (its marker line names it), or the .roc file itself, at the same place in the app. */
export function sourceOf(target, file) {
	const code = existsSync(file) ? readFileSync(file, "utf8") : "";
	const marker = /# rocx: generated from (.+?): edit that file/.exec(code.trimEnd().split("\n").pop() ?? "");
	const at = marker ? resolve(dirname(file), marker[1]) : file;
	return relative(target, at).split(sep).join("/");
}

/** A file's last line: where rocx writes its marker. */
const lastLine = (file) => (existsSync(file) ? readFileSync(file, "utf8") : "").trimEnd().split("\n").pop() ?? "";

/** Whether rocx wrote a file of the browser's copy from an author's .rocx file (a component, a
 * page): its marker names it ("generated from Echo.rocx: edit that file, not this one"). */
const fromRocx = (file) => /^# rocx: .*: edit that file/.test(lastLine(file));

/** Whether a file of the browser's copy is one the app's author wrote, or rocx wrote from one; not
 * one of rocx's own ("generated from the routes: rocx build writes it": its main.roc, Root.roc). */
const authored = (file) => !lastLine(file).startsWith("# rocx:") || fromRocx(file);

/** The warning for one module the browser's copy reaches that imports what only the server has,
 * said where browser code meets it: at the last component or page on the way (a file from a .rocx
 * file, which is the browser's for sure), or else at the first file the author wrote. `app` is the
 * app's directory, as the build names it. */
export function warning(target, app, { module, platform, line, chain }) {
	let from = -1;
	if (!fromRocx(module)) {
		from = chain.findLastIndex((step) => fromRocx(step.file));
		if (from < 0) from = chain.findIndex((step) => authored(step.file));
	}
	const steps = from < 0 ? [] : chain.slice(from);
	const where = steps.length ? steps[0] : { file: module, line };
	const imports = steps.length ? `imports ${steps.map((step) => step.written).join(", which imports ")}, which imports pf.${platform}` : `imports pf.${platform}`;
	const source = [app, sourceOf(target, where.file)].filter((part) => part && part !== ".").join("/");
	return `⚠ ${source}:${where.line}: the browser's copy ${imports}, which only the server has, so the browser's build can't compile it. Use it in an endpoint (+server.roc) or middleware, which the browser's copy leaves out.`;
}
