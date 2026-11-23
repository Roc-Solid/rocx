// D-058 spike: what a build-time check would say of every example's SQL today.
//
// For each example app on SQLite: its literal statements at `Db.all!`/`Db.run!` (interpolated or
// passed in a variable: skipped, counted), the record each `Db.all!` is annotated with when it can
// be read from the source (a binding's annotation, or the function's result), its migrations; then
// `describe` (a Rust spike: the engine prepares each statement on a database built from the
// migrations) on SQLite and on Turso, and what a checker would report. Approximate on purpose: the
// row types are read from the text here, where the design has the compiler read them.
//
//   cargo build --release --manifest-path spike/db-checked/describe/Cargo.toml
//   node spike/db-checked/run.mjs [target/release/rocx-describe-spike] [app…]
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const describe = process.argv[2] ?? "spike/db-checked/describe/target/release/rocx-describe-spike";
const only = process.argv.slice(3);
const apps = fs.readdirSync("examples").filter((a) => fs.existsSync(`examples/${a}/migrations`) && (only.length === 0 || only.includes(a)));

function files(dir) {
	const out = [];
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) {
			if (!["node_modules", "Generated", "out", "build", "data", "test", "migrations"].includes(e.name)) out.push(...files(p));
		} else if (/\.(roc|rocx)$/.test(e.name)) out.push(p);
	}
	return out;
}

// A string literal at `i` (just after its `"`): its text, unescaped as Roc does for `\"`, `\\`, `\n`.
function literal(s, i) {
	let text = "";
	while (i < s.length && s[i] !== '"') {
		if (s[i] === "\\") {
			const c = s[i + 1];
			text += c === "n" ? "\n" : c === "t" ? "\t" : c;
			i += 2;
		} else text += s[i++];
	}
	return { text, end: i + 1 };
}

// The top-level items of a bracketed list starting at `i` (`[`): how many, and their text.
function items(s, i) {
	let depth = 0, cur = "", out = [];
	for (let j = i; j < s.length; j++) {
		const c = s[j];
		if (c === '"') { const l = literal(s, j + 1); cur += s.slice(j, l.end); j = l.end - 1; continue; }
		if ("([{".includes(c)) { depth++; if (depth === 1) continue; }
		if (")]}".includes(c)) { depth--; if (depth === 0) { if (cur.trim()) out.push(cur.trim()); return out; } }
		if (c === "," && depth === 1) { out.push(cur.trim()); cur = ""; continue; }
		cur += c;
	}
	return null;
}

function splitTop(text, sep) {
	let depth = 0, cur = "", out = [];
	for (const c of text) {
		if ("([{".includes(c)) depth++;
		if (")]}".includes(c)) depth--;
		if (c === sep && depth === 0) { out.push(cur); cur = ""; } else cur += c;
	}
	if (cur.trim()) out.push(cur);
	return out;
}

// Record aliases anywhere in the app (`Entry : { … }`), by bare name: good enough for a spike.
function aliasesOf(all) {
	const map = new Map();
	for (const f of all) {
		const s = fs.readFileSync(f, "utf8");
		for (const m of s.matchAll(/^\s*([A-Z][A-Za-z0-9]*)\s*:\s*\{/gm)) {
			let depth = 0, j = m.index + m[0].length - 1, start = j;
			for (; j < s.length; j++) { if (s[j] === "{") depth++; if (s[j] === "}") { depth--; if (depth === 0) break; } }
			map.set(m[1], s.slice(start, j + 1));
		}
	}
	return map;
}

function rowFields(typeText, aliases) {
	let t = typeText.trim();
	const tryM = t.match(/^Try\((.*)\)$/s);
	if (tryM) t = splitTop(tryM[1], ",")[0].trim();
	const listM = t.match(/^List\((.*)\)$/s);
	if (!listM) return null;
	let rec = listM[1].trim();
	if (!rec.startsWith("{")) { const a = aliases.get(rec.split(".").pop()); if (!a) return null; rec = a; }
	return splitTop(rec.slice(1, -1), ",").map((p) => { const [name, ...rest] = p.split(":"); return { name: name.trim(), type: rest.join(":").trim() }; }).filter((f) => f.name && f.type);
}

const report = { statements: 0, interpolated: 0, variable: 0, rowsKnown: 0, rowsUnknown: 0, sqliteErrors: [], tursoErrors: [], paramMismatch: [], missingColumn: [], typeMismatch: [], nullableAsPlain: [], fieldsChecked: 0, fieldsUnknown: 0, timing: [] };

const kind = (decl) => {
	if (!decl) return null;
	const d = decl.toLowerCase();
	if (d === "boolean" || d === "bool") return "bool";
	if (d === "json" || d === "jsonb") return "json";
	if (d.includes("int")) return "int";
	if (d.includes("char") || d.includes("clob") || d.includes("text")) return "text";
	if (d.includes("real") || d.includes("floa") || d.includes("doub")) return "real";
	return "numeric";
};
const fits = (k, type) => {
	const nullable = /^(Db\.)?Nullable\((.*)\)$/.exec(type);
	const t = nullable ? nullable[2] : type;
	if (k === "json") return true;
	if (k === "bool") return t === "Bool";
	if (k === "int") return /^[IU](8|16|32|64|128)$|^Dec$|^F(32|64)$|^Bool$/.test(t);
	if (k === "real" || k === "numeric") return /^Dec$|^F(32|64)$|^[IU](8|16|32|64)$/.test(t);
	if (k === "text") return t === "Str" || !/^([IU](8|16|32|64)|Dec|F32|F64|Bool)$/.test(t); // a nominal may read text
	return true;
};

for (const app of apps) {
	const dir = `examples/${app}`;
	const all = files(dir);
	const aliases = aliasesOf(all);
	const calls = [];
	for (const f of all) {
		const s = fs.readFileSync(f, "utf8");
		for (const m of s.matchAll(/Db\.(all|run)!\(\s*/g)) {
			const ls = s.lastIndexOf("\n", m.index) + 1;
			if (/^\s*##/.test(s.slice(ls, m.index))) continue;
			const at = m.index + m[0].length;
			const where = `${f}:${s.slice(0, m.index).split("\n").length}`;
			if (s[at] !== '"') { report.variable++; continue; }
			const lit = literal(s, at + 1);
			if (lit.text.includes("${")) { report.interpolated++; continue; }
			let k = lit.end; while (/[\s,]/.test(s[k])) k++;
			const given = s[k] === "[" ? items(s, k)?.length ?? null : null;
			let row = null;
			if (m[1] === "all") {
				const b = /([a-z_][a-z0-9_]*)\s*=\s*$/.exec(s.slice(ls, m.index));
				if (b) {
					const ann = [...s.slice(0, ls).matchAll(new RegExp(`^\\s*${b[1]}\\s*:\\s*(.+)$`, "gm"))].pop();
					if (ann) row = rowFields(ann[1], aliases);
				} else {
					const fn = [...s.slice(0, ls).matchAll(/^\s*[a-z_][a-z0-9_]*!?\s*:\s*.*=>\s*(.+)$/gm)].pop();
					if (fn) row = rowFields(fn[1], aliases);
				}
				row ? report.rowsKnown++ : report.rowsUnknown++;
			}
			calls.push({ where, sql: lit.text, given, row, kind: m[1] });
		}
	}
	report.statements += calls.length;
	const migrations = fs.readdirSync(`${dir}/migrations`).sort().map((n) => fs.readFileSync(`${dir}/migrations/${n}`, "utf8"));
	const run = (engine) => JSON.parse(execFileSync(describe, { input: JSON.stringify({ engine, migrations, statements: calls.map((c) => c.sql) }), maxBuffer: 1 << 28 }).toString());
	const lite = run("sqlite");
	const turso = run("turso");
	report.timing.push({ app, statements: calls.length, sqlite: { migrate_ms: +lite.migrate_ms?.toFixed(1), describe_ms: +lite.describe_ms?.toFixed(1) }, turso: { migrate_ms: +turso.migrate_ms?.toFixed(1), describe_ms: +turso.describe_ms?.toFixed(1) }, migration_error: lite.migration_error ?? turso.migration_error });
	if (!lite.results) continue;
	calls.forEach((c, i) => {
		const d = lite.results[i];
		const t = turso.results?.[i];
		if (t?.error && !d.error) report.tursoErrors.push(`${c.where}: ${t.error}`);
		if (d.error) { report.sqliteErrors.push(`${c.where}: ${d.error}`); return; }
		if (c.given !== null && c.given !== d.params.length) report.paramMismatch.push(`${c.where}: ${d.params.length} used, ${c.given} given`);
		if (!c.row) return;
		for (const field of c.row) {
			const col = d.columns.find((x) => x.name === field.name);
			if (!col) { report.missingColumn.push(`${c.where}: ${field.name}`); continue; }
			const k = kind(col.decltype);
			if (!k) { report.fieldsUnknown++; continue; }
			report.fieldsChecked++;
			if (!fits(k, field.type)) report.typeMismatch.push(`${c.where}: ${field.name} : ${field.type} from ${col.decltype}`);
			const plain = !/Nullable\(/.test(field.type);
			if (plain && col.origin && col.not_null === false) report.nullableAsPlain.push(`${c.where}: ${field.name} : ${field.type} from ${col.table}.${col.origin}`);
		}
	});
}
console.log(JSON.stringify(report, null, 1));
