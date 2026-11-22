// A package's components (packages/charts/components/*.rocx), which rocx build copies into each
// app that names the package, without the compiler.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { build } from "../rocx-cli/rocx.mjs";
import { scopeClass } from "../rocx-cli/rocx.mjs";

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
		assert.match(chart.join("\n"), /Html\.component\(\|\| Bars\.view!\(\{ n: \|\| 1, \}\)\)/, "a component of the app's, run where it is rendered, given getters (D-039)");

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

test("packages: one that names the server platform is the browser's half as its browser.roc says, or not at all; a page that imports what only the server has is told where", () => {
	const root = mkdtempSync(join(tmpdir(), "rocx-packages-"));
	try {
		const file = (path, content) => {
			mkdirSync(dirname(join(root, path)), { recursive: true });
			writeFileSync(join(root, path), content);
		};
		// jobs: the server's alone. admin: its look for both halves, its jobs page for the server's.
		file("packages/jobs/main.roc", 'package [Job] { pf: platform "../../server/platform/main.roc" }\n');
		file("packages/jobs/Job.roc", "import pf.Db\n\nJob := [].{\n\tnone = 0\n}\n");
		file("packages/admin/main.roc", 'package [Look, JobsPage] { pf: platform "../../server/platform/main.roc", jobs: "../jobs/main.roc" }\n');
		file("packages/admin/browser.roc", "package [Look] {}\n");
		file("packages/admin/Look.roc", "Look := [].{\n\tcolour = \"teal\"\n}\n");
		file("packages/admin/JobsPage.roc", "import pf.Server\nimport jobs.Job\n\nJobsPage := [].{\n\tnone = Job.none\n}\n");
		file("app/main.roc", 'app [program] { admin: "../packages/admin/main.roc", jobs: "../packages/jobs/main.roc", pf: platform "../server/platform/main.roc" }\n');
		file("app/routes/+layout.rocx", "import pf.Html\n\nview! = |{ children, .. }|\n\t<main>{...children}</main>\n");
		file("app/routes/+page.rocx", "import pf.Html\nimport admin.Look\n\nview! = |_|\n\t<p>{Look.colour}</p>\n");
		file("app/routes/jobs/+page.rocx", "import pf.Html\nimport admin.JobsPage\n\nview! = |_|\n\t<p>{JobsPage.none.to_str()}</p>\n");
		const app = join(root, "app");
		const said = [];
		assert.ok(build([app], { client: join(app, "build", "client"), cwd: root, log: (line) => said.push(line) }), said.join("\n"));
		const main = readFileSync(join(app, "build", "client", "main.roc"), "utf8");
		const header = /^app \[main!\] \{ (.*) \}$/m.exec(main)?.[1] ?? "";
		assert.match(header, /^admin: "\.\.\/\.\.\/\.\.\/packages\/admin\/browser\.roc", pf: platform "/, "admin as its browser.roc says; jobs not at all");
		const warnings = said.filter((line) => line.startsWith("⚠"));
		assert.equal(warnings.length, 1, said.join("\n"));
		assert.match(warnings[0], /^⚠ app\/routes\/jobs\/\+page\.rocx:2: the browser's copy imports admin\.JobsPage, which only the server has/);
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
});
