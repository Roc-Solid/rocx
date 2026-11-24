// Reads what rocx prints, line by line, into problems at file, line and column: the Roc compiler's
// reports as rocx remaps them into .rocx files (`rocx dev`, `rocx check -- …`), and rocx's own
// (`rocx build`'s markup problems, its warnings). Plain Node, no VS Code, so it is tested alone
// (test/reports.test.mjs).
//
//   ── ✗ type mismatch ─────────────────────── routes/+page.rocx:11:4      a compiler error
//   ── ● unused variable ───────────────────── routes/+page.rocx:7:2       a compiler warning
//   ✗ routes/+page.rocx:3:5: <br> has no children or closing tag           rocx's own
//   ⚠ Ui/Card.rocx:12: the browser's copy imports …                        rocx's own, no column
//
// A report's text is what follows its first line, up to the next report or a line of rocx's own;
// the quoted source line and its carets are left out (the editor shows the code), and the carets'
// width is the problem's. A line `rocx dev: … changed` starts a build: the problems before it are
// dropped (`started` in what `push` returns), and a `rocx dev: built …` or `… failed` line ends it
// (`ended`).

const ANSI = /\x1b\[[0-9;?]*[A-Za-z]/g;

// `── ✗ title ──── file:line:col`
const REPORT = /^── ([✗●⚠]) (.+?) ─+ (\S(?:.*\S)?):(\d+):(\d+)\s*$/;
// A report rocx couldn't place, or the closing count (`── 1 error and 1 warning ──── main.roc`).
const RULE = /^── /;
// A build's count, before its reports (`1 error and 1 warning found in 666ms while successfully
// building:`): the end of the report before it, the server's build's when the browser's follows.
const COUNT = /^\d+ errors? and \d+ warnings? found\b/;
// `✗ file:line:col: reason`, `✗ file:line: reason`, `✗ file: reason`
const OWN = /^([✗⚠]) (\S+?\.(?:rocx|roc|sql|md|css)):(?:(\d+):(?:(\d+):)?)? (.*)$/;
// `rocx dev: routes/+page.rocx changed`, `rocx site dev: … changed`: a build starts.
const STARTS = /^rocx(?: [a-z-]+)*: \S.* changed$/;
// The build's end: `rocx dev: built hello in 2.1 s`, `rocx dev: the server's build failed; fix it
// and save again`, `rocx dev: the server's host didn't build`; `rocx site: built in 2.1 s (…)`, the
// docs site's (`just dev`).
const ENDS = /^rocx(?: [a-z-]+)*: (?:built\b.*|.*\bfailed\b.*|.*didn't build)$/;
// Any other line of rocx's own (`rocx: 3 files written`).
const OWN_LINE = /^rocx(?: [a-z-]+)*: /;
const CARETS = /^\s*(\^+)\s*$/;

const severityOf = (mark) => (mark === "✗" ? "error" : "warning");

class Reports {
	constructor() {
		// Problems since the last build started, by key (one report said twice, by the server's
		// build and the browser's, is one problem).
		this.problems = new Map();
		this.current = null;
	}

	// One line of output. Returns { started, ended, changed }: whether a build started (the problems
	// before it dropped) or ended, and whether the problems changed.
	push(raw) {
		const line = raw.replace(ANSI, "").replace(/\r$/, "");
		let match;
		if (STARTS.test(line)) {
			this.current = null;
			const had = this.problems.size > 0;
			this.problems.clear();
			return { started: true, ended: false, changed: had };
		}
		if ((match = REPORT.exec(line))) {
			const changed = this.finish();
			this.current = {
				severity: severityOf(match[1]),
				title: match[2],
				file: match[3],
				line: Number(match[4]),
				column: Number(match[5]),
				body: [],
			};
			return { started: false, ended: false, changed };
		}
		if (RULE.test(line) || COUNT.test(line)) {
			return { started: false, ended: false, changed: this.finish() };
		}
		if ((match = OWN.exec(line))) {
			const changed = this.finish();
			this.current = {
				severity: severityOf(match[1]),
				title: match[5],
				file: match[2],
				line: match[3] ? Number(match[3]) : 1,
				column: match[4] ? Number(match[4]) : 1,
				body: [],
			};
			return { started: false, ended: false, changed };
		}
		if (ENDS.test(line)) {
			return { started: false, ended: true, changed: this.finish() };
		}
		if (OWN_LINE.test(line)) {
			return { started: false, ended: false, changed: this.finish() };
		}
		if (this.current) this.current.body.push(line);
		return { started: false, ended: false, changed: false };
	}

	// The output ended: the report being read is done.
	end() {
		return this.finish();
	}

	// The problems since the last build started.
	list() {
		return [...this.problems.values()];
	}

	finish() {
		const report = this.current;
		if (!report) return false;
		this.current = null;
		const body = [...report.body];
		let width = 1;
		const caret = body.findIndex((line) => CARETS.test(line));
		if (caret >= 0) {
			width = CARETS.exec(body[caret])[1].length;
			// The caret line, and the quoted line above it.
			body.splice(Math.max(0, caret - 1), caret > 0 ? 2 : 1);
		}
		const text = body
			.join("\n")
			.replace(/^\s*\n/, "")
			.replace(/\n{3,}/g, "\n\n")
			.trimEnd();
		const problem = {
			severity: report.severity,
			file: report.file,
			line: report.line,
			column: report.column,
			width,
			message: text === "" ? report.title : `${report.title}\n\n${text}`,
		};
		const key = `${problem.file}:${problem.line}:${problem.column}:${problem.severity}:${report.title}`;
		if (this.problems.has(key)) return false;
		this.problems.set(key, problem);
		return true;
	}
}

module.exports = { Reports };
