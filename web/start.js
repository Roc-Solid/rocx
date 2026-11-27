// The bootstrap the server puts before a page's `</body>`
// (`<script type="module" data-rocx src="/rocx/start.js">`): it loads the runtime and the app's
// wasm, hydrates the document the server rendered (`runtime.hydrateDocument`), and tells the page,
// dispatching `rocx:ready` on the document with `{ runtime, ms }` (`ms`: how long hydrating took).
//
// Everything is beside this file, so the site may be served under a path of its own: at
// example.github.io/rocx/ this is /rocx/rocx/start.js, the runtime /rocx/rocx/runtime.js, the wasm
// /rocx/rocx/app.wasm, and the base, the directory above, /rocx/. The runtime asks for the URLs Roc
// gives (endpoints, fetches, streams) under that base, and `Router.location!` takes it off
// the page's path.
//
// A page that sets `window.rocxStrict = true` before this runs (the tests do) hydrates strictly: a
// page that isn't what the app renders throws, instead of rendering `<body>` again with a warning,
// and an extension's elements aren't passed over (D-112). So does a browser whose localStorage says
// so, to look into such a page in one's own browser: `localStorage.setItem("rocx:strict", "1")`.
const wasm = fetch(new URL("app.wasm", import.meta.url));
const { Runtime } = await import(new URL("runtime.js", import.meta.url).href);
const runtime = await Runtime.load(wasm, { base: new URL("..", import.meta.url).pathname });
const started = performance.now();
let strict = globalThis.rocxStrict === true;
try {
	strict ||= localStorage.getItem("rocx:strict") === "1";
} catch {}
runtime.hydrateDocument(document, { strict });
document.dispatchEvent(new CustomEvent("rocx:ready", { detail: { runtime, ms: performance.now() - started } }));
