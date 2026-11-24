// Roc Solid's VS Code extension. Highlighting is all package.json's (the grammar in syntaxes/);
// this is the `rocx` task type: `rocx dev <app>` and `rocx check <app>` for each app in the workspace
// (a directory with routes/ in it), or any command line (`just dev`), run in a terminal of its own whose output is
// read (reports.js) into problems at their .rocx lines, again on each build. No language server:
// what the editor shows is what the build says.
const vscode = require("vscode");
const childProcess = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { Reports } = require("./reports");

const TYPE = "rocx";
const IGNORED = "**/{node_modules,Generated,build,dist,target,.git}/**";

// One collection of problems per task, kept after its run ends (a `just check` that finished still
// shows what it found) and emptied when it runs again.
const collections = new Map();
// The runs going on, stopped with the extension: their commands run in process groups of their own.
const running = new Set();

function activate(context) {
	context.subscriptions.push(
		vscode.tasks.registerTaskProvider(TYPE, {
			provideTasks: () => provideTasks(),
			resolveTask: (task) => resolveTask(task),
		}),
		{
			dispose: () => {
				running.forEach((run) => run.stop());
				collections.forEach((collection) => collection.dispose());
			},
		},
	);
}

function deactivate() {}

// `rocx dev <dir>` and `rocx check <dir>` for each app in each workspace folder.
async function provideTasks() {
	const tasks = [];
	for (const folder of vscode.workspace.workspaceFolders ?? []) {
		const pattern = new vscode.RelativePattern(folder, "**/routes/**/{+page.rocx,+layout.rocx,+server.roc}");
		const files = await vscode.workspace.findFiles(pattern, IGNORED, 2000);
		const apps = new Set();
		for (const file of files) {
			const relative = path.relative(folder.uri.fsPath, file.fsPath).split(path.sep).join("/");
			const at = ("/" + relative).indexOf("/routes/");
			if (at >= 0) apps.add(at === 0 ? "." : relative.slice(0, at - 1));
		}
		for (const dir of [...apps].sort()) tasks.push(taskFor(folder, { type: TYPE, dir }), taskFor(folder, { type: TYPE, dir, check: true }));
	}
	return tasks;
}

// A task from tasks.json: { "type": "rocx", "dir": "…" } or { "type": "rocx", "command": "…" }.
function resolveTask(task) {
	const folder = typeof task.scope === "object" ? task.scope : vscode.workspace.workspaceFolders?.[0];
	if (!folder || (!task.definition.dir && !task.definition.command)) return undefined;
	return taskFor(folder, task.definition, task.name);
}

function taskFor(folder, definition, name) {
	const label = name ?? (definition.command ? definition.command : `${definition.check ? "check" : "dev"} ${definition.dir}`);
	const task = new vscode.Task(
		definition,
		folder,
		label,
		TYPE,
		new vscode.CustomExecution(async (resolved) => new Run(folder, resolved, label)),
	);
	task.isBackground = !definition.command && !definition.check;
	task.presentationOptions = { reveal: vscode.TaskRevealKind.Always, panel: vscode.TaskPanelKind.Dedicated, clear: true };
	return task;
}

// The rocx to run: the setting, else the workspace's bin/rocx (the rocx repository's own), else PATH's.
function rocxPath(folder) {
	const configured = vscode.workspace.getConfiguration("rocx", folder.uri).get("path");
	if (configured) return configured.replace(/^~(?=$|\/)/, os.homedir());
	const local = path.join(folder.uri.fsPath, "bin", "rocx");
	return fs.existsSync(local) ? local : "rocx";
}

// A task's terminal: runs the command, shows what it prints, and reads it into problems.
class Run {
	constructor(folder, definition, label) {
		this.folder = folder;
		this.definition = definition;
		this.label = label;
		this.written = new vscode.EventEmitter();
		this.closed = new vscode.EventEmitter();
		this.onDidWrite = this.written.event;
		this.onDidClose = this.closed.event;
		this.child = null;
		// Each stream's line so far: output comes in pieces, and the two streams' don't mix.
		this.pending = { stdout: "", stderr: "" };
		this.publishing = null;
		this.done = false;
	}

	open() {
		const cwd = this.folder.uri.fsPath;
		const key = `${cwd}\0${this.label}`;
		if (!collections.has(key)) collections.set(key, vscode.languages.createDiagnosticCollection(`rocx: ${this.label}`));
		this.problems = collections.get(key);
		this.problems.clear();
		this.reports = new Reports();
		// While rocx dev builds, the problems shown are the last build's, replaced when it ends; a
		// command's (`just check`, `rocx check`) show as they come.
		this.building = !this.definition.command && !this.definition.check;
		running.add(this);

		const env = { ...process.env, NO_COLOR: "1" };
		let shown;
		if (this.definition.command) {
			shown = this.definition.command;
			this.child = childProcess.spawn(this.definition.command, { cwd, env, shell: true, detached: true, stdio: ["ignore", "pipe", "pipe"] });
		} else {
			const rocx = rocxPath(this.folder);
			const args = [this.definition.check ? "check" : "dev", this.definition.dir, ...(this.definition.args ?? [])];
			shown = [rocx, ...args].join(" ");
			this.child = childProcess.spawn(rocx, args, { cwd, env, detached: true, stdio: ["ignore", "pipe", "pipe"] });
		}
		this.write(`> ${shown}\n\n`);
		for (const stream of ["stdout", "stderr"]) {
			// Decoded as a whole: a piece may end inside a character (`✗`, `─`).
			this.child[stream].setEncoding("utf8");
			this.child[stream].on("data", (text) => this.output(stream, text));
		}
		this.child.on("error", (error) => {
			const hint = error.code === "ENOENT" ? " (set rocx.path, or put rocx on PATH: the rocx repository's bin/)" : "";
			this.write(`\n${error.message}${hint}\n`);
			this.finish(1);
		});
		this.child.on("close", (code, signal) => {
			for (const stream of ["stdout", "stderr"]) {
				if (this.pending[stream] !== "") this.line(this.pending[stream]);
				this.pending[stream] = "";
			}
			this.reports.end();
			this.flush();
			this.write(`\n${signal ? `stopped (${signal})` : `exited with code ${code}`}\n`);
			this.finish(code ?? 0);
		});
	}

	finish(code) {
		if (this.done) return;
		this.done = true;
		running.delete(this);
		this.closed.fire(code);
	}

	close() {
		this.stop();
	}

	handleInput(data) {
		if (data === "\x03") this.stop();
	}

	stop() {
		if (!this.child || this.child.exitCode !== null || this.child.signalCode !== null) return;
		try {
			// The whole group: rocx dev's server, a shell's commands.
			process.kill(-this.child.pid, "SIGTERM");
		} catch {
			this.child.kill("SIGTERM");
		}
	}

	write(text) {
		this.written.fire(text.replace(/\r?\n/g, "\r\n"));
	}

	output(stream, text) {
		this.write(text);
		const lines = (this.pending[stream] + text).split("\n");
		this.pending[stream] = lines.pop();
		for (const line of lines) this.line(line);
	}

	line(line) {
		const { started, ended, changed } = this.reports.push(line);
		if (started) {
			this.building = true;
		} else if (ended) {
			this.building = false;
			this.flush();
		} else if (changed) {
			this.publish();
		}
	}

	// At most every 100 ms: a build's reports come in a burst.
	publish() {
		if (this.building || this.publishing) return;
		this.publishing = setTimeout(() => this.flush(), 100);
	}

	flush() {
		if (this.publishing) clearTimeout(this.publishing);
		this.publishing = null;
		const cwd = this.folder.uri.fsPath;
		const byFile = new Map();
		for (const problem of this.reports.list()) {
			const file = path.resolve(cwd, problem.file);
			const line = Math.max(0, problem.line - 1);
			const column = Math.max(0, problem.column - 1);
			const diagnostic = new vscode.Diagnostic(
				new vscode.Range(line, column, line, column + problem.width),
				problem.message,
				problem.severity === "error" ? vscode.DiagnosticSeverity.Error : vscode.DiagnosticSeverity.Warning,
			);
			diagnostic.source = "rocx";
			if (!byFile.has(file)) byFile.set(file, []);
			byFile.get(file).push(diagnostic);
		}
		this.problems.clear();
		for (const [file, diagnostics] of byFile) this.problems.set(vscode.Uri.file(file), diagnostics);
	}
}

module.exports = { activate, deactivate };
