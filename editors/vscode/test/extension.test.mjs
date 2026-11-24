// extension.js against a stand-in for VS Code's API (the parts it uses), with a fake rocx that
// prints what rocx dev printed, build after build, each when the test says so (a file appears).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { devFailed } from "./fixtures.mjs";

const require = createRequire(import.meta.url);
const Module = require("node:module");

// ---- The stand-in ----

class EventEmitter {
	constructor() {
		this.listeners = [];
		this.event = (listener) => {
			this.listeners.push(listener);
			return { dispose() {} };
		};
	}
	fire(value) {
		for (const listener of this.listeners) listener(value);
	}
}

class Collection {
	constructor(name) {
		this.name = name;
		this.files = new Map();
	}
	clear() {
		this.files.clear();
	}
	set(uri, diagnostics) {
		this.files.set(uri.fsPath, diagnostics);
	}
	dispose() {
		this.files.clear();
	}
}

const settings = { path: "" };
const collections = [];
let provider = null;
let workspace = null;

const vscode = {
	EventEmitter,
	Range: class {
		constructor(startLine, startColumn, endLine, endColumn) {
			Object.assign(this, { startLine, startColumn, endLine, endColumn });
		}
	},
	Diagnostic: class {
		constructor(range, message, severity) {
			Object.assign(this, { range, message, severity });
		}
	},
	DiagnosticSeverity: { Error: 0, Warning: 1 },
	Uri: { file: (fsPath) => ({ fsPath }) },
	RelativePattern: class {
		constructor(base, pattern) {
			Object.assign(this, { base, pattern });
		}
	},
	Task: class {
		constructor(definition, scope, name, source, execution) {
			Object.assign(this, { definition, scope, name, source, execution });
		}
	},
	CustomExecution: class {
		constructor(callback) {
			this.callback = callback;
		}
	},
	TaskRevealKind: { Always: 1 },
	TaskPanelKind: { Dedicated: 2 },
	languages: {
		createDiagnosticCollection: (name) => {
			const collection = new Collection(name);
			collections.push(collection);
			return collection;
		},
	},
	workspace: {
		get workspaceFolders() {
			return [workspace];
		},
		getConfiguration: () => ({ get: (key) => settings[key] }),
		// The route files under the folder, what the extension's pattern and exclusions find.
		findFiles: async (pattern, exclude) => {
			assert.match(pattern.pattern, /routes/);
			assert.match(exclude, /node_modules/);
			const found = [];
			const walk = (dir) => {
				for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
					const full = path.join(dir, entry.name);
					if (entry.isDirectory()) {
						if (!["node_modules", "Generated", "build", "dist", "target", ".git"].includes(entry.name)) walk(full);
					} else if (["+page.rocx", "+layout.rocx", "+server.roc"].includes(entry.name) && full.includes(`${path.sep}routes${path.sep}`)) {
						found.push({ fsPath: full });
					}
				}
			};
			walk(pattern.base.uri.fsPath);
			return found;
		},
	},
	tasks: {
		registerTaskProvider: (type, given) => {
			assert.equal(type, "rocx");
			provider = given;
			return { dispose() {} };
		},
	},
};

const resolve = Module._resolveFilename;
Module._resolveFilename = function (request, ...rest) {
	return request === "vscode" ? "vscode" : resolve.call(this, request, ...rest);
};
require.cache.vscode = { id: "vscode", filename: "vscode", loaded: true, exports: vscode };
const extension = require("../extension.js");
const disposables = [];
extension.activate({ subscriptions: disposables });

// ---- Helpers ----

const folderAt = (dir) => ({ uri: { fsPath: dir }, name: path.basename(dir), index: 0 });

const touch = (file, text = "") => {
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, text);
};

const until = async (what, done, ms = 20000) => {
	const started = Date.now();
	while (!done()) {
		if (Date.now() - started > ms) assert.fail(`timed out waiting for ${what}`);
		await new Promise((resolve) => setTimeout(resolve, 20));
	}
};

// Every terminal opened, closed after each test whatever happened, so no fake rocx outlives it.
const opened = [];
test.afterEach(() => {
	for (const run of opened.splice(0)) run.terminal.close();
});

// A task's terminal, opened, with what it wrote and whether it closed.
const start = async (task) => {
	const terminal = await task.execution.callback(task.definition);
	const run = { terminal, output: "", closed: null };
	terminal.onDidWrite((text) => (run.output += text));
	terminal.onDidClose((code) => {
		assert.equal(run.closed, null, "closed once");
		run.closed = code;
	});
	terminal.open();
	opened.push(run);
	return run;
};

// ---- Tests ----

test("a rocx dev task for each app in the folder: each directory with routes/ in it", async () => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rocx-vscode-"));
	touch(path.join(dir, "routes", "+server.roc"));
	touch(path.join(dir, "examples", "hello", "routes", "+page.rocx"));
	touch(path.join(dir, "examples", "hello", "routes", "about", "+page.rocx"));
	touch(path.join(dir, "site", "routes", "+layout.rocx"));
	touch(path.join(dir, "node_modules", "pkg", "routes", "+page.rocx"));
	touch(path.join(dir, "examples", "notes", "Generated", "routes", "+page.rocx"));
	workspace = folderAt(dir);
	const tasks = await provider.provideTasks();
	assert.deepEqual(
		tasks.map((task) => [task.name, task.definition.dir, task.isBackground]),
		[
			["dev .", ".", true],
			["dev examples/hello", "examples/hello", true],
			["dev site", "site", true],
		],
	);
	// A task from tasks.json, a command of one's own.
	const own = provider.resolveTask(new vscode.Task({ type: "rocx", command: "just check" }, workspace, "check", "rocx"));
	assert.equal(own.name, "check");
	assert.equal(own.isBackground, false);
	assert.equal(provider.resolveTask(new vscode.Task({ type: "rocx" }, workspace, "nothing", "rocx")), undefined);
	fs.rmSync(dir, { recursive: true });
});

test("rocx dev's problems at their .rocx lines, the last build's kept while the next one builds", async () => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rocx-vscode-"));
	const fake = path.join(dir, "fake-rocx.mjs");
	const go = (name) => touch(path.join(dir, name));
	fs.writeFileSync(
		fake,
		`#!/usr/bin/env node
import fs from "node:fs";
const say = (text) => process.stderr.write(text.endsWith("\\n") ? text : text + "\\n");
const after = async (name) => { while (!fs.existsSync(${JSON.stringify(dir)} + "/" + name)) await new Promise((r) => setTimeout(r, 20)); };
say("args: " + process.argv.slice(2).join(" "));
say(${JSON.stringify(devFailed)});
await after("go1");
say("rocx dev: routes/+page.rocx changed");
say("rocx: 1 file written");
await after("go2");
say("✗ app/routes/+page.rocx:3:5: <br> has no children or closing tag: write <br />\\n    \\t\\t<br>\\n        ^");
say("rocx dev: rocx build failed; fix it and save again");
await after("go3");
say("rocx dev: routes/+page.rocx changed");
// Half a line, then the rest: output comes in pieces, one even inside a character (✗ is three
// bytes), and a line on stdout meanwhile.
const mark = Buffer.from("── ✗ type mismatch ──── app/routes/+page.rocx:9:1\\n\\nWhy.\\n");
process.stderr.write(mark.subarray(0, 4));
await new Promise((r) => setTimeout(r, 50));
process.stdout.write("listening on :8099\\n");
process.stderr.write(mark.subarray(4));
process.stderr.write("rocx dev: built ");
await new Promise((r) => setTimeout(r, 50));
say("app in 1.2 s");
setInterval(() => {}, 1000);
`,
	);
	fs.chmodSync(fake, 0o755);
	settings.path = fake;
	workspace = folderAt(dir);
	const page = path.join(dir, "app", "routes", "+page.rocx");
	const task = provider.resolveTask(new vscode.Task({ type: "rocx", dir: "app", args: ["--port", "8099"] }, workspace, "dev app", "rocx"));
	const run = await start(task);
	const problems = () => collections.find((collection) => collection.name === "rocx: dev app").files;

	await until("the first build's problems", () => problems().get(page)?.length === 2);
	assert.match(run.output, /args: dev app --port 8099/);
	assert.match(run.output, /\r\n/);
	const [warning, error] = problems().get(page);
	assert.deepEqual([warning.severity, { ...warning.range }], [1, { startLine: 6, startColumn: 1, endLine: 6, endColumn: 7 }]);
	assert.deepEqual([error.severity, { ...error.range }], [0, { startLine: 10, startColumn: 3, endLine: 10, endColumn: 5 }]);
	assert.match(error.message, /^type mismatch\n\nThe first argument/);
	assert.equal(error.source, "rocx");

	go("go1");
	await until("the next build to start", () => run.output.includes("rocx: 1 file written"));
	await new Promise((resolve) => setTimeout(resolve, 200));
	assert.equal(problems().get(page)?.length, 2, "the last build's problems stay while it builds");

	go("go2");
	await until("the markup problem", () => problems().get(page)?.length === 1);
	assert.deepEqual({ ...problems().get(page)[0].range }, { startLine: 2, startColumn: 4, endLine: 2, endColumn: 5 });
	assert.equal(problems().get(page)[0].message, "<br> has no children or closing tag: write <br />");

	go("go3");
	await until("the last build's problem", () => problems().get(page)?.[0]?.range.startLine === 8);
	assert.equal(problems().get(page).length, 1);
	assert.equal(problems().get(page)[0].message, "type mismatch\n\nWhy.");

	run.terminal.close();
	await until("the terminal to close", () => run.closed !== null);
	assert.match(run.output, /stopped \(SIGTERM\)/);
	settings.path = "";
	fs.rmSync(dir, { recursive: true });
});

test("a command of one's own: problems as they come, kept after it ends", async () => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rocx-vscode-"));
	const report = path.join(dir, "report.txt");
	fs.writeFileSync(report, devFailed);
	workspace = folderAt(dir);
	const task = provider.resolveTask(new vscode.Task({ type: "rocx", command: `cat ${JSON.stringify(report)} >&2; exit 3` }, workspace, "check", "rocx"));
	const run = await start(task);
	await until("the command to end", () => run.closed !== null);
	assert.equal(run.closed, 3);
	const problems = collections.find((collection) => collection.name === "rocx: check").files;
	assert.equal(problems.get(path.join(dir, "app", "routes", "+page.rocx")).length, 2);
	fs.rmSync(dir, { recursive: true });
});

test("no rocx to run: said in the terminal, with what to do", async () => {
	settings.path = "/nonexistent/rocx";
	workspace = folderAt(os.tmpdir());
	const task = provider.resolveTask(new vscode.Task({ type: "rocx", dir: "app" }, workspace, "dev app", "rocx"));
	const run = await start(task);
	await until("the terminal to close", () => run.closed !== null);
	assert.match(run.output, /ENOENT[\s\S]*rocx\.path/);
	settings.path = "";
});
