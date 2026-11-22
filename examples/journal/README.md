# journal: Acme Journal

A small publication in two languages, English and Polish. Its posts are Markdown files in
`content/`, its pages are rendered once on the server, and two small islands run in the browser:
search as you type, and reactions under each post. It needs no database. The posts are compiled
into the server, and the reactions are kept in the server's memory (`Kv`).

## A tour

- **`/`** sends you to `/en` or `/pl`, whichever your browser asks for first (`Accept-Language`).
- **`/en`** is the latest writing, newest first, four posts to a page (`/en/page/2`, `/en/page/3`),
  each a card with its cover, day, reading time, writer, summary and tags. The masthead has the
  sections, a search form and the language switcher. The footer has the feed, the JSON API and
  the sitemap.
- **A post** (`/en/posts/slow-bread`) has its tags, title, summary, writer, day and reading time,
  and a link to its translation ("Czytaj po polsku →"). Then come its cover, a table of contents
  beside the text (above it on a narrow screen), the body (tables, code, images with captions,
  footnotes with links back) and its notes. Below the body is a row of reactions (👏 ❤️ 💡 😄) that
  answer your click at once, then the newer and older posts.
- **The switcher** keeps you on the same post when it has a translation (`/en/posts/night-trains`
  ⇄ `/pl/posts/night-trains`). When it doesn't, it takes you to the other language's front page
  (an English-only post) or its tags (a tag only one language uses).
- **`/en/tags`**, **`/en/tags/code`** and **`/en/authors/theo-marsh`** list every tag, a tag's posts,
  and a writer with their bio and posts.
- **`/en/search`** filters titles and tags on every key and marks the matching letters. Polish
  marks don't matter there, so `plywow` finds *pływów*. Without JavaScript it is a plain form, and
  the server renders the results for `?q=`.
- **A wrong address** (`/en/posts/no-such-post`, `/pl/posts/rain-sounds`, `/de`) is a 404 in the
  address's language.
- **For programs**: `/en/feed.xml` and `/pl/feed.xml` (Atom, every post whole), `/sitemap.xml` (every
  page with its `hreflang` alternates), `/api/posts?lang=pl&tag=kuchnia&q=…`,
  `/api/posts/en/slow-bread` (one post with its HTML and table of contents), and
  `/openapi.html` (the API in Scalar) beside `/openapi.json`.
- **Light and dark** follow the system. Printing gives black on white: the reading column alone,
  without the masthead's controls, the reactions or the table of contents, and each link's address
  written after it.

The 19 posts were written for this example: 10 in English and 9 in Polish, eight of them
translations. They cover sourdough timings, pocket notebooks, shell scripts, tide tables, night
trains, truing a wheel, reading JSON, a winter garden, rain sounds, the journal's own colophon and a
Polish-only Sunday of pierogi. Their writers, Iris Vale, Hanna Wierzba and Theo Marsh, are made up.

## What it shows

| Feature | Where |
|---|---|
| A collection with typed frontmatter (packages/markdown's `Collection`, `Frontmatter`): title, date, writer, tags, summary, optional cover and its description; a translation is the file of the same name in the other language's folder | `Post.roc`, `Posts.roc` |
| Content rules a type can't say: a real day, a known writer, one to five slug tags, a described cover, no `#` headings in the body, every footnote with its note and every note used (`Md.footnote_problems`), a translation by the same writer. A wrong post fails the build, with every problem named | `Rules.roc` (its expects), `Posts.all`, `test/content.test.mjs` |
| `<Markdown>` with hooks: heading anchors, labelled code blocks in a scroll of their own, images as captioned figures, packages/markdown's footnotes as superscripts and notes under a heading in the post's language (`footnote` and `notes` hooks); the typography through `:global(…)` under a scoped `.prose` | `Ui/Prose.rocx` |
| Reading time, table of contents, previous and next posts | `Posts.roc` (`minutes`, `newer`, `older`), `Ui/Toc.rocx`, `Ui/Article.rocx` |
| Index with pagination; tag, tags and writer pages; generated `Paths` for every link | `Ui/Listings.rocx`, `Ui/Pagination.rocx`, `routes/[lang]/…` |
| 404 through `+error.rocx`, and the same component for a post, tag or writer that isn't there (`<HttpStatusCode code={404} />`) | `routes/+error.rocx`, `Ui/NotFound.rocx` |
| packages/intl: dates ("February 14, 2026" / "14 lutego 2026"), numbers, plurals ("5 min read" / "5 minut czytania", "2 wpisy" / "12 wpisów"), and every interface word in both languages | `I18n.roc` (its expects check the catalog and the plurals) |
| The locale in the URL; `<html lang>` from the address; the switcher and `hreflang` alternates that know which posts are translated | `routes/+layout.rocx`, `Links.roc`, `Ui/Masthead.rocx` |
| Atom feeds, the sitemap with `hreflang` alternates: `+server.roc` files answering with `respond!`, in directories named for the file (`feed.xml`, `sitemap.xml`) | `routes/[lang]/feed.xml/+server.roc`, `routes/sitemap.xml/+server.roc`, `Xml.roc` |
| A JSON API of posts, typed, with its OpenAPI document and Scalar page, opted in through `App.program({ openapi: Page(Scalar) })` | `routes/api/posts/…`, `Listing.roc`, `main.roc` |
| Mostly static pages: everything but the islands inside `<NoHydration>` (the posts and the Markdown parser stay out of the wasm), `<Title>` set from inside it | every page in `routes/`, `routes/+layout.rocx` |
| Island 1, search as you type: a signal and a memo over the JSON API's answer, read as the page renders and carried in it, so typing asks the server nothing. The results reuse the server's pure `PostCard` | `Ui/SearchBox.rocx`, `Search.roc`, `Ui/PostCard.rocx` |
| Island 2, reactions: optimistic through `use_action!` and `use_submissions!` (the server's tally with the toggles on their way applied, `Reaction.apply`), refusals shown and dismissable; each button also a plain form for no JavaScript (`on:click.prevent`) | `Ui/ReactionBar.rocx`, `Reaction.roc` |
| `Kv` with atomic operations: counters (`increment!`), a reader's mark that one request alone sets (`add!`) or takes back (`take!`), and idempotent seeding (`add!` of each counter's seed) | `Reactions.roc` |
| packages/guard: a rate limit on sending reactions (20 a minute a reader, 429 with `Retry-After`), and the security headers (CSP) on every answer | `Middlewares.roc`, `routes/api/posts/[lang]/[slug]/reactions/+server.roc`, `Guard.roc` |
| Middleware: same-origin writes, the reader cookie in the context | `Middlewares.roc` |
| Scoped styles for each component; tokens and base in `static/journal.css` (light and dark); a print stylesheet (`static/print.css`, and `@media print` in the components) | `Ui/*.rocx`, `static/` |
| Pure `view` components (cards, lists, the article) and effectful `view!` ones (the islands, and `NotFound`, which sets the status) | `Ui/` |
| Stories for the components (`rocx build --dev`, `/__rocx/stories`) | `<story>` in `Ui/*.rocx` |

## Build and run it

From the repository's root, after `just setup` (the toolchain) and `just test` once (it builds the
platforms' hosts; `node server/build.mjs` builds the server's alone):

```sh
bin/rocx build examples/journal --client examples/journal/build/client
.tools/roc-active build --target=wasm32 --opt=size --output=examples/journal/build/client/static/rocx/app.wasm examples/journal/build/client/main.roc
node server/build.mjs examples/journal/main.roc examples/journal/build/journal
examples/journal/build/journal --port 18140 --host 127.0.0.1 --static examples/journal/build/client/static --static examples/journal/static
```

Then open http://localhost:18140. The feeds and the sitemap use whole URLs, taken from the request's
`Host`, or from `ORIGIN` when it is set (`ORIGIN=https://journal.example.com`). No database is
needed. Without a database, the rate limit's tallies stay in memory as well. With one
(`--database-url`), guard's actors write them to Postgres.

A new post is a Markdown file in `content/en/` or `content/pl/`, plus two lines in `Posts.roc` (its
`import` and its entry in `files`). A build tells you what is wrong with it.

## Test it

```sh
bin/rocx build examples/journal
bin/rocx check -- .tools/roc-active test examples/journal/main.roc   # the expects
node --test 'examples/journal/test/*.test.mjs'                        # HTTP, browser, content
```

- **Expects** (with the packages' own: 956 in all) cover the content rules (`Rules.roc`): frontmatter,
  footnotes, reading time and slugs. They also cover the catalog and the plurals in both languages
  (`I18n.roc`), search folding, matching and marking (`Search.roc`), the optimistic `apply` and the
  seeds (`Reaction.roc`), the XML and its escaping (`Xml.roc`), the links between languages
  (`Links.roc`), and the pure components through `testing.Dom` (`PostCard`, `Pagination`, `Prose`
  with its footnotes).
- **`test/http.test.mjs`** (15 tests) asks the server as a browser and as other programs do. It
  covers the redirect from `/`, each language's index and pages, dates and plurals, a post's parts,
  the switcher, tag and writer pages, every kind of 404, both feeds and the sitemap (well-formed XML,
  checked by `wellFormed` in `test/journal.mjs`), the JSON API, OpenAPI and its page, search without
  JavaScript, and reactions: counted once, taken back, refused when wrong (400, 403, 404), posted as
  a plain form, and rate limited (429).
- **`test/browser.test.mjs`** (2 tests) uses headless Chromium. It types into the search, with
  strict hydration and nothing fetched, then clicks a reaction: it shows at once, the server keeps
  it across a reload, and a second click takes it back. Both skip when there is no Chromium.
- **`test/content.test.mjs`** (4 tests) copies the journal, breaks one post at a time, and checks
  that `roc check` refuses it, naming the file and each problem.

The test files build the app themselves (`buildForTests`, taking turns through a lock in `build/`)
and start the server on a free port. They don't use `DATABASE_URL`.

## Product calls

- **Translations by file name.** One slug, shared across languages (`content/pl/slow-bread.md`), so
  URLs are `/pl/posts/slow-bread` and not localized slugs. It's simple to see and check. Tags are
  translated (`kuchnia`, not `kitchen`), so a tag page's other-language link falls back to that
  language's tags.
- **Reactions are shared by a post's translations**, counted per slug. A reader gives each kind
  once and can take it back, as GitHub's reactions work, rather than clapping without end. Counts
  start at a small seed, the same for the same post each time, so the first run looks read.
  Memory only: a restart starts them again, which is acceptable for a friendly gesture.
- **A reader is a cookie** (`reader`, random, HttpOnly, a year), given by the first page. Reactions
  are remembered and rate limited by it, and a reaction sent without one is refused (403). See
  "the client's address" below.
- **Search lives on its own page.** The masthead's search is a plain form to it, so the posts' index
  is carried only in the page that needs it.
- **No code highlighting**: code blocks are labelled with their language and scroll on their own.
  The site's highlighter isn't a package yet.
- **No webfonts**: system serif and sans stacks (Iowan Old Style, Charter, Georgia; system UI), so
  nothing is fetched from elsewhere and the CSP stays `'self'`.

## What it asked of the platform

Every gap met, and what the journal does about it. Four were fixed in the platform while it was
built: a route's directory may now name a file (`routes/sitemap.xml/`); packages/markdown parses
footnotes; packages/testing's `click()` scrolls instantly, so it no longer misses on a page with
`scroll-behavior: smooth`; and a `<For>` or `<Show>` may sit in a function child (the reactions'
`<For>` is in their `<Show>`'s child). These are still open:

1. **Collections aren't found by `rocx build`** (packages/markdown's PROPOSALS.md). Each post is
   imported as text and listed in `Posts.files`.
2. **guard's middleware is copied by hand** (packages/guard's PROPOSALS.md, "Server-only modules in
   packages"). `Guard.roc`, `FlagStore.roc` and `Kept.roc` are verbatim copies of
   `packages/guard/server/`. Its tallies are actors' state, not `Kv` yet ("Memory: state between
   requests"). With a database, each limited request writes to Postgres.
3. **The client's address isn't passed on** (guard's "The client's address"). `Guard.ip(Direct)` can't
   tell readers apart, and `Hops(1)` reads a header any client can write when there is no proxy.
   The limit counts by the reader cookie (`Guard.user(|c| c.reader, Hops(1))`), and a reaction
   without the cookie is refused.
4. **A page whose params are read only inside `<NoHydration>` doesn't build for the browser.** The
   browser's copy drops `<NoHydration>`'s children, so `params` is unused. Roc warns, exits 2, and
   `buildForTests` throws. Every page reads its params outside it too, in its `<Title>` or an
   island's props. `<Title>` and `<HttpStatusCode>` work from inside `<NoHydration>`, which is how a
   post's title and a missing post's 404 are set.
5. **`<HttpStatusCode>` is effectful**, so a component that sets the status is a `view!`
   (`Ui/NotFound.rocx`). Pure callers still write `<NotFound … />`, and rocx wraps it.
6. **guard's CSP refuses the OpenAPI page**, which loads Scalar from jsDelivr. `Middlewares.security`
   leaves `/openapi.html` out, and every other answer has the headers.
7. **`node --test examples/journal/test/` fails on Node 24**: a directory is taken as a module
   ("Cannot find module"). Use the glob, `node --test 'examples/journal/test/*.test.mjs'`.
8. **The OpenAPI document gives the reactions' `POST` a JSON body only**, though the endpoint takes
   the same fields as a form, which is what the no-JavaScript buttons send (server/README.md, "Not
   yet").
9. **The browser's copy of `Api` has no types** (known, D-030). The search's `posts` and the
    reactions' `toggles : Submissions(Reaction.Toggle, Reaction.Tally)` are annotated.
10. **The Roc gotchas met:**
    - `{ lang }` alone is a block, not a record (`Paths.lang({ lang: lang })`).
    - A parameter can't share a name with a member of its type's block (hence `Rules.of_title`, …).
    - `join_with` is `Str.join_with(list, sep)`, not a method of a list.
    - A `map_ok` can't take an effectful lambda (read `pending_inputs!()` first).
    - A top-level crash is a compile-time error with its message, which is how a wrong post fails
      the build.
