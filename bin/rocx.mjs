#!/usr/bin/env node
// rocx build <dir>… [--client <out>] [--dev]
//                          turn every .rocx file under the directories into the .roc beside it,
//                          and with --client write the browser's copy of the app to <out>: every
//                          module, a <NoHydration>'s children gone (and a route file without its
//                          `middleware`, the imports only those used gone)
//                          and, for an app with routes/ (+page.rocx, +layout.rocx, +error.rocx), a
//                          module for each route file and Generated/Routes.roc, Paths.roc and App.roc,
//                          its program (the jobs and actors its modules define, migrations/*.sql), which its
//                          main.roc gives what only it can say
//                          (`program = App.program({ context, middleware, crons })`);
//                          for an app with pages (every route file a component: `import pf.Html`,
//                          `view!`), Generated/Root.roc, its page; and with
//                          --client, <out>/main.roc, the browser's app, and <out>/static/rocx/start.js
//                          and runtime.js, beside which the wasm built from it goes (app.wasm, which a
//                          rebuild leaves in place until its own build replaces it): serve
//                          that directory (`--static <out>/static`);
//                          and the components of each package its headers name (a package's
//                          components/*.rocx) into Generated/<package>/, for `import charts.BarChart`;
//                          with --dev, the app's stories (`<story>` in a component's block) too: the
//                          catalog at /__rocx/stories (Generated/Stories.roc), each story in Routes,
//                          and the app's stories/ (modules of stories alone), which another build skips
// rocx check -- <command>  run a command (`roc check app/main.roc`) with its reports pointed into .rocx files
// rocx lint <dir>…         refuse Html.source_text in hand-written .roc files
// rocx routes <dir>        every route the app's routes/ has: its methods,
//                          its file, its middleware
// rocx fmt [--check] <path>…
//                          format the .rocx files, and the hand-written .roc files, under each directory
//                          (or each file named) with `roc fmt` ($ROC, or roc on the PATH), a .rocx
//                          file's markup kept as written; with --check, only say which aren't formatted
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { FormatError, formatRocx, rocFmt } from "../src/format.mjs";
import { remap } from "../src/remap.mjs";
import { STORIES_DIR, storiesModule, storyIds } from "../src/stories.mjs";
import { actorsIn, APP, apiModule, appModule, clientMainModule, definitions, findRouteFiles, GENERATED, hasPages, jobsIn, METHODS, migrationsIn, pathsModule, ROOT, rootModule, ROUTE_FILE, routeModule, routesModule, routesTable, routeTable, tagNames, viewProblems } from "../src/routes.mjs";
import { contextsDefined, MARKER, pascalCase, RocxError, rocString, transpileModule, viewsDefined } from "../src/transpile.mjs";

/** Where rocx is: the browser's platform (web/platform) and what a page loads (web/start.js, web/runtime.js) are beside it. */
const ROCX = join(dirname(fileURLToPath(import.meta.url)), "..");

function* files(dir, extension, skip = () => false) {
	for (const entry of readdirSync(dir)) {
		if (entry.startsWith(".") || entry === "node_modules") continue;
		const path = join(dir, entry);
		if (statSync(path).isDirectory()) {
			if (!skip(path)) yield* files(path, extension, skip);
		} else if (path.endsWith(extension)) yield path;
	}
}

/** Writes `content` to `path` unless it is there already: a watcher that sees the file would rebuild again. */
function write(path, content) {
	if (existsSync(path) && readFileSync(path, "utf8") === content) return false;
	mkdirSync(dirname(path), { recursive: true });
	writeFileSync(path, content);
	return true;
}

/**
 * Generated/Styles.roc: every <style>, scoped to the markup it styles (a component's, or a file's),
 * as one stylesheet, which the root layout puts in its <head>. `styles`: `{ file, line, component, css }`.
 */
function stylesModule(styles) {
	const css = [...styles]
		.sort((a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1 : a.line - b.line))
		.map(({ file, component, css }) => `/* ${file}${component ? `, ${component}` : ""} */\n${css}`)
		.join("\n\n");
	return [
		"## Every <style> in the app's .rocx files, scoped to the markup it styles (a component's, or at a",
		"## file's top level the file's), as one stylesheet, which the root layout puts in its <head>:",
		"## `{=Styles.style}`. Written by rocx build: edit the <style>s.",
		"import pf.Html",
		"",
		"Styles := [].{",
		"\t## The stylesheet's text.",
		"\tcss : Str",
		css ? `\tcss = Str.join_with([\n${css.split("\n").map((line) => `\t\t${rocString(line)},`).join("\n")}\n\t], "\\n")` : '\tcss = ""',
		"",
		"\t## The stylesheet, as a <style> element; nothing when no file has a <style>.",
		"\tstyle : Html",
		`\tstyle = ${css ? 'Html.element("style", [], [Html.source_text(css)])' : "Html.empty({})"}`,
		"}",
		"",
		`${MARKER} every .rocx file's <style>: rocx build writes it.`,
		"",
	].join("\n");
}

/** Relative paths in an app's, a package's or a platform's header, made relative to `to` instead of `from`. */
function moveHeader(code, from, to) {
	const start = code.search(/^(app|package|platform)\b/m);
	if (start < 0) return code;
	const open = code.indexOf("{", start);
	let end = open;
	for (let depth = 0; end < code.length; end++) {
		if (code[end] === "{") depth++;
		else if (code[end] === "}" && --depth === 0) break;
	}
	const header = code.slice(start, end).replace(/"(\.{1,2}\/[^"]*)"/g, (_, path) => {
		const moved = relative(dirname(to), resolve(dirname(from), path)).split(sep).join("/");
		return JSON.stringify(moved.startsWith(".") ? moved : `./${moved}`);
	});
	return code.slice(0, start) + header + code.slice(end);
}

/**
 * The browser's copy of the app under `dir`, in `out`: every .roc file, at the same place, but a
 * `<NoHydration>` has no children and a route file no middleware, so what only the server runs is
 * never compiled for the browser. `client` holds the browser's code for each .rocx file.
 * Build output (`build/`, `dist/`) stays out.
 */
function writeClient(dir, out, client, { main = null } = {}) {
	const root = resolve(dir);
	const target = resolve(out);
	if (target === root || relative(target, root).split(sep)[0] !== "..") throw new Error(`--client ${out}: it would hold ${dir} itself`);
	const ours = join(target, ".rocx-client");
	if (existsSync(target) && !existsSync(ours)) throw new Error(`--client ${out}: it exists and rocx didn't write it`);
	// What rocx wrote before goes, but the wasm built from it stays (`static/rocx/*.wasm`): rocx doesn't
	// build it, so a server serving the app goes on serving pages that hydrate until the wasm's own
	// build replaces it.
	clear(target, (path) => dirname(path) === join("static", "rocx") && path.endsWith(".wasm"));
	const skip = (path) => resolve(path) === target || /^(build|dist)$/.test(path.split(sep).pop());
	for (const path of files(dir, ".roc", skip)) {
		const to = join(target, relative(dir, path));
		const code = client.get(path.replace(/\.roc$/, ".rocx")) ?? readFileSync(path, "utf8");
		write(to, moveHeader(code, path, to));
	}
	// An app of component pages: the browser's app (main.roc, its root the app's page), and what a page
	// loads beside the wasm built from it (`static/rocx/`, served at /rocx/: start.js, runtime.js and
	// app.wasm, side by side).
	if (main) {
		write(join(target, "main.roc"), main(target));
		for (const name of ["start.js", "runtime.js"]) write(join(target, "static", "rocx", name), readFileSync(join(ROCX, "web", name), "utf8"));
	}
	writeFileSync(ours, "The browser's copy of an app, written by rocx build --client: don't edit.\n");
}

/** Empties `dir` but for the files `keep` says to keep (by their path inside it), which stay where
 * they are; a directory left empty goes. */
function clear(dir, keep, inside = "") {
	if (!existsSync(dir)) return;
	for (const entry of readdirSync(dir, { withFileTypes: true })) {
		const path = join(dir, entry.name);
		const named = inside ? join(inside, entry.name) : entry.name;
		if (entry.isDirectory()) {
			clear(path, keep, named);
			if (readdirSync(path).length === 0) rmSync(path, { recursive: true, force: true });
		} else if (!keep(named)) rmSync(path, { force: true });
	}
}

/** A path as Roc resolves it, through symbolic links (`/tmp` is `/private/tmp` on macOS): its
 * nearest directory that is there, resolved, and the rest as it is. */
function real(path) {
	let at = path;
	const rest = [];
	while (!existsSync(at) && dirname(at) !== at) {
		rest.unshift(basename(at));
		at = dirname(at);
	}
	return join(existsSync(at) ? realpathSync(at) : at, ...rest);
}

/**
 * The packages the app's server half names in its header (main.roc's, or another `app [program]`'s),
 * besides its platform (`charts: "../packages/charts/main.roc"`), each as the browser's app at `out`
 * names it.
 */
function headerPackages(dir, out) {
	const named = existsSync(join(dir, "main.roc")) ? ["main.roc"] : readdirSync(dir).filter((entry) => entry.endsWith(".roc"));
	for (const entry of named) {
		const header = /^app\s*\[\s*program\s*\]\s*\{([^}]*)\}/m.exec(readFileSync(join(dir, entry), "utf8"))?.[1];
		if (header === undefined) continue;
		return [...header.matchAll(/([a-z_][a-z0-9_]*)\s*:\s*(platform\s+)?"([^"]+)"/g)]
			.filter(([, , platform]) => !platform)
			.map(([, name, , path]) => {
				if (!/^\.{1,2}\//.test(path)) return `${name}: ${JSON.stringify(path)}`;
				const moved = relative(real(out), real(resolve(dir, path))).split(sep).join("/");
				return `${name}: ${JSON.stringify(moved.startsWith(".") ? moved : `./${moved}`)}`;
			});
	}
	return [];
}

/** Whether rocx wrote `path`: its last line is the marker (a file that only mentions it, in a string, isn't). */
const isGenerated = (path) => readFileSync(path, "utf8").trimEnd().split("\n").pop().startsWith(MARKER);

/**
 * The Roc an app is written in besides its .rocx files: its own .roc files (not rocx's, nor its
 * build output), and the packages' and platforms' its headers name (`"../packages/charts/main.roc"`). Where a
 * type an endpoint is sent or answers comes from, so its tags are among their names (`tagNames`).
 */
function rocCode(dir) {
	const skip = (path) => /^(build|dist|Generated)$/.test(path.split(sep).pop());
	const codes = [];
	const dirs = new Set();
	for (const path of files(dir, ".roc", skip)) {
		const code = readFileSync(path, "utf8");
		if (code.trimEnd().split("\n").pop().startsWith(MARKER) || ROUTE_FILE.test(basename(path))) continue;
		codes.push(code);
		const header = /^app\s*\[[^\]]*\]\s*\{([^}]*)\}/m.exec(code)?.[1] ?? "";
		for (const [, named] of header.matchAll(/"(\.{1,2}\/[^"]+)"/g)) dirs.add(dirname(resolve(dirname(path), named)));
	}
	for (const named of dirs) {
		if (named === dir || relative(dir, named).split(sep)[0] !== ".." || !existsSync(named)) continue;
		for (const path of files(named, ".roc", skip)) codes.push(readFileSync(path, "utf8"));
	}
	return codes;
}

/**
 * The packages an app's headers name that have components (`components/*.rocx`), such as
 * packages/charts: each as the header names it (`charts`), as its components import it (`own`, its
 * directory's name), and its components. A Roc package can't import a platform both of an app's
 * halves have, so `rocx build` copies these into the app (`Generated/charts/BarChart.roc`), where
 * `pf` is whichever platform each half is on.
 */
function componentPackages(dir) {
	const found = new Map();
	for (const entry of readdirSync(dir)) {
		if (!entry.endsWith(".roc") || statSync(join(dir, entry)).isDirectory()) continue;
		const header = /^app\s*\[[^\]]*\]\s*\{([^}]*)\}/m.exec(readFileSync(join(dir, entry), "utf8"))?.[1] ?? "";
		for (const [, name, named] of header.matchAll(/([a-z_][a-z0-9_]*)\s*:\s*"(\.{1,2}\/[^"]+)"/g)) {
			const root = dirname(resolve(dir, named));
			const components = join(root, "components");
			if (found.has(name) || !existsSync(components)) continue;
			const paths = [...files(components, ".rocx")];
			found.set(name, { name, own: basename(root), paths, modules: new Set(paths.map((path) => basename(path, ".rocx"))) });
		}
	}
	return [...found.values()];
}

/**
 * `import charts.BarChart`, a package's component, as an import of the app's copy of it
 * (`import ../Generated/charts/BarChart`), relative to the file at `path`: a line for a line.
 */
function linkComponents(source, path, dir, packages) {
	if (!packages.length) return source;
	return source.replace(/^import\s+([a-z_][a-z0-9_]*)\.([A-Z][A-Za-z0-9]*)\b/gm, (line, name, module) => {
		if (!packages.some((pkg) => pkg.name === name && pkg.modules.has(module))) return line;
		return `import ${relative(dirname(path), join(dir, GENERATED, name, module)).split(sep).join("/")}`;
	});
}

/**
 * `rocx build`: whether every file built. Paths are relative to `cwd`; what it has to say goes to
 * `log` (the site's build runs it in its own process, and shows it only when something failed).
 */
export function build(dirs, { client, cwd = process.cwd(), log = console.error, dev = false } = {}) {
	if (client && dirs.length > 1) throw new Error("rocx build --client: one directory, the app's");
	let failed = false;
	let written = 0;
	// Every .rocx file is components (Solid-style, its holes computations and its handlers effects),
	// written with the platform's Html (`import pf.Html`): a route file's markup too, a page, layout
	// or error page.
	for (const given of dirs) {
		const dir = resolve(cwd, given);
		const browser = new Map();
		// The app's Roc, as rocx writes it from each .rocx file, for the names that could be tags.
		const codes = [];
		// Each <style>, a component's or a file's, scoped to its markup, for the app's stylesheet (Generated/Styles.roc).
		const styles = [];
		// Each story (`<story>` in a component's block), for a dev build's catalog (`--dev`).
		const stories = [];
		// The contexts the directory's modules define, for the providers' tags in the others (`<PicksContext>`).
		const contexts = {};
		// The components of the packages the app's headers name (`charts: "../packages/charts/main.roc"`).
		const packages = componentPackages(dir);
		// How each component is called (`view!`, put off; `view`, pure, called where it is written), for
		// the tags in the others (`<Heading>`). A name some module defines with `view!` stays `view!`.
		const views = {};
		const viewsOf = (source) => {
			for (const [name, kind] of Object.entries(viewsDefined(source))) views[name] = views[name] === "view!" ? "view!" : kind;
		};
		// Build output (`build/`, `dist/`) isn't the app's: a copy of it, or what a build writes there.
		const output = (path) => /^(build|dist)$/.test(path.split(sep).pop());
		for (const path of [...files(dir, ".rocx", output), ...packages.flatMap((pkg) => pkg.paths)]) {
			const module = relative(dir, path).replace(/\.rocx$/, "").split(sep).pop();
			const source = readFileSync(path, "utf8");
			for (const { name, shared } of contextsDefined(source)) if (shared) contexts[pascalCase(name)] = `${module}.${name}`;
			viewsOf(source);
		}
		for (const path of files(dir, ".roc", (path) => /^(build|dist|Generated)$/.test(path.split(sep).pop()))) {
			if (!existsSync(`${path}x`) && !isGenerated(path)) viewsOf(readFileSync(path, "utf8"));
		}
		// Route files (`routes/blog/[slug]/+page.rocx`) are modules rocx writes under Generated/.
		const routes = join(dir, "routes");
		const routeFiles = findRouteFiles(routes);
		const isRoute = (path) => ROUTE_FILE.test(path.split(sep).pop()) && relative(routes, path).split(sep)[0] !== "..";
		let table = null;
		try {
			table = routeTable(routeFiles);
		} catch (error) {
			log(`✗ ${relative(cwd, dir) || "."}/${error.message}`);
			failed = true;
			continue;
		}
		const routed = new Map([...table.pages, ...table.servers, ...table.layouts, ...(table.error ? [table.error] : [])].map((entry) => [join(routes, ...entry.file.split("/")), entry]));
		const routeOutputs = new Set();
		// Each route file (`+page.rocx`, or `+server.roc`, plain Roc) as a module under Generated/.
		for (const [path, entry] of routed) {
			const out = join(dir, GENERATED, `${entry.module}.roc`);
			routeOutputs.add(out);
			if (existsSync(out) && !isGenerated(out)) {
				log(`✗ ${relative(cwd, path)}: ${relative(cwd, out)} exists and was not written by rocx; rename one of them`);
				failed = true;
				continue;
			}
			try {
				const source = linkComponents(readFileSync(path, "utf8"), path, dir, packages);
				const file = relative(cwd, path);
				const module = `${GENERATED}/${entry.module}`;
				const where = { name: entry.module, source: path, generated: out };
				const { code, styles: styled } = transpileModule(source, file, { module, contexts, views });
				codes.push(code);
				styles.push(...styled.map((style) => ({ file: relative(dir, path).split(sep).join("/"), ...style })));
				// The browser's copy: no middleware, no <NoHydration>'s children, and the imports only they used gone.
				if (client) browser.set(out.replace(/\.roc$/, ".rocx"), routeModule(transpileModule(source, file, { module, client: true, route: true, contexts, views }).code, where));
				if (write(out, routeModule(code, where))) written++;
			} catch (error) {
				if (error instanceof RocxError) {
					const line = readFileSync(path, "utf8").split("\n")[error.line - 1] ?? "";
					log(`✗ ${error.message}\n    ${line}\n    ${" ".repeat(error.column - 1)}^`);
				} else log(`✗ ${error.message}`);
				failed = true;
			}
		}
		// An app's stories/ holds stories alone (drafts beside one another): only a dev build has it.
		const storiesOnly = (path) => relative(dir, path).split(sep)[0] === STORIES_DIR;
		for (const path of files(dir, ".rocx", output)) {
			if (isRoute(path)) continue;
			if (storiesOnly(path) && !dev) continue;
			const out = path.replace(/\.rocx$/, ".roc");
			if (existsSync(out) && !isGenerated(out)) {
				log(`✗ ${relative(cwd, path)}: ${relative(cwd, out)} exists and was not written by rocx; rename one of them`);
				failed = true;
				continue;
			}
			try {
				const source = linkComponents(readFileSync(path, "utf8"), path, dir, packages);
				const file = relative(cwd, path);
				const module = relative(dir, path).replace(/\.rocx$/, "").split(sep).join("/");
				const { code, regions, styles: styled, stories: told } = transpileModule(source, file, { module, contexts, views });
				codes.push(code);
				styles.push(...styled.map((style) => ({ file: relative(dir, path).split(sep).join("/"), ...style })));
				stories.push(...told.map((story) => ({ file: relative(dir, path).split(sep).join("/"), module, ...story })));
				if (client) browser.set(path, regions ? transpileModule(source, file, { module, client: true, contexts, views }).code : code);
				if (write(out, code)) written++;
			} catch (error) {
				if (!(error instanceof RocxError)) throw error;
				const line = readFileSync(path, "utf8").split("\n")[error.line - 1] ?? "";
				log(`✗ ${error.message}\n    ${line}\n    ${" ".repeat(error.column - 1)}^`);
				failed = true;
			}
		}
		// Each package's components, copied into the app (`Generated/charts/BarChart.roc`): imported
		// by the name the app's header gives the package, its <style> in the app's stylesheet, and
		// the compiler's reports pointed at the package's file.
		for (const pkg of packages) {
			for (const path of pkg.paths) {
				const name = basename(path, ".rocx");
				const out = join(dir, GENERATED, pkg.name, `${name}.roc`);
				routeOutputs.add(out);
				if (existsSync(out) && !isGenerated(out)) {
					log(`✗ ${relative(cwd, out)} exists and was not written by rocx; rename it`);
					failed = true;
					continue;
				}
				try {
					let source = readFileSync(path, "utf8");
					// Its own package, which it imports by the package's directory's name, as the app names it.
					if (pkg.own !== pkg.name) source = source.replace(new RegExp(`^import\\s+${pkg.own}\\.`, "gm"), `import ${pkg.name}.`);
					const { code, styles: styled } = transpileModule(source, relative(cwd, path), { module: `${GENERATED}/${pkg.name}/${name}`, contexts, views });
					codes.push(code);
					styles.push(...styled.map((style) => ({ file: relative(dir, path).split(sep).join("/"), ...style })));
					const from = relative(dirname(out), path).split(sep).join("/");
					if (write(out, code.replace(/\n# rocx: generated from [^\n]*\n?$/, `\n${MARKER} ${from}: edit that file, not this one. Line N here is line N there.\n`))) written++;
				} catch (error) {
					if (!(error instanceof RocxError)) throw error;
					const line = readFileSync(path, "utf8").split("\n")[error.line - 1] ?? "";
					log(`✗ ${error.message}\n    ${line}\n    ${" ".repeat(error.column - 1)}^`);
					failed = true;
				}
			}
		}
		if (failed) continue;
		// The browser's app, for an app of component pages (`--client`): written with its copy.
		let main = null;
		// The routes: which page or endpoint a request is for, every page's path, every endpoint.
		if (routeFiles.length) {
			const sources = new Map(
				[...routed.values()].map((entry) => {
					const source = readFileSync(join(routes, ...entry.file.split("/")), "utf8");
					return [entry.file, definitions(source)];
				}),
			);
			for (const server of table.servers) {
				const defined = sources.get(server.file);
				const file = relative(cwd, join(routes, ...server.file.split("/")));
				if (defined.hooks) {
					log(`✗ ${file}: ${defined.hooks.join(", ")} ${defined.hooks.length === 1 ? "is a channel's hook" : "are a channel's hooks"}, and it defines no channel: define channel!, its check`);
					failed = true;
				}
				if (defined.methods.length || defined.respond || defined.channel || defined.hooks) continue;
				log(`✗ ${file}: a +server answers methods: define one of ${METHODS.join(", ")}, or respond!, or a channel (channel!)`);
				failed = true;
			}
			for (const problem of viewProblems(table, sources)) {
				log(`✗ ${relative(cwd, dir) || "."}/${problem}`);
				failed = true;
			}
			// Any app with routes: its program (`App`), with the jobs and kinds of actor its modules define (an app of
			// endpoints alone too); an app with pages: its page (`Root`).
			const pages = hasPages(table);
			const { jobs, problems: jobProblems } = jobsIn(dir, table);
			const { actors, problems: actorProblems } = actorsIn(dir, table);
			for (const problem of [...jobProblems, ...actorProblems]) {
				log(`✗ ${relative(cwd, dir) || "."}/${problem}`);
				failed = true;
			}
			if (failed) continue;
			// A dev build's stories, each at its id; only a dev build has them.
			let placed = null;
			if (dev) {
				try {
					placed = storyIds(stories);
				} catch (error) {
					log(`✗ ${error.message}`);
					failed = true;
					continue;
				}
				// A story is the app's page (Root renders it): an app with no pages has nowhere to show one.
				for (const story of pages ? [] : placed) {
					log(`✗ ${relative(cwd, join(dir, story.file))}:${story.line}: the story "${story.name}" is shown as the app's page, and the app has none: give it routes/ with a +page.rocx`);
					failed = true;
				}
				if (failed) continue;
			}
			const generated = [
				["Routes", routesModule(table, { sources, stories: placed })],
				...(placed ? [["Stories", storiesModule(placed, { title: basename(dir), root: dir })]] : []),
				["Paths", pathsModule(table)],
				["Styles", stylesModule(styles)],
				...(table.servers.length ? [["Api", apiModule(table, { sources, tags: tagNames([...codes, ...rocCode(dir)]), title: basename(dir) })]] : []),
				...(pages ? [[ROOT, rootModule(table, { sources, stories: placed ?? [] })]] : []),
				[APP, appModule({ jobs, actors, migrations: migrationsIn(dir), endpoints: table.servers.length > 0 })],
			];
			if (pages && client) {
				const web = (out) => {
					const path = relative(real(out), real(join(ROCX, "web", "platform", "main.roc"))).split(sep).join("/");
					return path.startsWith(".") ? path : `./${path}`;
				};
				main = (out) => clientMainModule({ web: web(out), packages: headerPackages(dir, out), dir: relative(cwd, dir) || "." });
			}
			if (table.servers.length && client) browser.set(join(dir, GENERATED, "Api.rocx"), apiModule(table, { sources, client: true }));
			for (const [name, content] of generated) {
				const out = join(dir, GENERATED, `${name}.roc`);
				routeOutputs.add(out);
				if (existsSync(out) && !isGenerated(out)) {
					log(`✗ ${relative(cwd, out)} exists and was not written by rocx; rename it`);
					failed = true;
				} else if (write(out, content)) written++;
			}
		}
		if (!routeFiles.length && styles.length) log(`rocx: ${relative(cwd, dir) || "."} has <style>s (${[...new Set(styles.map((style) => style.file))].join(", ")}) but no routes/, so no layout to put them in`);
		// A .roc file rocx wrote for a .rocx file that is gone is stale, and so is a route's that is gone.
		// (A route file's .roc beside it, from a rocx before routes, is stale too: its module is under Generated/.)
		// So is a story module's, but in a dev build; and Generated/ServerFunctions.roc, from a rocx
		// with server functions (D-023).
		for (const path of files(dir, ".roc")) {
			const stale = !existsSync(path.replace(/\.roc$/, ".rocx")) || isRoute(path.replace(/\.roc$/, ".rocx")) || (storiesOnly(path) && !dev);
			if (!routeOutputs.has(path) && stale && isGenerated(path)) unlinkSync(path);
		}
		if (client) writeClient(dir, resolve(cwd, client), browser, { main });
	}
	if (written) log(`rocx: ${written} file${written === 1 ? "" : "s"} written`);
	return !failed;
}

/** `rocx routes <dir>`: every route the app's routes/ has: the methods each answers, and the middleware each file names. */
function routes(dir) {
	console.log(routesTable(resolve(dir)));
}

function check(command) {
	if (!command.length) {
		console.error("usage: rocx check -- <command> [args…]");
		process.exit(2);
	}
	const run = spawnSync(command[0], command.slice(1), { encoding: "utf8", env: { ...process.env, NO_COLOR: "1" } });
	if (run.error) throw run.error;
	const output = remap(`${run.stdout}${run.stderr}`);
	process.stdout.write(output.endsWith("\n") || !output ? output : `${output}\n`);
	process.exit(run.status ?? 1);
}

function lint(dirs) {
	let failed = false;
	for (const dir of dirs) {
		for (const path of files(dir, ".roc")) {
			if (isGenerated(path)) continue;
			readFileSync(path, "utf8").split("\n").forEach((line, i) => {
				// A call, not a mention: comments, `\\` lines and string literals don't count.
				const code = line.trimStart().startsWith("\\\\") ? "" : line.replace(/"(?:[^"\\]|\\.)*"/g, '""').replace(/#.*/, "");
				if (/\bHtml\.source_text\b/.test(code)) {
					console.error(`✗ ${path}:${i + 1}: Html.source_text puts text in a page as markup; only rocx may write it`);
					failed = true;
				}
			});
		}
	}
	process.exit(failed ? 1 : 0);
}

/**
 * `rocx fmt`: each .rocx file, and each .roc file but rocx's (generated, or under build/, dist/ or
 * Generated/), under the directories or named, through `roc fmt`; a .rocx file's markup as written.
 * Its `roc` is $ROC, else the `roc` on PATH: right for an app outside this repo (in it, `just` sets ROC).
 */
function fmt(paths, { check = false, roc = process.env.ROC ?? "roc" } = {}) {
	const skip = (path) => /^(build|dist|Generated)$/.test(path.split(sep).pop());
	let failed = false;
	for (const given of paths) {
		const named = statSync(given).isDirectory() ? [...files(given, ".rocx", skip), ...files(given, ".roc", skip)] : [given];
		for (const path of named) {
			if (path.endsWith(".roc") && isGenerated(path)) continue;
			const source = readFileSync(path, "utf8");
			let formatted;
			try {
				formatted = path.endsWith(".rocx") ? formatRocx(source, path, { roc }) : rocFmt(source, { roc, file: path });
			} catch (error) {
				if (error.code === "ENOENT") {
					console.error(`✗ rocx fmt runs roc fmt, and there is no ${roc}: put roc on the PATH, or set ROC`);
					process.exit(2);
				}
				if (!(error instanceof RocxError || error instanceof FormatError)) throw error;
				console.error(`✗ ${error.message}`);
				failed = true;
				continue;
			}
			if (formatted === source) continue;
			if (check) {
				console.error(`✗ ${path}: not formatted (rocx fmt formats it)`);
				failed = true;
			} else {
				writeFileSync(path, formatted);
				console.log(`formatted ${path}`);
			}
		}
	}
	process.exit(failed ? 1 : 0);
}

// Run as a command, not imported (the site's build imports `build`).
if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
	const [command, ...args] = process.argv.slice(2);
	const rest = args;
	const dev = rest.includes("--dev");
	const clientAt = rest.indexOf("--client");
	const dirs = rest.filter((arg, i) => arg !== "--dev" && (clientAt < 0 || (i !== clientAt && i !== clientAt + 1)));
	if (command === "build" && clientAt >= 0 && rest[clientAt + 1] && dirs.length > 1) {
		console.error("rocx build --client: one directory, the app's");
		process.exit(2);
	} else if (command === "build" && dirs.length && (clientAt < 0 || rest[clientAt + 1])) {
		process.exit(build(dirs, { client: clientAt >= 0 ? rest[clientAt + 1] : undefined, dev }) ? 0 : 1);
	} else if (command === "check") check(args[0] === "--" ? args.slice(1) : args);
	else if (command === "lint" && args.length) lint(args);
	else if (command === "routes" && args.length === 1) routes(args[0]);
	else if (command === "fmt" && args.some((arg) => arg !== "--check")) fmt(args.filter((arg) => arg !== "--check"), { check: args.includes("--check") });
	else {
		console.error("usage: rocx build <dir>… [--client <out>] [--dev] | rocx check -- <command>… | rocx lint <dir>… | rocx routes <dir> | rocx fmt [--check] <path>…");
		process.exit(2);
	}
}
