// Builds the site's client wasm with each page's view replaced by Html.empty, and once with all of
// them replaced, and prints raw and brotli sizes: what each page alone owns, and the shared core.
import { readFileSync, writeFileSync, mkdirSync, copyFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { brotliCompressSync, constants } from "node:zlib";
const [client, outDir, roc, ...flags] = process.argv.slice(2);
const rootFile = `${client}/Generated/Root.roc`;
const original = readFileSync(rootFile, "utf8");
copyFileSync(rootFile, `${outDir}/Root.roc.orig`);
const pages = [...original.matchAll(/Html\.component\(\|\| (\w+Page)\.view!\(\{ params: params \}\)\)/g)].map((m) => m[1]);
const unique = [...new Set(pages)];
const br = (b) => brotliCompressSync(b, { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
mkdirSync(outDir, { recursive: true });
function build(name, without) {
	let text = original;
	for (const page of without) text = text.replaceAll(`Html.component(|| ${page}.view!({ params: params }))`, "Html.empty({})");
	writeFileSync(rootFile, text);
	const out = `${outDir}/${name}.wasm`;
	const r = spawnSync(roc, ["build", "--target=wasm32", ...flags, `--output=${out}`, `${client}/main.roc`], { encoding: "utf8" });
	if (r.status !== 0) { console.log(name, "FAILED", r.stdout.slice(-800), r.stderr.slice(-800)); return null; }
	spawnSync("sh", ["-c", `cp "${out}" "${out}.stripped" && nix shell nixpkgs#wabt -c wasm-strip "${out}.stripped"`]); const bytes = readFileSync(`${out}.stripped`);
	return { raw: bytes.length, br: br(bytes) };
}
try {
	const all = build("all", []);
	console.log(`all\t${all.raw}\t${all.br}`);
	const none = build("core", unique);
	console.log(`core\t${none.raw}\t${none.br}`);
	for (const page of unique) {
		const m = build(`minus-${page}`, [page]);
		if (m) console.log(`${page}\t${all.raw - m.raw}\t${all.br - m.br}`);
	}
} finally {
	writeFileSync(rootFile, original);
}
