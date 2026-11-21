# Proposals: what packages/markdown would like from outside it

Everything here is a proposal: nothing outside `packages/markdown/` was changed. The package
compiles and its tests pass without any of them. Each section: the problem, the options, the
recommended change (sketched), what in the package depends on it, and how to undo it.

## 1. Content collections found by `rocx build`

**Problem.** `Collection.load` reads a list of `{ path, source }`, each source a file imported as
text (`import "content/posts/hello.md" as hello : Str`). Today an app writes that list by hand:
a new post means a new import and a new line, and forgetting one drops the post without a word.
Finding the files needs the file system at build time, which only `rocx build` has.

What already works, and decides the design: a top-level value is evaluated when the app is built,
and a `crash` there is a compile error that `roc check` reports with its message. So a collection
loaded in a top-level value fails the build on a bad file (tried in a scratch app:
`bad: draft: expected true or false, found "maybe"`), with no frontmatter checking in JavaScript.

**Options.**

1. `rocx build` finds `content/<name>/**/*.md` and writes a typed module per folder, which loads
   them as above. Checked at build time; the same on both halves.
2. The server reads the files when it starts or when asked (a host primitive to read files, and a
   server-only module, proposal 4). Nothing checked until it runs; the browser can't have them.
3. Leave it: apps list their files by hand.

**Recommended: 1.** The convention: a folder under `content/` holds the Markdown files (at any
depth) and one `.roc` file declaring the type of their frontmatter, named for that type.

```
content/
  posts/
    Post.roc            # Post := { title : Str, date : Str, tags : List(Str) ?? [], draft : Bool ?? Bool.False }.{ parser_for : _ }
    hello-world.md
    2026/
      roc-solid.md
```

`rocx build` writes `Generated/Content/Posts.roc`:

```roc
## Written by rocx build from content/posts: an entry for each .md file there, its frontmatter a
## Post. Don't edit it: edit the files.
import markdown.Collection
import ../../content/posts/Post
import "../../content/posts/hello-world.md" as file_0 : Str
import "../../content/posts/2026/roc-solid.md" as file_1 : Str

Posts := [].{
	Entry : Collection.Entry(Post)

	## Every post, in the order of their paths. Read when the app is built: a file whose
	## frontmatter is wrong fails the build, and the message names it.
	all : List(Posts.Entry)
	all =
		match Collection.load([{ path: "hello-world.md", source: file_0 }, { path: "2026/roc-solid.md", source: file_1 }]) {
			Ok(entries) => entries
			Err(failed) => crash "content/posts/${Collection.describe(failed)}"
		}

	## The post with this id (`"2026/roc-solid"`).
	get : Str -> Try(Posts.Entry, [NotFound])
	get = |id| Collection.find(Posts.all, id)
}
```

A page uses it as any module: `import ../../Generated/Content/Posts`, then `Posts.all`, or
`Posts.get(slug)` in `routes/blog/[slug]/+page.rocx`.

In `bin/rocx.mjs`, beside `componentPackages(dir)`:

```js
// Each folder under content/ with Markdown files and one .roc type: Generated/Content/<Name>.roc.
function contentCollections(dir) {
	const root = join(dir, "content");
	if (!existsSync(root)) return [];
	const alias = headerAliasOf(dir, "markdown"); // the name the app's header gives packages/markdown
	return readdirSync(root).filter((name) => statSync(join(root, name)).isDirectory()).map((name) => {
		const folder = join(root, name);
		const types = readdirSync(folder).filter((file) => /^[A-Z][A-Za-z0-9]*\.roc$/.test(file));
		if (types.length !== 1) throw new RocxError(`content/${name}: put one .roc file beside the Markdown, its type the frontmatter's`);
		const markdown = [...files(folder, ".md")].sort();
		return { name, alias, type: basename(types[0], ".roc"), markdown, out: join(dir, GENERATED, "Content", `${pascalCase(name)}.roc`) };
	});
}
```

…whose outputs go in `routeOutputs` (so a folder that goes takes its module with it), and the dev
server's watcher also watches `content/**/*.md`.

**Depends on it in the package:** nothing; it uses `Collection.load`, `Collection.find` and
`Collection.describe`, which exist. **Undo:** delete the generator; an app lists its files again.

## 2. Trusted raw HTML in `<Markdown>`

**Problem.** `<Markdown>` can show raw HTML as text or leave it out, never as HTML. The platform's
`Html` is opaque, so nothing outside it can make a string markup, and that is on purpose. The one
way in, `Html.source_text`, is rocx's for a `<script>`'s or `<style>`'s text: `rocx lint` refuses it
in hand-written code, the server writes it as is, but the browser's runtime builds it as a text node
and, hydrating, takes the one text node it expects. HTML in it would show as text when the browser
renders the page, and break hydration.

**Options.**

1. Sanitize in Roc, in this package: read the raw HTML's tags, keep an allowlist (`kbd`, `sup`,
   `sub`, `mark`, `abbr`, `details`, `summary`, `br`, `span`…) and their safe attributes, and build
   them with `Html.element`. Safe by construction, on both halves, no platform change; but it needs
   an HTML tokenizer that pairs tags across Markdown's inlines and blocks (`<details>` around
   paragraphs), which is real work.
2. A platform node for trusted markup: `Html.trusted : Str -> Html`. The server writes it between
   comments (`<!--trusted-->…<!--/trusted-->`); the browser builds it through a `<template>` and,
   hydrating, keeps what is between the comments.
3. Leave it: escape or drop.

**Recommended: 1 when someone needs HTML in Markdown, as `raw={Allow(["kbd", "sup", "details"])}`;
2 only if the user decides a trusted escape hatch belongs in `Html` at all (open question 1).** A
sketch of 2, for the decision:

```roc
# web/platform/Html.roc and server/platform/Html.roc
Html :: [ …, Trusted(Str) ].{
	## Markup written as it is: for HTML the app trusts, never for anything a user typed.
	trusted : Str -> Html
	trusted = |markup| Trusted(markup)
}
# serialize!: Trusted(markup) => "{\"t\":\"trusted\",\"v\":${json_str(markup)}}"
# static_str: Trusted(markup) => "<!--trusted-->${markup}<!--/trusted-->"
```

```js
// web/runtime.js, build(): case "trusted": { const t = document.createElement("template"); t.innerHTML = node.v; return t.content; }
// adopt(): case "trusted": skip the cursor past the matching <!--/trusted-->.
```

`rocx lint` would warn on `Html.trusted` as it refuses `Html.source_text`, and `<Markdown>`'s `raw`
would gain `Trusted`.

**Depends on it in the package:** nothing today. **Undo:** remove the variant; `raw` goes back to
`Escape` and `Drop`.

## 3. The site's highlighter in a package

**Problem.** `site/Ui/Highlight.roc` colours Roc, `.rocx` and HTML for the docs. An app can't import
the site's code, so an app's Markdown has no highlighting unless it brings its own.

**Options.**

1. Move it into `packages/highlight/` (plain Roc), with the site's `Code.rocx` as its component.
2. Fold it into this package. But highlighting is useful without Markdown, and Markdown without it.
3. Leave it in the site.

**Recommended: 1.** `Highlight.lines` stays as it is, so the site's callers don't change, and one
function picks a lexer by a code block's language:

```roc
## packages/highlight/main.roc
package [Highlight] {}

## packages/highlight/Highlight.roc (site/Ui/Highlight.roc, moved)
Highlight := [].{
	Token : { kind : Str, text : Str }
	lines : Str, [Code, Markup] -> List(List(Token))

	## The lexer for a code block's language: `roc` and `rocx` start in code, `html` in markup;
	## any other language is plain lines.
	for_lang : Str -> (Str -> List(List(Token)))
}
```

The move: `site/Ui/Highlight.roc` to `packages/highlight/Highlight.roc`; the site's header gains
`highlight: "../packages/highlight/main.roc"`; `site/Ui/Code.rocx` imports `highlight.Highlight`
(and may move to `packages/highlight/components/CodeBlock.rocx`, its `--t-*` colours documented as
custom properties, as charts documents `--chart-*`); `just test` adds
`roc test packages/highlight/main.roc`. Then, in any app:

```roc
<Markdown source={doc} code={Markdown.highlight(|text, lang| Highlight.for_lang(lang)(text))} />
```

**Depends on it in the package:** nothing. `Markdown.highlight` takes any function that gives
lines of `{ kind, text }` tokens, a structural type, so this package never imports the highlighter.
Tried with a copy of `site/Ui/Highlight.roc` in a scratch app: built on both halves, and the
browser's wasm renders the coloured code. **Undo:** move the file back.

## 4. Server-only modules in packages

**Problem (shared with the other packages).** A package can't import a platform module, since an
app is two apps on two platforms; `rocx build` copies only `components/*.rocx` into the app.

**For markdown:** the parser and the component need nothing more. What a `server/` folder would
add: an RSS or Atom feed endpoint for a collection (`Feed.respond!`, on `Endpoint` and `Server`),
and reading Markdown from disk while the server runs (with a host primitive to read files; but
proposal 1 makes that unnecessary for files that ship with the app).

**Recommended (markdown's version, for merging with the others):** `rocx build` copies a package's
`server/` folder (`.roc` and `.rocx`) into the server's half only, as `Generated/<alias>/server/…`,
never into `--client`'s copy; in the app, `import markdown.server.Feed` imports it, and the browser's
copy of a file drops such an import as it drops server functions. **Depends on it:** nothing yet.
**Undo:** stop copying the folder.

## 5. A component that never hydrates

**Problem.** A page that renders `<Markdown>` and hydrates puts the parser in the browser's wasm:
in a scratch app, a page of one `<Markdown>` was 278 KB of wasm (94 KB gzipped); with the same
`<Markdown>` inside `<NoHydration>`, 52 KB (21 KB). Most Markdown is a post or a docs page that
the server renders once, and writing `<NoHydration>` around each one is easy to forget.

**Options.**

1. Document `<NoHydration>` (done: README, "In the browser").
2. Let a component say it renders on the server only: rocx writes each `<Markdown …/>` tag as if it
   were inside `<NoHydration>`, its call gone from the browser's copy. A live preview still has the
   function, `{=Markdown.view({ source: draft!() })}`, which isn't a tag and hydrates.
3. rocx strips any pure component with nothing reactive in its props from the browser's copy. Too
   clever: a pure component in a hole must render again in the browser.

**Recommended: 2, if the user wants `<Markdown>` server-only by default (open question 2).** In the
component's block, a definition rocx reads, as it reads `view` and `view!`:

```roc
Markdown := [].{
	## Rendered on the server only: rocx writes each <Markdown> as if inside <NoHydration>.
	hydrates = Bool.False
	…
}
```

In `src/transpile.mjs`, a tag whose module says so is written as
`Html.no_hydration([Markdown.view({ … })])`, and in the browser's copy `Html.no_hydration([])`; a
handler in its props is refused, as inside `<NoHydration>`.

**Depends on it in the package:** nothing. **Undo:** drop the rule; the tag hydrates again.

## Open questions

1. **Trusted HTML.** Should `Html` gain a node that writes trusted markup as it is (proposal 2,
   option 2)? It would be the one way around "nothing outside `Html` can wrap a string as markup".
   Or should Markdown only ever sanitize (option 1)?
2. **Server-only by default.** Should `<Markdown>` render on the server only unless used as a
   function in a hole (proposal 5)? It saves about 225 KB of wasm on every page that forgets
   `<NoHydration>`, and costs nothing for live previews, which call `Markdown.view` anyway.
3. **Where a collection's type lives.** A `.roc` file beside its Markdown (`content/posts/Post.roc`,
   proposal 1), or one file declaring every collection, as Astro's `content.config.ts` does?
4. **Heading ids.** GitHub's slugs (`"Hello, World!"` is `hello-world`, non-ASCII letters kept as
   they are, duplicates numbered `-1`, `-2`): the convention you want?
5. **The specs' examples.** `Spec.roc` holds 202 examples from the CommonMark and GFM specs (both
   CC BY-SA 4.0), credited in its header, as markdown-it and others ship them. Fine for a repo that
   is going public, or should it keep only examples written here?
