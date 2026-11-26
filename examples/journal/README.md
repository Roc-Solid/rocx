# Journal

A small publication in two languages, English and Polish. Its posts are Markdown files in
`content/`, compiled into the server. The server renders the pages, and two small islands run in
the browser: search as you type, and reactions under each post. It needs no database: the reactions
are kept in the server's memory (`Kv`).

Read it to see a Markdown collection with typed frontmatter, two languages with packages/intl,
feeds and a sitemap, a typed JSON API with its OpenAPI page, and pages that are mostly
server-rendered, with only the islands hydrated.

## Run it

From the repository's root, after `just setup`:

```sh
cd examples/journal
../../bin/rocx dev    # http://localhost:8080
```

`rocx dev` builds the app, serves it under `--dev` with the journal's own files in `static/` (its
stylesheets and images), and builds it again each time you save. That includes the posts: a new
post is a new Markdown file in `content/en/` or `content/pl/`, and nothing else. A post that breaks
a content rule fails the build, which names the file and each problem.

The feeds and the sitemap need whole URLs. They take them from the request's `Host`, or from
`ORIGIN` when it is set (`ORIGIN=https://journal.example.com ../../bin/rocx dev`).

### Build it by hand

To build each piece yourself, run these from the repository's root. The browser's wasm is
optimized for size here, as the docs' examples page measures it:

```sh
just web-host     # the browser platform's host, once (rocx dev builds it too)
bin/rocx build examples/journal --client examples/journal/build/client
.tools/roc-active build --target=wasm32 --opt=size --output=examples/journal/build/client/static/rocx/app.wasm examples/journal/build/client/main.roc
node server/build.mjs examples/journal/main.roc examples/journal/build/journal
examples/journal/build/journal --port 18140 --static examples/journal/build/client/static --static examples/journal/static
```

Then open http://localhost:18140.

## A tour

- **`/`** sends you to `/en` or `/pl`, whichever your browser asks for first (`Accept-Language`).
- **`/en`** is the latest writing, newest first, four posts to a page (`/en/page/2`, `/en/page/3`).
  Each post is a card with its cover, day, reading time, writer, summary and tags. The masthead has
  the sections, a search form and the language switcher. The footer links the feed, the JSON API's
  page and the sitemap.
- **A post** (`/en/posts/slow-bread`) shows its tags, title, summary, writer, day and reading time,
  and links to its translation ("Czytaj po polsku →"). Then come its cover, a table of contents
  beside the text (above it on a narrow screen), the body (tables, code, images with captions,
  footnotes with links back) and its notes. Below the body are four reactions (Applause, Love it,
  Made me think, Made me smile), which answer a click at once, then the newer and older posts.
- **The switcher** keeps you on the same post when it has a translation (`/en/posts/night-trains`
  and `/pl/posts/night-trains`). When it has none, the switcher takes you to the other language's
  front page (for an English-only post) or its tags page (for a tag only one language uses).
- **`/en/tags`**, **`/en/tags/code`** and **`/en/authors/theo-marsh`** list every tag, a tag's
  posts, and a writer with their bio and posts.
- **`/en/search`** filters titles and tags on every key, and marks the matching letters. Polish
  marks don't matter there, so `plywow` finds *pływów*. Without JavaScript it is a plain form, and
  the server renders the results for `?q=`.
- **Follow any link**: the next page renders without a full load.
- **A wrong address** (`/en/posts/no-such-post`, `/pl/posts/rain-sounds`, `/de`) is a 404 page in
  the address's language.
- **For programs**: `/en/feed.xml` and `/pl/feed.xml` (Atom, every post whole), `/sitemap.xml`
  (every page with its `hreflang` alternates), `/api/posts?lang=pl&tag=kuchnia&q=…`,
  `/api/posts/en/slow-bread` (one post, with its HTML and table of contents), and `/openapi.html`
  (the API in Scalar) beside `/openapi.json`.
- **Light and dark** follow the system. Printing gives black on white: the reading column alone,
  without the masthead's controls, the reactions or the table of contents, and with each link's
  address written after it.

The 19 posts were written for this example: 10 in English and 9 in Polish, eight of them
translations. They cover sourdough timings, pocket notebooks, shell scripts, tide tables, night
trains, truing a wheel, reading JSON, a winter garden, rain sounds, the journal's own colophon, and a
Polish-only Sunday of pierogi. Their writers, Iris Vale, Hanna Wierzba and Theo Marsh, are made up.

## What it shows

Each row names a feature and the file to read for it. Paths are from `examples/journal/`.

### Content

| Feature | Where |
|---|---|
| A collection with typed frontmatter (packages/markdown's `Collection`): title, date, writer, tags, summary, and an optional cover with its description. A translation is the file of the same name in the other language's folder | [`Post.roc`](Post.roc), [`Posts.roc`](Posts.roc), [`content/`](content) |
| `rocx build` finds the files and writes a module for each folder (`Generated/Content/En`, `Generated/Content/Pl`), so a new post is a new file | [`Posts.roc`](Posts.roc) |
| Content rules a type can't say: a real day, a known writer, one to five slug tags, a described cover, no `#` headings in the body, every footnote with its note and every note used (`Md.footnote_problems`), a translation by the same writer. `Posts.all` checks them as the app compiles and crashes on a problem, so a wrong post fails the build with every problem named | [`Rules.roc`](Rules.roc) (with expects), [`Posts.roc`](Posts.roc) (`all`), [`test/content.test.mjs`](test/content.test.mjs) |
| `<Markdown>` with hooks: heading anchors, labelled code blocks that scroll on their own, images as captioned figures, footnotes as superscripts and notes under a heading in the post's language. The typography reaches the elements `<Markdown>` makes through `:global(…)` under a scoped `.prose` | [`Ui/Prose.rocx`](Ui/Prose.rocx) |
| Reading time, a table of contents, and the newer and older posts | [`Posts.roc`](Posts.roc) (an entry's `minutes`, `newer`, `older`), [`Ui/Toc.rocx`](Ui/Toc.rocx), [`Ui/Article.rocx`](Ui/Article.rocx) |
| An index with pages; tags, tag and writer pages; generated `Paths` for every link | [`Ui/Listings.rocx`](Ui/Listings.rocx), [`Ui/Pagination.rocx`](Ui/Pagination.rocx), [`routes/[lang]/`](routes/[lang]) |

### Two languages

| Feature | Where |
|---|---|
| packages/intl: dates ("February 8, 2026", "8 lutego 2026"), numbers, plurals ("5 min read", "5 minut czytania"; "12 wpisów"), and every interface word in both languages. The expects check the catalog and the plurals | [`I18n.roc`](I18n.roc) |
| The language in the URL (`routes/[lang]/…`), and `<html lang>` computed from the address | [`routes/+layout.rocx`](routes/+layout.rocx) |
| The switcher and the `hreflang` alternates, which know which posts are translated | [`Links.roc`](Links.roc), [`Ui/Masthead.rocx`](Ui/Masthead.rocx) |
| `/` redirected by `Accept-Language`, in a route that answers with a whole response (`respond!`) | [`routes/+server.roc`](routes/+server.roc) |
| A 404 page in the address's language, for a path no route has and for a post, tag or writer that isn't there (one component, with `<HttpStatusCode code={404} />`) | [`routes/+error.rocx`](routes/+error.rocx), [`Ui/NotFound.rocx`](Ui/NotFound.rocx) |

### Pages and islands

| Feature | Where |
|---|---|
| Pages rendered by the server alone: everything but the islands is inside `<NoHydration>`, so the posts and the Markdown parser stay out of the browser's wasm. A post's `<Title>` is set from inside it | every page in [`routes/`](routes), [`routes/+layout.rocx`](routes/+layout.rocx) |
| Island 1, search as you type: a signal (what is typed) and a memo (the results) over the JSON API's answer. The page reads the API once as the server renders it and carries the answer in the page, so typing asks the server nothing. The results reuse the server's pure `PostCard` | [`Ui/SearchBox.rocx`](Ui/SearchBox.rocx), [`Search.roc`](Search.roc), [`Ui/PostCard.rocx`](Ui/PostCard.rocx) |
| Island 2, reactions. A click sends an action (`use_action!`) and shows at once: the counts shown are the server's, with the toggles still on their way applied (`use_submissions!`, `Reaction.apply`). Refusals show, and can be dismissed. Each button is also a plain form, for no JavaScript; with it, `on:click.prevent` takes the click over | [`Ui/ReactionBar.rocx`](Ui/ReactionBar.rocx), [`Reaction.roc`](Reaction.roc) |
| Pure `view` components (cards, lists, the article) and effectful `view!` ones (the islands, and `NotFound`, which sets the status) | [`Ui/`](Ui) |
| Stories for the components, at `/__rocx/stories` in a dev build | `<story>` in [`Ui/*.rocx`](Ui) |
| Scoped styles for each component; the tokens and base styles in `static/journal.css` (light and dark); a print stylesheet (`static/print.css`, and `@media print` in the components) | [`Ui/*.rocx`](Ui), [`static/`](static) |

### The server

| Feature | Where |
|---|---|
| Atom feeds and a sitemap: `+server.roc` files that answer with `respond!`, in directories named for the file they serve (`feed.xml`, `sitemap.xml`) | [`routes/[lang]/feed.xml/+server.roc`](routes/[lang]/feed.xml/+server.roc), [`routes/sitemap.xml/+server.roc`](routes/sitemap.xml/+server.roc), [`Xml.roc`](Xml.roc) |
| A typed JSON API of posts, with its OpenAPI document and Scalar page, turned on with `App.program({ openapi: Page(Scalar) })` | [`routes/api/posts/`](routes/api/posts), [`Listing.roc`](Listing.roc), [`main.roc`](main.roc) |
| `Kv` with atomic operations: counters (`increment!`), a reader's mark that only one request can set (`add!`) or take back (`take!`), and seeding that is safe to repeat (`add!` of each counter's seed) | [`Reactions.roc`](Reactions.roc) |
| A middleware around every request (`routes/+middleware.roc`): the `reader` cookie, given on a first page, in every handler's `context`; writes from other sites are refused by the platform | [`Middlewares.roc`](Middlewares.roc), [`routes/+middleware.roc`](routes/+middleware.roc) |
| packages/guard: security headers (a CSP) on every answer, and a rate limit on sending reactions (20 a minute a reader, then 429 with `Retry-After`), its counts in `Kv`. The limit is the reactions' directory's middleware (its `+middleware.roc`: `middleware = Middlewares.reactions_limit`) | [`Middlewares.roc`](Middlewares.roc), [`routes/api/posts/[lang]/[slug]/reactions/+middleware.roc`](routes/api/posts/[lang]/[slug]/reactions/+middleware.roc) |

## Test it

```sh
just examples journal                                               # build, type-check, lint, check the SQL, run the expects and the tests
bin/rocx check examples/journal                                     # build, then type-check both programs
bin/rocx check -- .tools/roc-active test examples/journal/main.roc  # the expects (after a build)
node --test 'examples/journal/test/*.test.mjs'                      # HTTP, browser, content
```

- **The expects** cover the content rules (`Rules.roc`: frontmatter, footnotes, reading time,
  slugs), the catalog and the plurals in both languages (`I18n.roc`), search folding, matching and
  marking (`Search.roc`), the optimistic `apply` and the seeds (`Reaction.roc`), the XML and its
  escaping (`Xml.roc`), and the links between languages (`Links.roc`). They also render the pure
  components through packages/testing's `Dom` (`PostCard`, `Pagination`, and `Prose` with its
  footnotes).
- **[`test/http.test.mjs`](test/http.test.mjs)** asks the server what a browser and other programs
  ask. It covers the redirect from `/`, each language's index and pages, dates and plurals, a post's
  parts, the switcher, tag and writer pages, every kind of 404, both feeds and the sitemap (checked
  to be well-formed XML), the JSON API, OpenAPI and its page, and search without JavaScript. For
  reactions, it checks that each is counted once, can be taken back, is refused when wrong (400,
  403, 404), works as a plain form, and is rate limited (429).
- **[`test/browser.test.mjs`](test/browser.test.mjs)** uses headless Chromium, and skips when there
  is none. It types into the search, with strict hydration and nothing fetched. Then it clicks a
  reaction: the reaction shows at once, the server keeps it across a reload, and a second click
  takes it back.
- **[`test/content.test.mjs`](test/content.test.mjs)** copies the journal, breaks one post at a
  time, and checks that the build refuses it, naming the file and each problem.

The test files build the app themselves, taking turns through a lock in `build/`
([`test/journal.mjs`](test/journal.mjs)), and start the server on a free port.

## Product calls

- **Translations by file name.** A post has one slug, shared by its languages
  (`content/pl/slow-bread.md`), so URLs are `/pl/posts/slow-bread`, not localized slugs. That is
  simple to see and to check. Tags are translated (`kuchnia`, not `kitchen`), so a tag page's link
  to the other language falls back to that language's tags.
- **Reactions are shared by a post's translations**, counted per slug. A reader gives each kind
  once and can take it back, as with GitHub's reactions, rather than clapping without end. Counts
  start at a small seed, the same for the same post each time, so the first run looks read. They
  are kept in memory only: a restart starts them again, which is acceptable for a friendly gesture.
- **A reader is a cookie** (`reader`: random, HttpOnly, kept a year), given by the first page.
  Reactions are remembered and rate limited by it. A request without one is rate limited by the
  connection's address, and a reaction sent without one is refused (403).
- **Search lives on its own page.** The masthead's search is a plain form that goes there, so the
  posts' index is carried only in the page that needs it.
- **No code highlighting.** Code blocks are labelled with their language and scroll on their own.
  The docs site's highlighter isn't a package yet.
- **No webfonts.** System serif and sans stacks (Iowan Old Style, Charter, Georgia; system UI), so
  nothing is fetched from elsewhere and the CSP stays `'self'`.

## What it asked of the platform

Building the journal showed what the platform didn't do yet. Most of it has been fixed since: a
route's directory may name a file (`routes/sitemap.xml/`), packages/markdown parses footnotes,
`rocx build` finds a content folder's files, a request carries its connection's address
(`request.peer`), and guard keeps its state in `Kv` and is imported as a package. What remains, and
what the journal does about it:

1. **`<HttpStatusCode>` is effectful**, so a component that sets the status is a `view!`
   (`Ui/NotFound.rocx`). Pure callers, such as `Listings.missing`, still write `<NotFound … />`,
   and rocx wraps it.
2. **guard's CSP refuses the OpenAPI page**, which loads Scalar from jsDelivr.
   `Middlewares.security` leaves `/openapi.html` out; every other answer has the headers.
3. **`node --test examples/journal/test/` fails on Node 24**: it takes the directory as a module
   ("Cannot find module"). Use the glob, `node --test 'examples/journal/test/*.test.mjs'`.
4. **Roc, met on the way:**
    - `{ lang }` alone is a block, not a record: write `Paths.lang({ lang: lang })`.
    - A parameter can't share a name with a member of its type's block (hence `Rules.of_title`
      and the like).
    - It is `Str.join_with(list, sep)`, not a method of a list.
    - A `map_ok` can't take an effectful lambda: read `pending_inputs!()` first, as
      `Ui/ReactionBar.rocx` does.
    - A top-level `crash` is a compile-time error with its message, which is how a wrong post
      fails the build.
