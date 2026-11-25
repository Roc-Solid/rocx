// What `rocx new` does with templates/app/, for the template's tests: the folder copied, each
// placeholder filled in, and the program's database chosen. rocx new (rocx-cli) does the same.
//
// - `{{root}}`: where the platform and packages are, from the app's folder: `./.rocx` in an app
//   rocx new makes (the link to the installed version); here, the path back to this repository.
// - `{{name}}`: the app's name as code writes it (lower-case letters, digits and `_`): its
//   session cookie is `{{name}}_session`.
// - `{{title}}`: the app's name as people read it: the pages' titles, the bar, the mail.
// - The database: main.roc says `database: Sqlite("data/app.db")` (SQLite, the default); for
//   another, that is replaced with `Postgres` or `Turso("data/app.db")`.
import { cpSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

/** templates/app/, the folder rocx new copies. */
export const template = join(dirname(fileURLToPath(import.meta.url)), "..", "app");

/** The repository's root. */
export const repo = join(template, "..", "..");

/** What main.roc says for each database. */
export const databases = {
	sqlite: 'Sqlite("data/app.db")',
	postgres: "Postgres",
	turso: 'Turso("data/app.db")',
};

/** The line rocx new changes for a database other than SQLite. */
export const databaseLine = `database: ${databases.sqlite},`;

/** Every file under `dir`, as paths relative to it. */
function files(dir, under = "") {
	return readdirSync(join(dir, under)).flatMap((entry) => {
		const path = join(under, entry);
		return statSync(join(dir, path)).isDirectory() ? files(dir, path) : [path];
	});
}

/**
 * A new app in `dir` (emptied first), as rocx new makes one: `name` (as code writes it), `title`
 * (as people read it), `database` ("sqlite", "postgres" or "turso"), and the platform and packages
 * at `root` (by default, the path from `dir` back to this repository). Its folder.
 */
export function generate(dir, { name = "acme", title = "Acme", database = "sqlite", root = relative(dir, repo) } = {}) {
	rmSync(dir, { recursive: true, force: true });
	mkdirSync(dir, { recursive: true });
	cpSync(template, dir, { recursive: true });
	for (const path of files(dir)) {
		const file = join(dir, path);
		let text = readFileSync(file, "utf8");
		text = text.replaceAll("{{root}}", root).replaceAll("{{name}}", name).replaceAll("{{title}}", title);
		if (path === "main.roc") {
			if (!text.includes(databaseLine)) throw new Error(`main.roc has no \`${databaseLine}\` line to choose the database on`);
			text = text.replace(databaseLine, `database: ${databases[database]},`);
		}
		const left = /\{\{[a-z]+\}\}/.exec(text);
		if (left) throw new Error(`${path} still has ${left[0]}`);
		writeFileSync(file, text);
	}
	return dir;
}
