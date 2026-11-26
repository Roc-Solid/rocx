// The repo's JavaScript (its tests, the site's build) calling rocx, which is Roc (rocx-cli/*.roc, built
// into bin/rocx): each function here is one of rocx's, run by `rocx internal` with its arguments as
// JSON, its answer back as JSON.
import { spawnSync } from "node:child_process";
import { rocxBinary } from "../server/build.mjs";

/** A problem in a .rocx file, at a line and column (both from 1). */
export class RocxError extends Error {
	constructor(reason, file, line, column) {
		super(`${file}:${line}:${column}: ${reason}`);
		this.reason = reason;
		this.file = file;
		this.line = line;
		this.column = column;
	}
}

/** `roc fmt` couldn't read the code: its reasons, at the file's lines. */
export class FormatError extends Error {}

/** One of rocx's functions, by name, given `args`; what it answers, or what it throws. */
export function call(fn, ...args) {
	const run = spawnSync(rocxBinary(), ["internal"], { input: JSON.stringify({ fn, args }), encoding: "utf8", maxBuffer: 1 << 30 });
	if (run.error) throw run.error;
	let answer;
	try {
		answer = JSON.parse(run.stdout);
	} catch {
		throw new Error(`rocx internal ${fn} crashed (${run.status}):\n${run.stdout}${run.stderr}`);
	}
	if ("ok" in answer) return answer.ok;
	const error = answer.error;
	if (error.kind === "RocxError") throw new RocxError(error.reason, error.file, error.line, error.column);
	if (error.kind === "FormatError") throw new FormatError(error.message);
	// Anything else an Error, with what else it says (scopeCss: the offset of the problem).
	const { kind, message, ...rest } = error;
	throw Object.assign(new Error(message), rest);
}

/** Many of rocx's functions in one process, each `[fn, ...args]`: their answers, in order (the
 * first that throws, thrown). One process instead of one each: for a script that asks many times. */
export const callMany = (calls) => call("batch", calls.map(([fn, ...args]) => ({ fn, args })));

/** A Map's entries as an object, for JSON. */
const plain = (value) => (value instanceof Map ? Object.fromEntries(value) : value);

// ---- the transpiler (Transpile.roc, Styles.roc) ----

/** The last lines of every generated file start with this; tools tell generated files by it. */
export const MARKER = "# rocx: generated from";
export const rocString = (text) => call("rocString", text);
export const transpile = (source, file = "input.rocx", options = {}) => call("transpile", source, file, options);
export const transpileModule = (source, file = "input.rocx", options = {}) => call("transpileModule", source, file, options);
export const markupSpans = (source, file = "input.rocx", options = {}) => call("markupSpans", source, file, options);
export const viewsDefined = (source) => call("viewsDefined", source);
export const contextsDefined = (source) => call("contextsDefined", source);
export const pascalCase = (name) => call("pascalCase", name);
export const scopeClass = (module) => call("scopeClass", module);
/** `css` with every selector scoped to `scope`; `fail(reason, offset)` reports a problem at an
 * offset into `css`, and must throw. */
export function scopeCss(css, scope, fail = (reason) => { throw new Error(reason); }) {
	try {
		return call("scopeCss", css, scope);
	} catch (error) {
		if (error.offset === undefined) throw error;
		return fail(error.message, error.offset);
	}
}
/** Elements that are never styled, so get no class: what goes in <head>, and the raw-text ones. */
export const UNSCOPED_ELEMENTS = new Set(["head", "meta", "title", "link", "base", "script", "style"]);

// ---- rocx check, rocx fmt (Remap.roc, Format.roc) ----

export const remap = (output) => call("remap", output);
export const formatRocx = (source, file = "input.rocx", { roc = "roc" } = {}) => call("formatRocx", source, file, { roc });
export const rocFmt = (code, { roc = "roc", file = "<stdin>" } = {}) => call("rocFmt", code, { roc, file });

// ---- stories (Stories.roc) ----

export const STORIES_PATH = "/__rocx/stories";
export const STORIES_DIR = "stories";
export const storyIds = (stories) => call("storyIds", stories);
export const storiesModule = (stories, { title = "app", root = process.cwd() } = {}) => call("storiesModule", stories, { title, root });
export const catalogHtml = (stories, { title = "app", root = process.cwd() } = {}) => call("catalogHtml", stories, { title, root });

// ---- routes (Routes.roc) ----

export const ROUTE_FILE = /^\+(page|layout|error|server)\.(rocx|roc)$/;
export const METHODS = ["get!", "post!", "put!", "patch!", "delete!", "events!"];
export const GENERATED = "Generated";
export const ROOT = "Root";
export const APP = "App";
export const findRouteFiles = (routes) => call("findRouteFiles", routes);
export const routeTable = (paths) => call("routeTable", paths);
export const definitions = (source) => call("definitions", source);
/** `definitions` of each source, in one process. */
export const definitionsOf = (sources) => callMany(sources.map((source) => ["definitions", source]));
export const tagNames = (codes) => call("tagNames", codes);
export const routeModule = (code, where) => call("routeModule", code, where);
export const hasPages = (table) => table.pages.length > 0 || Boolean(table.error);
export const viewProblems = (table, sources) => call("viewProblems", table, plain(sources));
export const metaProblems = (table, sources) => call("metaProblems", table, plain(sources));
export const middlewareProblems = (table, sources) => call("middlewareProblems", table, plain(sources));
export const routesModule = (table, { sources, stories = null }) => call("routesModule", table, { sources: plain(sources), stories });
export const apiModule = (table, { sources, client = false, tags = [], title = "app" }) => call("apiModule", table, { sources: plain(sources), client, tags, title });
export const handlersModule = (table, { sources }) => call("handlersModule", table, { sources: plain(sources) });
export const contractProblems = (table, sources) => call("contractProblems", table, plain(sources));
export const pathsModule = (table, { sources = new Map() } = {}) => call("pathsModule", table, { sources: plain(sources) });
export const rootModule = (table, { sources, stories = [], build = "0badc0de", dev = false }) => call("rootModule", table, { sources: plain(sources), stories, build, dev });
export const jobsIn = (dir, table) => call("jobsIn", dir, table);
export const actorsIn = (dir, table) => call("actorsIn", dir, table);
export const migrationsIn = (dir) => call("migrationsIn", dir);
export const appModule = ({ jobs = [], actors = [], migrations = [], endpoints = false, jobsPackage = "", middleware = null } = {}) => call("appModule", { jobs, actors, migrations, endpoints, jobsPackage, middleware });
export const clientMainModule = ({ web, packages = [], dir = "." }) => call("clientMainModule", { web, packages, dir });
export const routeList = (table, sources) => call("routeList", table, plain(sources));
export const routesTable = (dir, only = null) => call("routesTable", dir, only);
export const matches = (route, path) => call("matches", route, path);

// ---- the docs site's reference (SiteReference.roc), for its test ----

/** Every module the server platform exposes (server/platform/main.roc's `exposes`), read from its
 * source: `{ name, file, shared, doc, effects, functions }`, each item `{ name, type, doc, line }`. */
export const platformReference = () => call("platformReference");
/** The effects of `modules` with no doc comment, as `Module.name! (file:line)`. */
export const undocumented = (modules) => call("undocumented", modules);
/** A doc comment as the reference page shows it: `Para` (`inlines`), `Bullets` (`items`, each
 * inlines) and `Sample` (`code`) blocks, an inline `{ kind: "Text" | "Mono", text }`. */
export const referenceBlocks = (doc) => call("referenceBlocks", doc);

// ---- rocx build (main.roc) ----

/**
 * `rocx build`: whether every file built. Paths are relative to `cwd`; what it has to say goes to
 * `log`, a message at a time.
 */
export function build(dirs, { client, cwd = process.cwd(), log = console.error, dev = false } = {}) {
	const { ok, said } = call("build", dirs, { client: client ?? null, cwd, dev });
	for (const message of said) log(message);
	return ok;
}
