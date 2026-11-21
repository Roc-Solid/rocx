// A package's components (packages/charts/components/*.rocx), which rocx build copies into each
// app that names the package, without the compiler.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { build } from "../bin/rocx.mjs";
import { scopeClass } from "../src/styles.mjs";

test("packages: rocx build copies a package's components into the app, and `import charts.X` imports the copy", () => {
	const root = mkdtempSync(join(tmpdir(), "rocx-packages-"));
	try {
		const file = (path, content) => {
			mkdirSync(dirname(join(root, path)), { recursive: true });
			writeFileSync(join(root, path), content);
		};
		file("packages/charts/main.roc", "package [Scale] {}\n");
		file("packages/charts/Scale.roc", "Scale := [].{\n\tat = |x| x\n}\n");
		file("packages/charts/components/Bars.rocx", 'import pf.Html\nimport charts.Scale\n\nBars := [].{\n\tview! = |{ n }| <p class="bars">{Scale.at(n).to_str()}</p>\n\n\t<style>\n\t\t.bars { color: red }\n\t</style>\n}\n');
		file("packages/charts/components/Pie.rocx", "import pf.Html\n\nPie := [].{\n\tview! = |{}| <p>pie</p>\n}\n");
		// The app names the package `plots`, not `charts`: the copies import it by that name.
		file("app/main.roc", 'app [main!] { plots: "../packages/charts/main.roc", pf: platform "../web/platform/main.roc" }\n');
		file("app/routes/+layout.rocx", "import pf.Html\n\nview! = |{ children, .. }|\n\t<main>{...children}</main>\n");
		file("app/routes/+page.rocx", "import pf.Html\n\nview! = |_|\n\t<p>Hi</p>\n");
		file("app/Demos/Chart.rocx", "import pf.Html\nimport plots.Bars\nimport plots.Scale\n\nChart := [].{\n\tview! = |{}| <div><Bars n={1} /></div>\n}\n");
		const app = join(root, "app");
		const said = [];
		assert.ok(build([app], { log: (line) => said.push(line) }), said.join("\n"));

		const bars = readFileSync(join(app, "Generated", "plots", "Bars.roc"), "utf8");
		assert.match(bars, /^import plots\.Scale$/m, "its own package, by the app's name for it");
		assert.equal(bars.split("\n").length, readFileSync(join(root, "packages/charts/components/Bars.rocx"), "utf8").split("\n").length + 2, "line for line, and the marker");
		assert.match(bars.trimEnd().split("\n").pop(), /^# rocx: generated from \.\.\/\.\.\/\.\.\/packages\/charts\/components\/Bars\.rocx: edit that file/);
		assert.ok(existsSync(join(app, "Generated", "plots", "Pie.roc")));

		const chart = readFileSync(join(app, "Demos", "Chart.roc"), "utf8").split("\n");
		assert.equal(chart[1], "import ../Generated/plots/Bars", "a component: its copy, from where the file is");
		assert.equal(chart[2], "import plots.Scale", "a module of the package: as it was");
		assert.match(chart.join("\n"), /Html\.component\(\|\| Bars\.view!\(\{ n: 1, \}\)\)/, "a component of the app's, run where it is rendered");

		const styles = readFileSync(join(app, "Generated", "Styles.roc"), "utf8");
		assert.ok(styles.includes(`".bars.${scopeClass("Generated/plots/Bars.Bars")} { color: red }",`), styles);

		// A component the package no longer has: its copy goes.
		rmSync(join(root, "packages/charts/components/Pie.rocx"));
		assert.ok(build([app], { log: (line) => said.push(line) }), said.join("\n"));
		assert.equal(existsSync(join(app, "Generated", "plots", "Pie.roc")), false);
		assert.ok(existsSync(join(app, "Generated", "plots", "Bars.roc")));
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
});
