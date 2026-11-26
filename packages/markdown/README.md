# markdown

Markdown for Roc Solid apps:

- a parser in plain Roc: CommonMark, with GitHub's tables, strikethrough, task lists, bare links
  and footnotes;
- a `<Markdown>` component that renders the parsed document as the platform's markup, with hooks
  to draw headings, code, links, images and footnotes your own way;
- frontmatter read into a record type the app declares;
- collections: a folder of Markdown files as a typed list, in the manner of Astro.

```roc
import markdown.Markdown

<Markdown source={post.body} />
```

It is safe by default: raw HTML in the source is shown as text, and a link or an image whose URL
could run script (`javascript:`) points nowhere.

The user guide, with every example rendered, is the docs site's
[Markdown page](https://roc-solid.github.io/ecosystem/markdown); this file is the reference.

## Installing it

Name the package in the app's header (`main.roc`):

```roc
app [program] { markdown: "../packages/markdown/main.roc", pf: platform "…" }
```

It is a package, not a plugin: there is nothing to register. It has two halves.

**The parser is a Roc package** (`main.roc` exposes `Block`, `Collection`, `Frontmatter`,
`Inline`, `Md`, `Spec` and `Yaml`). It is plain Roc on no platform, so the server, a component in
the browser and a test all use the same functions. Import its modules as `markdown.Md` and so on.

**The component is a `.rocx` file** (`components/Markdown.rocx`). It imports the platform's
`Html`, which a Roc package can't do for an app that is two programs (the server's and the
browser's). So `rocx build` copies it into the app, as `Generated/markdown/Markdown.roc`, where
`pf` is each half's own platform; `rocx build --client` gives the browser's copy the same. In a
`.rocx` file, `import markdown.Markdown` imports that copy.

## The modules

| Module | What it does |
|---|---|
| `Md` | `parse(source)` makes the document. `to_html(doc)` writes it as HTML text (a feed's, an email's), raw HTML escaped and headings without ids; `to_html_with(doc, { raw, ids })` with options (`raw : [Escape, Drop, Trusted]`, `ids : Bool`, both optional). `headings(doc)` (a table of contents: `{ level, id, text }`), `slug(text)`, `words(doc)`, `reading_minutes(doc)` (200 words a minute, rounded up), `safe_url(url)`, `href(url)` (percent-encodes what a URL can't hold), `escape(text)`. Footnotes: `footnotes(doc)`, `footnote_id(label)`, `footnote_ref_id(label, nth)`, `footnote_problems(source)`. |
| `Block` | A block: `Paragraph`, `Heading({ level, id, content })`, `Code({ lang, info, text })`, `Quote`, `Unordered({ tight, items })`, `Ordered({ start, tight, items })`, `Table({ align, head, rows })`, `Raw` (an HTML block), `Rule`, `Footnotes(List(Note))`. An item is `{ task : [None, Open, Done], blocks }`; a note is `{ label, number, refs, blocks }`. `Block.plain(doc)` is the document's words. |
| `Inline` | What text is made of: `Text`, `Code`, `Emph`, `Strong`, `Strike`, `Link({ url, title, content })`, `Image({ url, title, alt })`, `Raw`, `Footnote({ label, number, nth })`, `Break`, `SoftBreak`. `Inline.plain(content)` is the words. |
| `Frontmatter` | `read(source)`: the YAML between the `---` lines at a file's start, decoded into your record, and the body. `split(source)`: the YAML, the body, and the body's first line number, undecoded. |
| `Yaml` | The YAML frontmatter is written in: `parse`, `decode` (into any type with a parser), `get`, `describe(problem)`. |
| `Collection` | Files as entries: `load(files)`, `entry(path, source)`, `find(entries, id)`, `id(path)`, `describe(problem)`. `Collection.Entry(data)` is `{ id, data, body, doc }`. |
| `Spec` | Nothing to import: examples from the specs, as `expect`s. |

`roc test packages/markdown/main.roc` runs every module's `expect`s.

## `<Markdown>`

`Markdown` is a pure component (`view`, no `!`): it makes markup from its props and runs nothing
after. Every prop has a default, so `<Markdown source={text} />` is a whole use.

| Prop | Default | What it is |
|---|---|---|
| `source : Str` | `""` | The Markdown. |
| `doc : List(Block)` | `[]` | Or the document, already parsed (to make a table of contents from the same parse). Used when it isn't empty. |
| `raw : [Escape, Drop]` | `Escape` | Raw HTML in the source: shown as text (`Escape`) or left out (`Drop`). |
| `class : Str` | `"markdown"` | The class of the `<div>` it renders in. |
| `heading : Markdown.Heading -> Html` | `Markdown.heading` | Draws a heading, given `{ level, id, text, children }`. The default is `<h2 id="…">` for a level 2. |
| `code : Markdown.Code -> Html` | `Markdown.code` | Draws a code block, given `{ lang, info, text }`. `lang` is the info string's first word, `""` for none. The default is `<pre><code class="language-…">`. |
| `link : Markdown.Link -> Html` | `Markdown.link` | Draws a link, given `{ url, title, children }`. |
| `image : Markdown.Image -> Html` | `Markdown.image` | Draws an image, given `{ url, title, alt }`. |
| `footnote : Markdown.Footnote -> Html` | `Markdown.footnote` | Draws a footnote's reference, given `{ number, href, id }` (`#fn-salt`, `fnref-salt`). The default is `<sup class="footnote-ref"><a …>1</a></sup>`. |
| `notes : List(Markdown.Note) -> Html` | `Markdown.notes` | Draws the notes at the end, given each one's `{ number, id, children, backs }` (`backs`: where each reference to it is, for links back). The default is `<section class="footnotes"><ol>…</ol></section>`, with `↩` links labelled in English. |

Each hook is given what the node says, with its children already rendered, so it decides only its
own element. The defaults are public, for a hook to fall back on.

Anchors beside headings:

```roc
<Markdown
	source={post.body}
	heading={|h| Html.element("h${h.level.to_str()}", [Html.attr("id", h.id)], [<a href={"#${h.id}"} class="anchor">#</a>].concat(h.children))}
/>
```

Links to other sites in a new tab, the default for the rest:

```roc
link={|l| if (l.url.starts_with("https://")) <a href={l.url} target="_blank" rel="noopener">{...l.children}</a> else Markdown.link(l)}
```

### Highlighting

`Markdown.highlight(lines)` makes a `code` hook from any highlighter. `lines(text, lang)` returns
the code's lines, each a list of tokens (`Markdown.Token`, `{ kind : Str, text : Str }`, `""` for
plain text). Each token with a kind becomes a `<span class="t-kind">` for your CSS to colour. The
docs site's `Highlight` (`site/Ui/Highlight.roc`) gives exactly these:

```roc
<Markdown source={doc} code={Markdown.highlight(|text, lang| if (lang == "html") Highlight.lines(text, Markup) else Highlight.lines(text, Code))} />
```

An app can't import the site's highlighter yet: `PROPOSALS.md` proposes moving it into a package.

## Footnotes

Footnotes are GitHub's. `[^label]` in the text refers to a note, and `[^label]: what it says` on a
line of its own, anywhere in the document, is the note. A note's further lines are indented four
spaces (or continue its paragraph), so a note may hold paragraphs, lists or code.

```markdown
A loaf keeps for days[^salt], longer in a cloth[^cloth].

[^salt]: About 2% of the flour's weight.
[^cloth]: Linen, not plastic.

    A second paragraph of the same note.
```

`Md.parse` numbers the notes in the order the text first refers to them, and puts them at the end
of the document as one `Footnotes` block. A reference is an `Inline.Footnote`; its `nth` says which
reference to its note it is. A note nothing refers to is left out, a reference to no note stays
text, and labels match without case, as on GitHub.

`Md.to_html` writes them as cmark-gfm does: `<sup class="footnote-ref"><a href="#fn-salt"
id="fnref-salt" data-footnote-ref>1</a></sup>` in the text, then `<section class="footnotes"
data-footnotes>` with a link back (`↩`) to each reference. `<Markdown>` draws them through its
`footnote` and `notes` hooks, so a page can give the notes a heading and labels in its own
language:

```roc
notes = |found|
	<section class="notes" aria-labelledby="notes-title">
		<h2 id="notes-title">Notes</h2>
		<ol>{...found.map(|note| <li id={note.id}>{...note.children}{...note.backs.map(|href| <a href={href} aria-label="Back to the text">↩</a>)}</li>)}</ol>
	</section>

<Markdown source={post.body} notes={notes} />
```

`Md.footnotes(doc)` is the notes. `Md.footnote_id("salt")` and `Md.footnote_ref_id("salt", 2)`
are the anchors (`fn-salt`, `fnref-salt-2`). `Md.footnote_problems(source)` lists what is wrong,
for a build's or a test's check of what writers write: a reference to a note that isn't there, a
note given twice, and a note nothing refers to (`[^cloth] is a note nothing refers to`).
`examples/journal` checks its posts this way.

## Walking the document

The document is plain data, so a table of contents, a reading time or a summary is a function:

```roc
doc = Md.parse(post.body)

<aside>
	<p>{Md.reading_minutes(doc).to_str()} min read</p>
	<nav>{...Md.headings(doc).keep_if(|h| h.level == 2).map(|h| <a href={"#${h.id}"}>{h.text}</a>)}</nav>
</aside>
<Markdown doc={doc} />
```

A heading's id is its text as GitHub makes one (`"Hello, World!"` is `hello-world`), numbered when
an earlier heading has it already (`intro`, `intro-1`). Blocks and inlines compare with `==`, so a
test can check a parse without rendering it.

## Frontmatter

`Frontmatter.read` decodes a file's frontmatter into a record you declare. Make it a nominal type
(`:=`) so its fields can have defaults (`??`), and add `parser_for : _` so Roc writes the parser
for it. The type says what each value is: `2026` is a number for a `U64` field and text for a `Str`
one.

```roc
Post := { title : Str, date : Str, tags : List(Str) ?? [], draft : Bool ?? Bool.False }.{
	parser_for : _
}

match Frontmatter.read(source) {
	Ok({ data, body }) => …                     # data : Post
	Err(problem) => Yaml.describe(problem)     # "draft: expected true or false, found \"maybe\""
}
```

A missing field without a default, a value of the wrong kind, a tag the union doesn't have, a key
set twice or a line indented wrong is an error that says which, and where.

The YAML is the part frontmatter uses: maps, lists (block and `[a, b]`), inline maps (`{ a: 1 }`),
plain and quoted scalars, `|` and `>` block scalars, comments, and null (`~`, `null`, or nothing),
which leaves a field to its default. Not anchors, aliases, tags, several documents, or keys that
aren't scalars.

## Collections

A collection is a folder of Markdown files whose frontmatter has one type. Each folder under the
app's `content/` is one. `rocx build` finds its `.md` files, at any depth, and writes a module for
it, `Generated/Content/<Name>.roc` (`content/blog-posts/` is `BlogPosts`), each file imported as
text. A new post is a new file, and nothing else. A collection's folder is named in lower case.

With one `.roc` file beside the Markdown, named for the frontmatter's type, the module reads the
files too:

```
content/
  posts/
    Post.roc              Post := { title : Str, date : Str, tags : List(Str) ?? [], draft : Bool ?? Bool.False }.{ parser_for : _ }
    hello.md
    2026/
      later.md
```

```roc
import Generated/Content/Posts

Posts.all                 # List(Collection.Entry(Post)), in the order of their paths
Posts.get("2026/later")   # Try(Collection.Entry(Post), [NotFound])
Posts.files               # List({ path, source }): the files as text
```

`all` is read when the app is built, so a file whose frontmatter is wrong fails the build, naming
the file and the field (`content/posts/hello: title is missing`). A typed folder needs the
markdown package in the app's header; `rocx build` says so if it's missing.

A folder with no type has `files` alone, for an app that reads them its own way:
`Collection.load(Posts.files)`, or several folders of one type read together (`examples/journal`
reads `content/en/` and `content/pl/` as one collection of posts). The browser's copy has the files
too, for a component that reads one.

An entry is `{ id, data, body, doc }`: `id` is its path without `.md` (`2026/later`), `data` its
frontmatter, `body` the rest of the file, and `doc` the body parsed.

Outside `content/`, list the files yourself, each imported as text:

```roc
import "posts/hello.md" as hello : Str

posts = Collection.load([{ path: "hello.md", source: hello }])
```

## In the browser

A page that hydrates `<Markdown>` puts the parser in the browser's wasm: measured in a small app,
about 225 KB more (73 KB gzipped). Markdown that the server renders once and nothing changes (a
post, a docs page) belongs in `<NoHydration>`, which keeps the browser's copy of it out of the wasm
altogether:

```roc
<NoHydration>
	<Markdown source={post.body} />
</NoHydration>
```

A live preview is the other case: render it in a hole, which renders it again whenever what is
typed changes:

```roc
(draft!, set_draft!) = create_signal!("")
<textarea on:input.value={set_draft!}></textarea>
{Markdown.view({ source: draft!() })}
```

## Safety

Raw HTML (`<b>`, `<script>`, an HTML block) is escaped unless a renderer is told otherwise.
`raw={Drop}` leaves it out. `Md.to_html_with(doc, { raw: Trusted })` writes it as it is, and checks
no URLs, for a source you wrote yourself. `<Markdown>` can't take trusted HTML: the platform's
`Html` has no way to put a string into a page as markup (see `PROPOSALS.md`).

A link's or an image's URL may be relative, or start with `http:`, `https:`, `mailto:` or `tel:`.
Anything else (`javascript:`, `data:`, `vbscript:`, with tabs or line breaks hidden in it or not)
becomes `about:invalid#rocx-unsafe-url`. `Md.to_html` checks with `Md.safe_url`; `<Markdown>`
leaves it to the platform's `Html`, which checks every URL it renders the same way (and, like any
`<img>`, lets an image's `data:image/…` URL through).

## What works, and what doesn't yet

Works today:

- The parser passes 649 of CommonMark 0.31.2's 652 examples. The other three are bare links
  (`https://…`, `www.…`, `someone@example.com`), which GitHub's extension makes links of and
  CommonMark leaves as text. Of GFM's extension examples, all but the tag filter pass (the specs'
  HTML passes raw HTML through, so they are checked with `raw: Trusted`). `Spec.roc` runs 202 of
  these examples.
- `<Markdown>`, its hooks and `Markdown.highlight`, on both halves of an app; the browser's wasm
  renders the same page as the server.
- Frontmatter read into a record, collections found by `rocx build`, and a bad file failing the
  build.

Not yet (each a proposal in `PROPOSALS.md`):

- Trusted raw HTML in `<Markdown>`, or HTML from an allowlist.
- The site's highlighter in a package of its own.
- An RSS or Atom feed for a collection, on the server: a package may have server-only modules now
  (D-033), and this one has none yet.
- A component that never hydrates, without writing `<NoHydration>` around it.

Limits:

- A reference's label is case folded for ASCII, Latin-1, Latin Extended-A, Greek, Cyrillic and
  `ß`, not all of Unicode; emphasis knows Unicode's punctuation by its main blocks.
- No heading attributes (`{#id}`), smart quotes or maths.
- A footnote's label has no spaces or brackets in it. References inside a note number the notes
  they refer to after the ones the text refers to.
