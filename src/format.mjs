// rocx fmt: a .rocx file's Roc formatted by `roc fmt`, its markup kept as written. Roc can't read
// markup, so each markup expression, and each <style> stylesheet, is swapped for a placeholder Roc
// formats as it would anything in its place, and put back afterwards, its later lines moved as far
// as its first line's line moved. The markup, and the Roc in its holes, stay as they are.

import { spawnSync } from "node:child_process";
import { markupSpans } from "./transpile.mjs";

/** `roc fmt` couldn't read the code: its reasons, at the file's lines. */
export class FormatError extends Error {}

/**
 * `roc fmt --stdin`: `code` formatted. When roc can't read it, a FormatError giving its reasons at
 * the file's lines (`line`: the file's line for a line of `code`, both from 1).
 */
export function rocFmt(code, { roc = "roc", file = "<stdin>", line = (n) => n } = {}) {
	const run = spawnSync(roc, ["fmt", "--stdin"], { input: code, encoding: "utf8" });
	if (run.error) throw run.error;
	if (run.status === 0) return run.stdout;
	const reasons = `${run.stdout}\n${run.stderr}`
		.split("\n")
		.map((said) => said.trim())
		.filter((said) => said && said !== "Errors:")
		.map((said) => {
			const at = /^(.*?),? at (\d+):(\d+)$/.exec(said);
			return at ? `${file}:${line(Number(at[2]))}:${at[3]}: ${at[1]}` : `${file}: ${said}`;
		});
	throw new FormatError(reasons.join("\n") || `${file}: roc fmt can't read it`);
}

/** Where each <pre> or <textarea> in some markup keeps its text: what's between its tags. */
const PREFORMATTED = /<(pre|textarea)\b[^>]*>([^]*?)<\/\1\s*>/gi;

const indentOf = (line) => /^[ \t]*/.exec(line)[0];

/**
 * `text`'s lines after its first, moved from `from` (the indent they were written against) to
 * `to`. A line with less indent than `from`, or one a <pre> or <textarea> keeps as text, stays.
 */
function moved(text, from, to) {
	if (from === to) return text.split("\n");
	// From the end of each one's opening tag to the start of its closing tag.
	const kept = [...text.matchAll(PREFORMATTED)].map((match) => [match.index + match[0].indexOf(">") + 1, match.index + match[0].lastIndexOf("</")]);
	let offset = 0;
	return text.split("\n").map((line, n) => {
		const start = offset;
		offset += line.length + 1;
		if (n === 0 || !line.startsWith(from) || kept.some(([open, close]) => open < start && start <= close)) return line;
		return to + line.slice(from.length);
	});
}

/** The markup a file's Roc holds, outermost only: markup in a hole is its markup's. */
function outermost(spans) {
	const found = [];
	for (const span of [...spans].sort((a, b) => a.from - b.from)) if (!found.length || span.from >= found.at(-1).to) found.push(span);
	return found;
}

/**
 * A .rocx file, its Roc as `roc fmt` writes it and its markup as written. Throws a RocxError for a
 * problem in its markup, and a FormatError when roc can't read its Roc.
 */
export function formatRocx(source, file = "input.rocx", { roc = "roc" } = {}) {
	let prefix = "rocx_fmt_";
	while (source.includes(prefix)) prefix += "x";
	const lineAt = (pos) => source.lastIndexOf("\n", pos - 1) + 1;
	// Each piece of markup, and how it stands in for it: `inline`, a name (on one line, or after code
	// on its line); `lines`, a `\\` string a line per line it has, so that Roc keeps it on its own
	// lines; `style`, a comment.
	const pieces = outermost(markupSpans(source, file)).map((span, i) => {
		const text = source.slice(span.from, span.to);
		const ownLine = !/\S/.test(source.slice(lineAt(span.from), span.from));
		// A stylesheet or a story stands where definitions go: a comment stands in for it.
		const kind = span.kind === "style" || span.kind === "story" ? "style" : ownLine && text.includes("\n") ? "lines" : "inline";
		return { ...span, text, kind, name: `${prefix}${i}`, indent: indentOf(source.slice(lineAt(span.from))) };
	});

	// What roc reads, and for each of its lines the file's line, for roc's reasons.
	let masked = "";
	let line = 1;
	const lines = [1];
	let at = 0;
	const copy = (text) => {
		masked += text;
		for (const c of text) if (c === "\n") lines.push(++line);
	};
	for (const piece of pieces) {
		copy(source.slice(at, piece.from));
		const written = piece.text.split("\n");
		if (piece.kind === "lines") {
			written.forEach((said, n) => {
				if (n) {
					masked += `\n${indentOf(said)}`;
					lines.push(++line);
				}
				masked += `\\\\ ${piece.name}`;
			});
			// What follows on its last line would be in the string: it goes on the next.
			const end = source.indexOf("\n", piece.to);
			if (/\S/.test(source.slice(piece.to, end < 0 ? source.length : end))) {
				masked += "\n";
				lines.push(line);
			}
		} else {
			masked += piece.kind === "style" ? `# ${piece.name}` : piece.name;
			line += written.length - 1;
		}
		at = piece.to;
	}
	copy(source.slice(at));

	let out = rocFmt(masked, { roc, file, line: (n) => lines[n - 1] ?? line });
	for (const piece of pieces) {
		const written = piece.text.split("\n");
		if (piece.kind === "lines") {
			const outLines = out.split("\n");
			const first = outLines.findIndex((said) => said.trimEnd().endsWith(`\\\\ ${piece.name}`));
			if (first < 0 || outLines.slice(first, first + written.length).some((said) => !said.trimEnd().endsWith(`\\\\ ${piece.name}`))) {
				throw new Error(`rocx fmt: lost the markup at ${file}:${source.slice(0, piece.from).split("\n").length}`);
			}
			const head = outLines[first];
			const indent = indentOf(head);
			const markup = moved(piece.text, piece.indent, indent);
			markup[0] = head.slice(0, head.lastIndexOf(`\\\\ ${piece.name}`)) + markup[0];
			// Roc puts a comma after a multi-line string on its own line; after markup, it closes it.
			const after = outLines[first + written.length];
			const comma = after !== undefined && /^\s*,\s*$/.test(after);
			if (comma) markup[markup.length - 1] += ",";
			outLines.splice(first, written.length + (comma ? 1 : 0), ...markup);
			out = outLines.join("\n");
		} else {
			const placeholder = piece.kind === "style" ? `# ${piece.name}` : piece.name;
			const found = new RegExp(`${placeholder}(?![A-Za-z0-9_])`).exec(out);
			if (!found) throw new Error(`rocx fmt: lost the markup at ${file}:${source.slice(0, piece.from).split("\n").length}`);
			const indent = indentOf(out.slice(out.lastIndexOf("\n", found.index - 1) + 1));
			out = out.slice(0, found.index) + moved(piece.text, piece.indent, indent).join("\n") + out.slice(found.index + placeholder.length);
		}
	}
	return out;
}
