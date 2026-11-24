// Content collections (D-042): each folder under an app's content/ is listed by rocx build in a
// module of its own (Generated/Content/<Name>.roc), its Markdown files imported as text; with a type
// beside them, read as the app is built, a wrong file failing the build.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "../rocx-cli/rocx.mjs";
import { roc as findRoc } from "../server/build.mjs";

const repo = join(dirname(fileURLToPath(import.meta.url)), "..");
const roc = (() => {
	try {
		return findRoc();
	} catch {
		return "";
	}
})();
const hasRoc = roc !== "" && spawnSync(roc, ["version"]).status === 0;

/** A scratch app with a typed collection (posts) and an untyped one (notes); the app's root. */
function scratch() {
	const app = realpathSync(mkdtempSync(join(tmpdir(), "rocx-content-")));
	const file = (path, content) => {
		mkdirSync(dirname(join(app, path)), { recursive: true });
		writeFileSync(join(app, path), content);
	};
	const from = (path) => relative(app, join(repo, path));
	file(
		"main.roc",
		`app [program] { markdown: "${from("packages/markdown/main.roc")}", pf: platform "${from("server/platform/main.roc")}" }

import pf.Server
import Generated/Content/Posts
import Generated/Content/Notes

program = {
	init!: |_started| Ok({}),
	respond!: |_, _| Server.response(200, [], Str.join_with(Posts.all.map(|post| post.data.title), ", ")),
	database: Postgres,
	migrations: [],
	actors: [],
	logs: { format: Auto },
	plugins: [],
	routes: [],
}

expect Posts.all.map(|post| post.id) == ["2026/later", "hello"]
expect Posts.get("hello").map_ok(|post| post.data.title) == Ok("Hello")
expect Notes.files.map(|note| note.path) == ["first.md"]
`,
	);
	file("content/posts/Post.roc", "Post := { title : Str, draft : Bool ?? Bool.False }.{\n\tparser_for : _\n}\n");
	file("content/posts/hello.md", "---\ntitle: Hello\n---\nThe first.\n");
	file("content/posts/2026/later.md", "---\ntitle: Later\ndraft: true\n---\nThe second.\n");
	file("content/notes/first.md", "Just a note.\n");
	return { app, file };
}

test("content: each folder under content/ is a module listing its Markdown files, and one with a type beside them reads them; a folder that goes takes its module with it", () => {
	const { app, file } = scratch();
	try {
		const said = [];
		assert.ok(build([app], { log: (line) => said.push(line) }), said.join("\n"));
		const posts = readFileSync(join(app, "Generated", "Content", "Posts.roc"), "utf8");
		assert.match(posts, /^import markdown\.Collection\nimport \.\.\/\.\.\/content\/posts\/Post$/m, "the type beside the files, and the app's name for packages/markdown");
		assert.match(posts, /^import "\.\.\/\.\.\/content\/posts\/2026\/later\.md" as file_0 : Str\nimport "\.\.\/\.\.\/content\/posts\/hello\.md" as file_1 : Str$/m, "every file, at any depth, in the order of their paths");
		assert.match(posts, /^\t\t\{ path: "2026\/later\.md", source: file_0 \},$/m);
		assert.match(posts, /^\tall : List\(Collection\.Entry\(Post\)\)$/m);
		assert.match(posts, /crash "content\/posts\/\$\{Collection\.describe\(failed\)\}"/);
		assert.match(posts.trimEnd().split("\n").pop(), /^# rocx: generated from content\/posts\//);
		const notes = readFileSync(join(app, "Generated", "Content", "Notes.roc"), "utf8");
		assert.doesNotMatch(notes, /import markdown\.Collection|Collection\.load\(/, "no type, no reading: the files alone");
		assert.match(notes, /^\t\t\{ path: "first\.md", source: file_0 \},$/m);

		// A new file is in the module at the next build; a folder that goes takes its module with it.
		file("content/notes/second.md", "Another.\n");
		assert.ok(build([app], { log: (line) => said.push(line) }), said.join("\n"));
		assert.match(readFileSync(join(app, "Generated", "Content", "Notes.roc"), "utf8"), /second\.md/);
		rmSync(join(app, "content", "notes"), { recursive: true });
		assert.ok(build([app], { log: (line) => said.push(line) }), said.join("\n"));
		assert.equal(existsSync(join(app, "Generated", "Content", "Notes.roc")), false);
		assert.ok(existsSync(join(app, "Generated", "Content", "Posts.roc")));
	} finally {
		rmSync(app, { recursive: true, force: true });
	}
});

test("content: the browser's copy has the files too; a folder that can't be a module's name, or two types beside the files, are refused", () => {
	const { app, file } = scratch();
	const out = join(app, "..", `${relative(join(app, ".."), app)}-client`);
	try {
		const said = [];
		assert.ok(build([app], { client: out, log: (line) => said.push(line) }), said.join("\n"));
		assert.equal(readFileSync(join(out, "content", "posts", "2026", "later.md"), "utf8"), "---\ntitle: Later\ndraft: true\n---\nThe second.\n");
		assert.ok(existsSync(join(out, "Generated", "Content", "Posts.roc")));

		file("content/posts/Other.roc", "Other := { title : Str }.{\n\tparser_for : _\n}\n");
		const twice = [];
		assert.equal(build([app], { log: (line) => twice.push(line) }), false);
		assert.match(twice.join("\n"), /content\/posts: one \.roc file beside the Markdown, the type of its frontmatter, not Other\.roc, Post\.roc/);
		rmSync(join(app, "content", "posts", "Other.roc"));

		file("content/Bad Name/x.md", "x\n");
		const refused = [];
		assert.equal(build([app], { log: (line) => refused.push(line) }), false);
		assert.match(refused.join("\n"), /content\/Bad Name: a collection's folder is named in lower case/);
	} finally {
		rmSync(app, { recursive: true, force: true });
		rmSync(out, { recursive: true, force: true });
	}
});

test("content: a typed collection compiles, its expects pass, and a file whose frontmatter is wrong fails the build, naming it", { skip: !hasRoc && "no Roc (run `just setup`, or set ROC)" }, () => {
	const { app, file } = scratch();
	try {
		const said = [];
		assert.ok(build([app], { log: (line) => said.push(line) }), said.join("\n"));
		const tested = spawnSync(roc, ["test", join(app, "main.roc")], { encoding: "utf8" });
		assert.equal(tested.status, 0, tested.stdout + tested.stderr);
		file("content/posts/hello.md", "---\ndraft: maybe\n---\nNo title.\n");
		assert.ok(build([app], { log: (line) => said.push(line) }), said.join("\n"));
		const checked = spawnSync(roc, ["check", join(app, "main.roc")], { encoding: "utf8" });
		assert.notEqual(checked.status, 0);
		assert.match(checked.stdout + checked.stderr, /content\/posts\/hello: /);
	} finally {
		rmSync(app, { recursive: true, force: true });
	}
});
