# markdown

Markdown for Roc Solid apps: a parser in plain Roc (CommonMark, with GitHub's tables,
strikethrough, task lists, bare links and footnotes), a `<Markdown>` component that renders it as the
platform's markup, frontmatter read into a record the app declares, and Astro-style collections of
Markdown files.

```roc
import markdown.Markdown

<Markdown source={post.body} />
```

Safe by default: raw HTML in the source is shown as text, and a link or an image whose URL could
run script (`javascript:`) points nowhere.

## Two halves

**The parser is a Roc package** (`main.roc`): plain Roc on no platform, so the server, a component
in the browser and a test all use the same functions. `Md.parse` makes a document a list of
`Block`s, a tree an app can walk and render as it likes.

| Module | What it does |
|---|---|
| `Md` | `parse(source)` is the document; `to_html(doc)` is HTML text (a feed's, an email's), `to_html_with(doc, { raw, ids })` as told; `headings(doc)` (a table of contents), `slug(text)`, `words(doc)`, `reading_minutes(doc)`, `safe_url(url)`, `href(url)`, `escape(text)` |
| `Block` | a block: `Paragraph`, `Heading({ level, id, content })`, `Code({ lang, info, text })`, `Quote`, `Unordered({ tight, items })`, `Ordered({ start, tight, items })`, `Table({ align, head, rows })`, `Raw` (an HTML block), `Rule`; an item is `{ task : [None, Open, Done], blocks }`; `Block.plain(doc)` is its words |
| `Inline` | what text is made of: `Text`, `Code`, `Emph`, `Strong`, `Strike`, `Link({ url, title, content })`, `Image({ url, title, alt })`, `Raw`, `Break`, `SoftBreak`; `Inline.plain(content)` |
| `Frontmatter` | `read(source)`: the YAML between the `---` lines at a file's start, decoded into your record, and the body; `split(source)` |
| `Yaml` | the YAML frontmatter is written in: `parse`, `decode` (into any type with a parser), `get`, `describe(problem)` |
| `Collection` | a folder's files as entries: `load(files)`, `entry(path, source)`, `find(entries, id)`, `describe(problem)`; `Collection.Entry(data)` is `{ id, data, body, doc }` |
| `Spec` | nothing to import: the specs' examples, as `expect`s |

`roc test packages/markdown/main.roc` runs their `expect`s.

**The component is a `.rocx` file** (`components/Markdown.rocx`). It imports the platform's
`Html`, which a Roc package can't do for an app that is two apps (the server's and the browser's),
so `rocx build` copies it into the app, where `pf` is each half's own platform:

1. Name the package in the app's header (`main.roc`); `rocx build --client` gives the browser's
   copy the same:

   ```roc
   app [program] { markdown: "../packages/markdown/main.roc", pf: platform "…" }
   ```

2. `rocx build` writes the component to the app's `Generated/markdown/Markdown.roc`, and in a
   `.rocx` file, `import markdown.Markdown` imports that copy.

## `<Markdown>`

| Prop | |
|---|---|
| `source : Str` | the Markdown |
| `doc : List(Block)` | or the document, parsed already (to make a table of contents from the same parse) |
| `raw : [Escape, Drop]` | raw HTML in the source: shown as text (`Escape`, the default) or left out |
| `class : Str` | the class of the `<div>` it renders in: `"markdown"` unless you say |
| `heading : Markdown.Heading -> Html` | how a heading renders, given `{ level, id, text, children }`; `Markdown.heading` is `<h2 id="…">` |
| `code : Markdown.Code -> Html` | how a code block renders, given `{ lang, info, text }`; `Markdown.code` is `<pre><code class="language-…">` |
| `link : Markdown.Link -> Html` | how a link renders, given `{ url, title, children }`; `Markdown.link` |
| `image : Markdown.Image -> Html` | how an image renders, given `{ url, title, alt }`; `Markdown.image` |
| `footnote : Markdown.Footnote -> Html` | how a footnote's reference renders, given `{ number, href, id }` (`#fn-salt`, `fnref-salt`); `Markdown.footnote` is `<sup class="footnote-ref"><a …>1</a></sup>` |
| `notes : List(Markdown.Note) -> Html` | how the notes at the end render, given each one's `{ number, id, children, backs }` (`backs`: where each reference to it is, for links back); `Markdown.notes` is `<section class="footnotes"><ol>…</ol></section>` with `↩` links labelled in English |

Each hook is given what the node says, its children already rendered, so it decides only its own
element. Anchors beside headings:

```roc
<Markdown
	source={post.body}
	heading={|h| Html.element("h${h.level.to_str()}", [Html.attr("id", h.id)], [<a href={"#${h.id}"} class="anchor">#</a>].concat(h.children))}
/>
```

Outside links in a new tab, falling back on the default for the rest:

```roc
link={|l| if (l.url.starts_with("https://")) <a href={l.url} target="_blank" rel="noopener">{...l.children}</a> else Markdown.link(l)}
```

### Highlighting

`Markdown.highlight(lines)` is a `code` hook for any highlighter that gives a code block's lines as
tokens (`{ kind : Str, text : Str }`, `""` for plain text); a token with a kind is a
`<span class="t-kind">`, styled by your CSS. The site's `Highlight` (`site/Ui/Highlight.roc`) gives
exactly these:

```roc
<Markdown source={doc} code={Markdown.highlight(|text, lang| if (lang == "html") Highlight.lines(text, Markup) else Highlight.lines(text, Code))} />
```

PROPOSALS.md proposes moving it into a package of its own, so any app can.

## Footnotes

GitHub's: `[^label]` where the text refers to a note, and `[^label]: what it says` on a line of its
own, anywhere in the document; the note's further lines are indented four spaces (or continue its
paragraph), so a note may hold paragraphs, lists or code.

```markdown
A loaf keeps for days[^salt], longer in a cloth[^cloth].

[^salt]: About 2% of the flour's weight.
[^cloth]: Linen, not plastic.

    A second paragraph of the same note.
```

`Md.parse` numbers the notes in the order the text first refers to them, and puts them last in the
document, as a `Footnotes` block of `Block.Note`s (`{ label, number, refs, blocks }`); a reference
is an `Inline.Footnote` (`{ label, number, nth }`, `nth` saying which reference to its note it is).
A note nothing refers to is left out, and a reference to no note stays text, as on GitHub; labels
match without case. `Md.to_html` writes them as cmark-gfm does: `<sup class="footnote-ref"><a
href="#fn-salt" id="fnref-salt" data-footnote-ref>1</a></sup>`, then `<section class="footnotes"
data-footnotes>` with a link back (`↩`) to each reference. `<Markdown>` draws them through its
`footnote` and `notes` hooks, so a page gives the notes a heading in its own language:

```roc
notes = |found|
	<section class="notes" aria-labelledby="notes-title">
		<h2 id="notes-title">Przypisy</h2>
		<ol>{...found.map(|note| <li id={note.id}>{...note.children}{...note.backs.map(|href| <a href={href} aria-label="Wróć do tekstu">↩</a>)}</li>)}</ol>
	</section>

<Markdown source={post.body} notes={notes} />
```

`Md.footnotes(doc)` is the notes; `Md.footnote_id("salt")` and `Md.footnote_ref_id("salt", 2)` are
the anchors (`fn-salt`, `fnref-salt-2`). `Md.footnote_problems(source)` says what is wrong, for a
build's checks of what writers write: a reference to a note that isn't there, a note given twice,
and a note nothing refers to (`[^cloth] is a note nothing refers to`).

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
an earlier heading has it (`intro`, `intro-1`). Blocks and inlines compare with `==`.

## Frontmatter and collections

`Frontmatter.read` decodes a file's frontmatter into a record you declare, a nominal one so its
fields can have defaults (`??`); `parser_for : _` gives it the parser Roc writes for it. The type
says what each value is: `2026` is a number for a `U64` field and text for a `Str` one.

```roc
Post := { title : Str, date : Str, tags : List(Str) ?? [], draft : Bool ?? Bool.False }.{
	parser_for : _
}

match Frontmatter.read(source) {
	Ok({ data, body }) => …                     # data : Post
	Err(problem) => Yaml.describe(problem)     # "draft: expected true or false, found \"maybe\""
}
```

A missing field without a default, a value of the wrong kind, a tag the union hasn't, a key set
twice or a line indented wrong is an error that says which, and where.

A collection is a folder of such files. Until `rocx build` finds them for you (PROPOSALS.md), list
them yourself, each imported as text. Read in a top-level value, they are read when the app is
built, so a file whose frontmatter is wrong fails the build, naming the file and the field:

```roc
import markdown.Collection
import "content/posts/hello.md" as hello : Str
import "content/posts/second.md" as second : Str

Posts := [].{
	all : List(Collection.Entry(Post))
	all =
		match Collection.load([{ path: "hello.md", source: hello }, { path: "second.md", source: second }]) {
			Ok(entries) => entries.keep_if(|post| !post.data.draft)
			Err(failed) => crash Collection.describe(failed)   # "second: title is missing"
		}
}
```

An entry is `{ id, data, body, doc }`: `id` is its path without `.md` (`2026/hello`), `doc` its
body parsed.

The YAML is the part frontmatter uses: maps, lists (block and `[a, b]`), inline maps, plain and
quoted scalars, `|` and `>` block scalars, comments, and null (`~`, `null`, or nothing), which
leaves a field to its default. Not anchors, aliases, tags or several documents.

## In the browser

A page that renders `<Markdown>` puts the parser in the browser's wasm when it hydrates: about
225 KB (73 KB gzipped) on top of the page's own. Markdown that the server renders once and nothing
changes (a post, a docs page) belongs in `<NoHydration>`, which keeps the browser's copy out of the
wasm altogether:

```roc
<NoHydration>
	<Markdown source={post.body} />
</NoHydration>
```

A live preview is the other way: rendered again whenever what is typed changes, in a hole:

```roc
(draft!, set_draft!) = create_signal!("")
<textarea on:input.value={set_draft!}>{draft!()}</textarea>
{=Markdown.view({ source: draft!() })}
```

## Safety

Raw HTML (`<b>`, `<script>`, an HTML block) is escaped unless a renderer is told otherwise:
`raw={Drop}` leaves it out, and `Md.to_html_with(doc, { raw: Trusted })` writes it as it is (and
checks no URLs), for a source you wrote yourself. `<Markdown>` can't take trusted HTML: the
platform's `Html` has no way to put a string in a page as markup (see PROPOSALS.md).

A link's or an image's URL may be relative, or `http:`, `https:`, `mailto:` or `tel:`; anything
else (`javascript:`, `data:`, `vbscript:`, with tabs or line breaks hidden in it or not) becomes
`about:invalid#rocx-unsafe-url`, as every `href` the platform renders does.

## Status

Works today:

- The parser passes 649 of CommonMark 0.31.2's 652 examples; the other three are bare links
  (`https://…`, `www.…`, `someone@example.com`), which GitHub's extension makes links of and
  CommonMark leaves as text. Of GFM's extension examples, all but the tag filter pass
  (`raw: Trusted` writes HTML as it is). `Spec.roc` runs 202 of them.
- `<Markdown>`, its hooks and `Markdown.highlight`, built and type-checked in an app on both
  halves; the browser's wasm renders the same page as the server.
- Frontmatter into a record, typed collections listed by hand, and a bad file failing the build.

Waits on a proposal (PROPOSALS.md):

- Collections found by `rocx build`, without listing the files.
- Trusted raw HTML in `<Markdown>`.
- The site's highlighter in a package.
- A component that never hydrates without writing `<NoHydration>` around it.

## Limits, for now

- A reference's label is case folded for ASCII, Latin-1, Latin Extended-A, Greek, Cyrillic and
  `ß`, not all of Unicode; emphasis knows Unicode's punctuation by its main blocks.
- No heading attributes (`{#id}`), smart quotes or math.
- A footnote's label has no spaces or brackets in it; references inside a note number the notes
  they refer to after the text's.
