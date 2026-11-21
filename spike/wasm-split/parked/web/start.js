// The bootstrap the server puts before a page's `</body>`
// (`<script type="module" data-rocx src="/rocx/start.js">`): it loads the runtime and the app's
// wasm, hydrates the document the server rendered (`runtime.hydrateDocument`), and tells the page,
// dispatching `rocx:ready` on the document with `{ runtime, ms }` (`ms`: how long hydrating took).
//
// Everything is beside this file, so the site may be served under a path of its own: at
// example.github.io/rocx/ this is /rocx/rocx/start.js, the runtime /rocx/rocx/runtime.js, the wasm
// /rocx/rocx/app.wasm, and the base, the directory above, /rocx/. The runtime asks for the URLs Roc
// gives (server functions, fetches, streams) under that base, and `Router.location!` takes it off
// the page's path.
//
// A page that sets `window.rocxStrict = true` before this runs (the tests do) hydrates strictly: a
// page that isn't what the app renders throws, instead of rendering `<body>` again with a warning.
//
// A split app (`rocx build --split`) has a chunk per page beside app.wasm (`app.<Page>.wasm`): the
// server names the page's as preloads (`<link rel="preload" data-rocx-chunk="…">`), which are in
// before hydrating; any other is fetched when the app first calls into it.
const here = import.meta.url;
const wasm = fetch(new URL("app.wasm", here));
const { Runtime } = await import(new URL("runtime.js", here).href);
const preload = [...document.querySelectorAll("link[data-rocx-chunk]")].map((link) => link.getAttribute("data-rocx-chunk"));
const strict = globalThis.rocxStrict === true;
const runtime = await Runtime.load(wasm, { base: new URL("..", here).pathname, chunk: (owner) => fetch(new URL(`app.${owner}.wasm`, here)), preload, strict });
const started = performance.now();
runtime.hydrateDocument(document, { strict });
document.dispatchEvent(new CustomEvent("rocx:ready", { detail: { runtime, ms: performance.now() - started } }));
