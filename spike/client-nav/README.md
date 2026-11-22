# Client-side navigation: the design and its spike

`DESIGN.md` is the design (D-040, Proposed): what navigates in place, what a navigation does, the
API with Solid Router's beside it, the generated code, a phased plan, and the questions for the
user. Nothing in it is built.

## The spike: what a navigation would download (`measure.mjs`)

The question: should a navigation fetch the page's own HTML document, as the server answers it
(and as `just site` writes it), or a JSON of only what the browser can't make itself (the
answers, the `<NoHydration>` regions, the title)? The script measures both for every page of a
static copy of the site, raw and with brotli (quality 11, as the site's facts are):

```sh
node spike/client-nav/measure.mjs site/dist     # after `just site`
```

On the docs site as `just site` wrote it on 2026-11-21 (22 pages):

| | HTML document | JSON (answers, regions, title) |
|---|---|---|
| all pages, brotli | 448.9 KB | 424.4 KB |
| per page, brotli | 13.1–39.2 KB | 12.1–33.9 KB |
| ratio, per page | 1.02–1.16× | 1 |

And the parts of three pages (raw, then brotli):

| page | the app's stylesheet (a region in `<head>`) | `<body>`'s regions | answers | the rest (markup the wasm makes) |
|---|---|---|---|---|
| `/` | 77.3 KB, 11.7 KB br | 13.8 KB, 2.0 KB br | 1.0 KB | 3.6 KB, 1.0 KB br |
| `/platform` | 77.3 KB, 11.7 KB br | 14.6 KB, 3.5 KB br | 0.5 KB | 4.9 KB, 1.2 KB br |
| `/syntax` | 77.3 KB, 11.7 KB br | 74.0 KB, 7.0 KB br | 0.5 KB | 13.8 KB, 2.6 KB br |

What it proved:

- The document costs 2–16% more than the smallest JSON could (1–2.6 KB brotli a page): the markup
  the wasm could have made itself. Everything else the browser needs from the server either way,
  since the regions' code isn't in the wasm. So the design fetches the document, which needs no
  server change and works on a static host as it is (DESIGN.md §4.1).
- The largest part of every page, and so of every navigation, is the app's stylesheet
  (`Styles.style`, in a `<NoHydration>` in `<head>`): 11.7 KB brotli of a 13–17 KB page. Served as a
  file the browser caches, it would leave every load and every navigation (DESIGN.md §8, question 9).
