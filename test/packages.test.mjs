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

// packages/admin draws its pages in the platform's admin look (the jobs page's, the mailbox's), from
// a copy in packages/admin/Look.roc, since the platform doesn't expose server/platform/AdminHtml.roc.
// This keeps the copy from drifting: each part of AdminHtml's stylesheet is either one Look carries
// as it is, or one it leaves out (the jobs page's own); and the helpers Look copies are AdminHtml's,
// line for line. What is compared is Roc's text of each string, so how the files are laid out
// doesn't matter. When it fails, copy that part of AdminHtml into Look.roc again, and update the
// commit Look's comment says it matches.
test("packages/admin: Look carries the platform's admin look (AdminHtml's stylesheet and helpers) as AdminHtml has it", () => {
	const root = join(dirname(new URL(import.meta.url).pathname), "..");
	const adminHtml = readFileSync(join(root, "server/platform/AdminHtml.roc"), "utf8");
	const look = readFileSync(join(root, "packages/admin/Look.roc"), "utf8");
	const resync = "copy it from server/platform/AdminHtml.roc into packages/admin/Look.roc again, and update the commit Look.roc's comment says it matches";

	// A stylesheet's parts: each `# comment` in its list of strings starts one; a part is its strings' text, joined.
	const parts = (source, file) => {
		const start = source.search(/^\t*stylesheet =$/m);
		assert.ok(start >= 0, `${file} has no stylesheet`);
		const list = source.slice(start, source.indexOf("\n\t\t],", start));
		const found = new Map();
		let name = "(before any comment)";
		for (const [, comment, text] of list.matchAll(/#[ \t]*([^\n]*)|"((?:[^"\\]|\\.)*)"/g)) {
			if (comment !== undefined) name = comment.trim();
			else found.set(name, (found.get(name) ?? "") + text);
		}
		return found;
	};
	const platform = parts(adminHtml, "AdminHtml.roc");
	const copied = [...parts(look, "Look.roc").values()].join("");
	const shared = ["Tokens: light, and dark when the reader's scheme is.", "The shell: a sidebar, and the main part.", "The main part's header.", "Panels.", "Tables.", "Buttons.", "Nothing to show; a callout.", "Narrower screens."];
	const jobsOnly = ["Metrics: how many of each state.", "A job's state.", "Filters.", "The last hour.", "Lists in a panel: failures, schedules.", "Kinds.", "A job, in a drawer over the list.", "Plain pages (the mailbox's): a list of facts, a frame."];
	for (const name of platform.keys()) {
		assert.ok(shared.includes(name) || jobsOnly.includes(name), `AdminHtml's stylesheet has a part this test doesn't know, "${name}": say whether the admin's pages share it (then ${resync}) or not, in test/packages.test.mjs`);
	}
	for (const name of shared) {
		assert.ok(platform.has(name), `AdminHtml's stylesheet no longer has the part "${name}": update the parts test/packages.test.mjs names`);
		assert.ok(copied.includes(platform.get(name)), `packages/admin/Look.roc's stylesheet differs from AdminHtml's part "${name}": ${resync}`);
	}

	// A helper's definition, from its type to the next one: its text with the module's name and the
	// spaces taken out.
	const definition = (source, name) => {
		const at = source.search(new RegExp(`^\\t${name} : `, "m"));
		if (at < 0) return null;
		const end = source.slice(at + 1).search(/^\t(?:##|[a-z_]+ : )|^\}/m);
		return source.slice(at, at + 1 + end).replace(/\b(?:AdminHtml|Look)\./g, "").replace(/\s+/g, " ").trim();
	};
	for (const name of ["escape", "side", "nav_link", "nav_label", "header", "panel", "empty", "button_with"]) {
		assert.ok(definition(adminHtml, name), `AdminHtml has no ${name}: update the helpers test/packages.test.mjs names`);
		assert.equal(definition(look, name), definition(adminHtml, name), `Look.${name} differs from AdminHtml.${name}: ${resync}`);
	}
	// Its icons: each of AdminHtml's, drawn as AdminHtml draws it (Look has a few more of its own).
	const icons = (source) => {
		const body = definition(source, "icon");
		return { svg: /"<svg[^]*?<\/svg>"/.exec(body)?.[0], arms: [...body.matchAll(/("[a-z]+") => ("(?:[^"\\]|\\.)*")/g)].map(([, name, paths]) => `${name} => ${paths}`) };
	};
	const drawn = icons(look);
	assert.equal(drawn.svg, icons(adminHtml).svg, `Look.icon draws its <svg> differently from AdminHtml.icon: ${resync}`);
	for (const arm of icons(adminHtml).arms) assert.ok(drawn.arms.includes(arm), `Look.icon lacks AdminHtml's icon ${arm.split(" =>")[0]}, or draws it differently: ${resync}`);
});
