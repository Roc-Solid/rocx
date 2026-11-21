// Points the Roc compiler's reports into .rocx files. Generated files keep the .rocx file's
// lines, so a report at `Page.roc:22:48` is about line 22 of Page.rocx; this rewrites the
// location, prints the .rocx line instead of the generated one, and moves the caret onto the
// same code there (a hole's expression is copied as written, so it can be found again).
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { MARKER } from "./transpile.mjs";

const LOCATION = /([^\s:()]+\.roc):(\d+):(\d+)/;

function generatedSource(file, cache) {
	if (!cache.has(file)) {
		let entry = null;
		const last = existsSync(file) ? readFileSync(file, "utf8").trimEnd().split("\n").pop() : "";
		// The .rocx beside it; or, for a route's module (Generated/ShowcasePage.roc), the one its last line names.
		const named = new RegExp(`^${MARKER} (\\S+\\.rocx):`).exec(last)?.[1];
		const besides = file.replace(/\.roc$/, ".rocx");
		const rocx = existsSync(besides) ? besides : named && join(dirname(file), named);
		if (last.startsWith(MARKER) && rocx && existsSync(rocx)) {
			entry = { rocx: relative(process.cwd(), rocx) || rocx, generated: readFileSync(file, "utf8").split("\n"), source: readFileSync(rocx, "utf8").split("\n") };
		}
		cache.set(file, entry);
	}
	return cache.get(file);
}

/** The column in `sourceLine` of the code under the caret in `generatedLine` (both untrimmed). */
function mapColumn(generatedLine, sourceLine, column, width) {
	const snippet = generatedLine.slice(column - 1, column - 1 + Math.max(width, 1));
	if (snippet.trim()) {
		// The k-th occurrence of the snippet in the generated line is the k-th in the source line.
		let occurrence = 0;
		for (let at = generatedLine.indexOf(snippet); at >= 0 && at < column - 1; at = generatedLine.indexOf(snippet, at + 1)) occurrence++;
		let at = -1;
		for (let k = 0; k <= occurrence; k++) {
			at = sourceLine.indexOf(snippet, at + 1);
			if (at < 0) break;
		}
		if (at >= 0) return at + 1;
	}
	return sourceLine.length - sourceLine.trimStart().length + 1;
}

/** What `rocx check` adds to the compiler's report that the builtin `Try` has no JSON encoder or
 * parser: it can't go as JSON on this Roc (an endpoint's body or answer, a
 * `Browser.call!`'s argument), and a tag union can. */
export const TRY_HINT =
	"Hint: the builtin Try can't go as JSON on this Roc (it has no encoder_for or parser_for, and nothing outside the builtins can give it one): what an endpoint or Browser.call! takes or answers can't be one, or hold one. Use a tag union instead, [Ok(a), Err(e)], which a match reads as it reads a Try.";

/** Adds TRY_HINT after each report that `Try(…)` has no `encoder_for` or `parser_for`. */
function hintTry(lines) {
	const out = [];
	let missing = false;
	for (const line of lines) {
		out.push(line);
		if (/requires the (encoder_for|parser_for) method/.test(line)) missing = true;
		else if (/^── /.test(line)) missing = false;
		else if (missing && /^\s+Try\(/.test(line)) {
			out.push("", TRY_HINT);
			missing = false;
		}
	}
	return out;
}

/** Rewrites the compiler's output; text about other files passes through unchanged. */
export function remap(output) {
	const cache = new Map();
	const lines = output.split("\n");
	const out = [];
	for (let i = 0; i < lines.length; i++) {
		const match = LOCATION.exec(lines[i]);
		const entry = match && generatedSource(match[1], cache);
		if (!entry) {
			out.push(lines[i]);
			continue;
		}
		const lineNumber = Number(match[2]);
		const generatedLine = entry.generated[lineNumber - 1] ?? "";
		const sourceLine = entry.source[lineNumber - 1] ?? "";
		const trimmedGenerated = generatedLine.trim();
		// The compiler quotes the line trimmed, then a caret line under the code it means.
		const quoted = lines.findIndex((line, j) => j > i && j < i + 12 && line.trim() === trimmedGenerated && trimmedGenerated !== "");
		let column = Number(match[3]);
		let caretWidth = 1;
		if (quoted >= 0 && /^\s*\^+\s*$/.test(lines[quoted + 1] ?? "")) {
			const caretStart = lines[quoted + 1].indexOf("^");
			caretWidth = lines[quoted + 1].trim().length;
			const indent = generatedLine.length - generatedLine.trimStart().length;
			const quotedIndent = lines[quoted].length - lines[quoted].trimStart().length;
			column = indent + (caretStart - quotedIndent) + 1;
		}
		const sourceColumn = mapColumn(generatedLine, sourceLine, column, caretWidth);
		out.push(lines[i].replace(LOCATION, `${entry.rocx}:${lineNumber}:${sourceColumn}`));
		if (quoted >= 0) {
			for (let j = i + 1; j < quoted; j++) out.push(lines[j]);
			const sourceIndent = sourceLine.length - sourceLine.trimStart().length;
			const quotedIndent = lines[quoted].length - lines[quoted].trimStart().length;
			out.push(" ".repeat(quotedIndent) + sourceLine.trim());
			const caretLine = lines[quoted + 1] ?? "";
			if (/^\s*\^+\s*$/.test(caretLine)) {
				out.push(" ".repeat(quotedIndent + Math.max(0, sourceColumn - 1 - sourceIndent)) + "^".repeat(caretWidth));
				i = quoted + 1;
			} else {
				i = quoted;
			}
		}
	}
	return hintTry(out).join("\n");
}
