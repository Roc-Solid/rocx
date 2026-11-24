// `just grammar-check`: tokenizes .rocx files with the editor grammar (editors/orca/syntaxes) by VS
// Code's TextMate engine, and fails on any whose markup is still open at its end, which is what a
// wrong guess about `<` (markup or less-than) leaves behind.
//
// usage: node editors/check-grammar.cjs <node_modules> <syntaxes> [--dump <file>:<from>-<to>] <file>…
// `--dump` prints the scopes of those lines of that file (a suffix of its path), to see what the
// grammar made of them.
const path = require("path");
const fs = require("fs");

const [modulesArg, syntaxesArg, ...rest] = process.argv.slice(2);
const modules = path.resolve(modulesArg);
const syntaxes = path.resolve(syntaxesArg);
const textmate = require(path.join(modules, "vscode-textmate"));
const oniguruma = require(path.join(modules, "vscode-oniguruma"));

const grammars = {
	"source.rocx": "rocx.tmLanguage.json",
	"source.roc": "roc.tmLanguage.json",
	"source.css": "css.tmLanguage.json",
};

let dump = null;
const files = [];
for (let i = 0; i < rest.length; i++) {
	if (rest[i] === "--dump") {
		const [file, range] = rest[++i].split(":");
		const [from, to] = range.split("-").map(Number);
		dump = { file, from, to };
	} else {
		files.push(rest[i]);
	}
}

const main = async () => {
	await oniguruma.loadWASM(fs.readFileSync(path.join(modules, "vscode-oniguruma/release/onig.wasm")).buffer);
	const registry = new textmate.Registry({
		onigLib: Promise.resolve({
			createOnigScanner: (patterns) => new oniguruma.OnigScanner(patterns),
			createOnigString: (text) => new oniguruma.OnigString(text),
		}),
		loadGrammar: async (scope) => {
			const file = grammars[scope];
			if (!file) return null;
			const full = path.join(syntaxes, file);
			return textmate.parseRawGrammar(fs.readFileSync(full, "utf8"), full);
		},
	});
	const grammar = await registry.loadGrammar("source.rocx");
	const open = [];
	for (const file of files) {
		const lines = fs.readFileSync(file, "utf8").split("\n");
		const dumping = dump && file.endsWith(dump.file);
		let stack = textmate.INITIAL;
		let lastAtRoot = 0;
		lines.forEach((line, index) => {
			const result = grammar.tokenizeLine(line, stack);
			stack = result.ruleStack;
			if (stack.depth === 1) lastAtRoot = index + 1;
			if (dumping && index + 1 >= dump.from && index + 1 <= dump.to) {
				console.log(`${index + 1}: ${line}`);
				for (const token of result.tokens) {
					const text = line.slice(token.startIndex, token.endIndex);
					if (text.trim() !== "") console.log(`    ${JSON.stringify(text).padEnd(32)} ${token.scopes.slice(1).join(" ")}`);
				}
			}
		});
		if (stack.depth !== 1) open.push(`${file}: markup still open at the end (last back in plain Roc after line ${lastAtRoot})`);
	}
	for (const line of open) console.log(`✗ ${line}`);
	console.log(`${files.length} .rocx files tokenized, ${open.length} left open`);
	process.exit(open.length === 0 ? 0 : 1);
};

main().catch((error) => {
	console.error(error);
	process.exit(2);
});
