# Design: iOS and Android apps from the same .rocx files (D-063, Proposed)

> **Status (2026-11-23):** the Android spike is built, on branch `nxy7/native-android`: one screen
> (`spike/native-apps/phone-hello`) runs as native Android views on the emulator, with typed calls
> to the server, and the same `.rocx` in a browser. What was built, how to run it, its
> measurements and gaps are in [README.md](README.md); §13 says where it sits in the phases, and §16
> where the build went otherwise than this design said, and why. An Expo-like dev mode followed
> (`rocx dev --android`: a dev client that loads each build's library, about a second from a save
> to the phone; README.md, Dev mode). In master since 2026-11-24, as an experiment (opt-in).

> A design spike, 2026-11-23, on master at 56221d2. The web stays the
> primary target; this is background work, and nothing in it may slow the web down or change what
> a web app writes. The user's direction: "keep Web as primary target and in the background work on
> getting Android and iOS into a place where they can be usable", the Lynx approach (HTML and CSS
> rendered as native views), and "no JS, so our own renderer".
>
> **The user's answers (2026-11-23).** Build it as a spike in a workspace of its own. For now:
> (1) a native Android platform, (2) typesafe communication with the server, the same as the web's,
> (3) one simple screen, nothing fancier. Android comes first, not iOS. Question 1: CSS and tags a
> phone can't do only warn and are ignored; never fail the build. Question 2: as recommended (the
> app draws its own header; native back gestures). Question 4: page guards are ignored for now.
> The other questions are open until the spike meets them.

## 0. In short

The same app, its `.rocx` files unchanged, also builds as an iOS app and an Android app whose
screens are real native views (`UIView`s, Android `View`s), not a web page in a WebView, and with
no JavaScript engine anywhere. It talks to the same rocx server the browser does.

What makes this possible is already true: a component's markup reaches its host as JSON, and every
hole is a box the host keeps and runs (`web/platform/Host.roc` has no DOM operation in it). Today
two hosts read that JSON: `web/runtime.js` in the browser (the reactive engine plus the DOM) and
`server/host/src/signals.rs` on the server (render once, no tracking). A phone gets a third host:

```
.rocx ──rocx build──► Generated/*.roc ──roc──► wasm32  + web/runtime.js   (browser, as today)
                                       └─roc──► arm64ios / arm64android
                                                 + native/core   reactive engine, styles, layout (Rust)
                                                 + native/ios    UIKit views    (Rust, objc2)
                                                 + native/android  Android views (Rust, JNI + a Kotlin applier)
```

The app's Roc is compiled for the phone against the same platform (`web/platform`, with new
targets). The new host is Rust: a reactive engine that does what `runtime.js` does, minus the DOM;
a resolver for a CSS subset; Taffy for layout (block, flex and grid); and a thin layer per phone
that turns a batch of changes into native views. HTML tags keep their meaning: a `<div>` is a
view, a `<p>` is a text view, an `<input>` is a native text field, `<a href="/day/3">` pushes a
screen.

The first app is Plate. The first milestone needs no phone at all: the Rust engine, linked with the
app compiled for the Mac, passes the web platform's own component tests, compared against what
Chromium's DOM holds after the same steps.

## 1. Why our own renderer, not Lynx, a WebView or drawing ourselves

Researched 2026-11-23 from Lynx's docs and source (lynxjs.org, github.com/lynx-family):

- **Lynx can't be driven without JS.** Its element tree is built only through the "Element PAPI",
  globals callable from JS on its main thread (PrimJS); every framework (ReactLynx, vue-lynx,
  lynx-solid, the Haskell miso-lynx) is a JS shim calling them. There is no public native API for
  the tree (the C embedder API only loads views and registers modules). WebAssembly runs only on
  Android, on the background thread, in the wasm3 interpreter, and not at all on iOS. The workable
  bridge would be native Roc as an experimental Node-API addon plus a JS shim on the main thread,
  with an asynchronous hop between threads on every interaction, about 10 MB of native libraries
  per ABI, and PAPI functions the docs don't list (`__CreateView`, `__FlushElementTree`).
- **A WebView shell** keeps the web UI, which is what the user doesn't want here (and Apple rejects
  apps that are only a website).
- **Drawing everything ourselves** (Blitz-style: Stylo, Taffy, Vello) keeps all of CSS but gives up
  native text input, IME, accessibility and platform feel, and is alpha upstream.

What we take from Lynx is its idea, proven at TikTok's scale: a web-like vocabulary, a CSS subset,
native views. Our own version can stay closer to HTML than Lynx does: Taffy has block layout (Lynx
has only linear, flex and grid, and text must sit in `<text>`), so a `<div>` keeps `display:
block` and a `<p>` holds text as it does on the web.

## 2. Decisions at a glance

| | Proposed | Instead of |
|---|---|---|
| Vocabulary | HTML tags and a CSS subset, the web app's own | RN-style primitives (`<view>`, `<text>`) |
| Drawing | Native views, laid out by us (Taffy) | A WebView; drawing ourselves |
| JS | None | Lynx's engine; a JS shim |
| Roc platform | `web/platform` with phone targets | A fourth platform |
| Engine | A Rust port of `runtime.js`'s engine, tested against it | Sharing one engine with the browser (maybe later, §14) |
| Threads | One: Roc, the engine and layout on the UI thread, as in a browser | RN's split threads |
| CSS | Checked and compiled at build time; what a phone can't do is reported | Parsed on the phone |
| Navigation | Every page in the binary, a stack of screens, layouts kept | A request per page |
| Server | The same server, over HTTP; online only at first | An embedded server; offline |
| First phone | Android (the user's choice), as a spike: one simple screen with typed calls to the server | iOS first; both at once |

## 3. Where things stand

What carries over unchanged:

- **The app's code.** Pages, layouts, components, `Solid`, `<Show>`, `<For>`, `<Loading>`,
  `<Errored>`, contexts, memos, effects, `Endpoint.get!`/`read!`, actions and submissions: all of
  it is Roc that talks to its host through `Host.roc`'s hosted functions (63 in 2026-11).
- **The markup.** `Html.serialize!` writes `{"t":"e","tag":…,"a":[…],"c":[…]}` for an element,
  `{"t":"x","r":id}` for a text hole, `{"t":"l"}` for a list, `{"t":"show"}`, `{"t":"c"}` for a
  component, and so on (`web/platform/Html.roc`, around line 296). Nothing in it is a DOM node.
- **The styles.** Every `<style>` is already collected at build time, scoped by a class
  (`Generated/Styles.roc`, `rocx-cli/Build.roc` around line 690), so the build can hand a phone a
  stylesheet without a browser.
- **The server.** Endpoints, middleware, sessions, channels, jobs: the phone is one more client.
- **Aborting a computation natively.** `signals.rs` already fails a computation by jumping back to
  its guard and freeing what the run allocated (`roc::fail`, `guard.c`), which is what the browser
  does by throwing through the wasm frames. A phone's waits (a memo whose answer isn't in) abort the
  same way and run again later, so the semantics stay the browser's.

What doesn't exist yet:

- Roc for phones: the fork has `arm64mac` and `arm64linux`, no iOS or Android targets (the
  `android` in `src/target/mod.zig` is Zig's ABI tag list). (For Android it needs none: the spike
  links the app's `arm64musl` objects as Android's, §16.) Zig builds for `aarch64-ios`,
  `aarch64-ios-simulator` and `aarch64-linux-android`. The fork links executables and shared
  libraries (`linker.zig`'s `OutputKind`); iOS most likely needs an object or static library for
  Xcode to link (unverified).
- A reactive engine outside JS: `signals.rs` renders once, tracks nothing and never re-runs.
- Client-side navigation: D-040 is Proposed, not built (§8 needs only part of it). *(Since built in
  the browser; on phones since D-138: §8.)*
- Anything that turns markup into native views, lays it out, or resolves CSS outside a browser.
  *(Since D-137 on phones: CSS resolved by `native/core/src/css.rs`, the views laid out by Taffy:
  §6.3.)*

## 4. The shape

### 4.1 Same platform, new targets

The app compiled for a phone is the browser's app compiled for another target. `web/platform`
gains targets the way `server/platform` has them: `targets/arm64ios/`, `targets/arm64iossim/`,
`targets/arm64android/`, each holding the native host's library. `requires { main! }`, the
exposed modules and the hosted functions stay as they are; the phone's host implements them.

### 4.2 Directories

```
native/
  core/       Rust, no platform code: the engine (Host.roc's functions), the tree, styles,
              Taffy layout, events, timers, HTTP, the op batches. Builds and tests on the Mac.
  ios/        Rust (objc2): applies op batches to UIKit views, measures text with CoreText,
              runs the main run loop's wakeups. Plus the Xcode shell template (a few Swift lines).
  android/    Rust (jni, ndk): measures text, wakes the main Looper; a small Kotlin applier
              that takes one byte buffer of ops per flush and makes the Views. Plus the Gradle
              shell template.
  test/       The conformance runner (§12).
```

### 4.3 One thread

Roc, the engine and layout run on the UI thread, as the browser runs the wasm and `runtime.js` on
its main thread. HTTP and timers wait elsewhere and post their answers back to the run loop (iOS:
the main dispatch queue; Android: a pipe the main `ALooper` watches). It keeps the browser's
semantics (a handler's writes apply when it's done; a flush is one turn) and needs no locks.
Moving Roc off the UI thread is what React Native's new architecture spent years on; we measure
first.

## 5. The engine (`native/core`)

A port of `runtime.js`'s engine, the parts that aren't the DOM: computations and their tracking,
signals, memos and their waits, `<Loading>` and `<Errored>` boundaries, `refresh!`, `is_pending!`,
`<For>`'s keyed rows, `<Repeat>`, contexts, owners and cleanups, effects (split compute and apply,
render effects, error handlers), timers, `untrack!`/`latest!`, actions, submissions, `listen!`,
channels, `Browser.call!`'s dispatch. `runtime.js` stays the reference; where the two differ, the
browser is right and the conformance suite (§12) says so.

Its output is not DOM calls but **ops**, batched per flush:

```
create(id, tag)          set_attr(id, name, value)   set_text(id, text)
insert(parent, id, before)   remove(id)              set_classes(id, list)
set_frame(id, x, y, w, h)    set_paint(id, resolved paint)   set_text_run(id, runs)
```

After a flush, the engine resolves the styles of what changed (§6.2), runs Taffy over the dirty
part of the tree (§6.3), and sends one batch. iOS applies it directly through objc2; Android gets
one JNI call per batch with a byte buffer its Kotlin applier walks, because a JNI call per view
change is slow (React Native's "mount items" for the same reason).

Events come back as `(id, event, value)` and run their handlers the way `runtime.js` runs them.

## 6. Elements and CSS: the phone subset

### 6.1 Tags

| Web | Phone |
|---|---|
| `div`, `section`, `article`, `header`, `footer`, `main`, `nav`, `aside`, `form`, `fieldset`, `figure`, `ul`/`ol`/`li`, `dl`/`dt`/`dd` | A view (a block box). List markers are text. |
| `p`, `h1`–`h6`, `span`, `strong`, `em`, `b`, `i`, `small`, `code`, `label`, `time`, `legend`, `caption`, `br` | Text: a block's inline content is one native text view with styled runs |
| `a href` | A tappable run or view: a same-app path pushes a screen, another opens the system browser |
| `button` | A view with a tap and a pressed state (`:active`), the button role |
| `input` (text, email, password, number, search, tel, url) | A native text field with the matching keyboard |
| `input` checkbox, radio | A view the CSS draws, with the checkbox or radio role (iOS has no native checkbox) |
| `input` range, date, time | `UISlider`/`SeekBar`, the system date and time pickers |
| `textarea` | A native multi-line text view |
| `select`/`option` | A native menu or picker |
| `img` | An image view: loaded off the UI thread, cached, `object-fit` |
| `svg` with `path`, `circle`, `rect`, `line`, `polyline`, `polygon`, `g` | One vector view drawn from the subtree (Core Graphics paths, `android.graphics.Path`), drawn again when any part changes |
| `table`, `thead`, `tbody`, `tr`, `th`, `td` | A grid (an approximation of table layout) |
| `title` | The screen's title (accessibility, the app switcher) |
| `html`, `head`, `body`, `meta`, `link` | The document's, nothing on a phone |
| `canvas`, `iframe`, `video`, `audio`, `object`, `embed`, `contenteditable` | Not on phones: the build reports them (§6.5) |

Plate's `.rocx` files use 45 tag names (counted 2026-11-23). Besides `<style>` and `<story>`, which
the build handles, every one is in the table.

> **Status (2026-11-28, D-139):** on Android, `img` (its `srcset` source by the screen's density,
> loaded with the app's cookies, cached, `object-fit`), the text fields with their keyboards,
> `textarea` by its rows, `select`/`option`/`optgroup` as the phone's list, checkboxes and radios
> (the platform's, or the CSS's with `appearance: none`), `date`, `time`, `datetime-local` and `month`
> as the system's pickers, `details`/`summary` toggling, `label` passing a tap to its control, and
> `input type="file"` as the system's photo or document picker. `video` moved out of the last row: a
> native player (a MediaPlayer on a TextureView, its poster or first frame, `controls`, with the
> app's cookies). `range` and `color` inputs, `canvas`, `iframe`, `audio` (an element; `Audio.play!`
> is there), `object`, `embed` and `contenteditable` still aren't. README.md, "Controls, media and
> custom elements' phone halves".

### 6.2 Styles

The build, not the phone, parses the CSS. `rocx build --ios` reads every `<style>` the app has
(`Generated/Styles.roc`'s sources, with their files and lines), checks each rule against the
subset, and writes a compact table (selectors, declarations, `var()` references) into the app.
The phone only matches selectors and resolves values. A parser that already exists (lightningcss,
in Rust) can sit in `cli/host` behind a hosted function, so the check runs in rocx with the
file and line.

Before the app's CSS comes a **phone user-agent stylesheet**, a trimmed copy of the HTML spec's
(`h1`'s size and margins, `p`'s margins, a button's and an input's look), so a page looks as it
does in a browser before the app styles it.

The subset, for a start (what Plate and the site use most: `display: grid` 55 times, `var(--…)`
140 times, `gap`, `color`, `margin`, `padding`, `border-radius`, `font-*`):

- **Boxes:** `display` (block, flex, grid, inline inside text, none, contents), `position`
  (relative, absolute, fixed against the screen; sticky later), insets, sizes and their min/max,
  `aspect-ratio`, margins, padding, borders (solid first), `border-radius`, `box-sizing`,
  `overflow` (hidden; auto and scroll make a native scroll view), `gap`, every `flex-*`, `align-*`,
  `justify-*`, `place-*`, `order`, `grid-template-*` with `repeat`, `fr`, `minmax`, and placement.
- **Paint:** `background-color`, linear gradients, `opacity`, one `box-shadow`, `transform`
  (translate, scale, rotate), `visibility`, `z-index`, `outline` for focus.
- **Text:** `font-family` (the system font for `system-ui`/`sans-serif`, bundled fonts through
  `@font-face`), `font-size`, `font-weight`, `font-style`, `font-variant-numeric`, `line-height`,
  `letter-spacing`, `text-align`, `text-decoration`, `text-transform`, `white-space`,
  `text-overflow: ellipsis`, `-webkit-line-clamp`, `color`.
- **Values:** px, rem, em, %, vw, vh, `calc()`, `var()` with inheritance, every colour syntax, and
  `env(safe-area-inset-*)`, which on a phone is the notch and the home indicator.
- **Selectors:** type, class, id, all four combinators, `:not`, `:first-child`, `:last-child`,
  simple `:nth-child`, `:active`, `:focus`, `:focus-visible`, `:disabled`, `:checked`, attribute
  selectors, `::placeholder`, and `:global()` as today. `:hover` matches nothing.
- **At-rules:** `@media` with widths, `prefers-color-scheme` and `prefers-reduced-motion`;
  `@font-face`; `@keyframes`, `animation` and `transition` in phase 4.

### 6.3 Layout

Taffy lays out the tree: block, flex and grid, implemented from the CSS specs. A block whose
children are inline (text, `span`, `a`, `strong`…) is one text view: its runs become an
`NSAttributedString` or a `SpannableString`, measured by the platform (CoreText, `StaticLayout`)
through Taffy's measure function, with a cache. A block with both inline and block children gets
anonymous blocks, as CSS gives it. An `inline-block` in the middle of a line of text is the one hard
case; at first it breaks the line, and the build reports it.

> **Status (2026-11-28, D-137):** built so on Android, with an `inline-block` among text handled
> otherwise: its block becomes a line, a flex row that wraps (the inline boxes and the text between
> them its items), which keeps badges, icons and buttons on one line with their text. Taffy 0.16 on a
> tree of the engine's own (its `calc()` resolved, `aspect-ratio` and fit-content where Taffy's flex
> misses them, `order` by sorting the items); text measured by `StaticLayout` over JNI; absolute
> boxes drawn in their containing block's view and fixed ones on a layer over the scrolling page; a
> render projects again only what changed (README.md, CSS and layout).

### 6.4 SVG

Icons, rings and small charts draw as one native vector view each, from the `<svg>`'s subtree (with
the CSS that styles it: `fill`, `stroke`, `stroke-dasharray`, `transform`), drawn again when any of
it changes. That covers Plate's icons and its energy ring (`components/Summary.rocx`). The charts
package, which updates single nodes many times a second and uses text and transitions in SVG, waits
for a later phase.

### 6.5 What the build reports

Web first: a web app is never refused because of its phone build. `rocx build --ios` (and `rocx
check --ios`) lists, with files and lines, the tags a phone doesn't have, the CSS it ignores
(`float`, `cursor`, `user-select`, scrollbar styling, `inline-block` in text), and the
`Browser.call!` names no native handler answers. Question 1 asks whether some of these should fail
the phone build instead.

## 7. Events, forms, focus

- `on:click` is a tap (with the pressed state); `on:input`, `on:change`, `on:focus`, `on:blur` and
  `on:keydown` for Enter come from the native fields; `on:submit` from a form's submit button and
  the keyboard's return key.
- A `<form>` posting to an endpoint behaves as the browser's runtime already makes it: its named
  fields are gathered and sent, and its submission is read (`use_submissions!`).
- Focus, the keyboard and scrolling a focused field into view are the host's. `on:viewport`
  (`<Repeat>`'s virtual lists) works from the scroll offset and the layout, with no
  IntersectionObserver.
- Drag and drop (D-029) waits for a later phase.

> **Status (2026-11-28, D-139):** built so, and a tap's default actions as the HTML spec has them (a
> summary, a label, a file input); `change` when a field loses the focus changed; constraint
> validation before a form is sent (`required`, `email`), its field focused with its message; forms
> with files as `multipart/form-data`; a double tap a `dblclick`. The keyboard keeps the focused field
> in view (the screen scrolled above it). `on:viewport` is D-137's.
>
> **Status (2026-11-28, D-141):** a touch goes to what is drawn where it lands (a view hanging out of
> its box, a menu's items, gets it), a finger down off the focused field blurs it, the keyboard goes
> with its field, and a page script's listeners on `window` (capturing and bubbling, a held event
> sent on later, Android's back as Escape) are an app's page halves'.

## 8. Pages and navigation

> **Status (2026-11-28, D-138):** built as below, with Question 4 answered otherwise than proposed:
> no light route check, but D-040's own way. A navigation fetches the page's document, as the
> browser's does, so the server runs the page's middleware and its redirect is followed; the phone
> reads only what the document seeds (its answers and flash), so the new page's first frame asks
> the server for nothing. The page doesn't slide: the layouts stay and the levels below them are
> made anew, as in the browser (README.md, Pages, sessions and the server).

There is no server rendering and no hydration on a phone: every page is in the binary (as it is
in the wasm today) and is mounted from nothing.

- The app opens at `/` (or a configured start path), its layouts mounted around the page.
- A same-app link, `Router.navigate!` or a redirect pushes a screen; the system back gesture and
  Android's back button pop one. The layouts stay mounted and only the page slides, so the app's
  header and tab bar are its own, drawn from its `.rocx`, as on the web. (D-040 plans the same:
  layouts kept, the page swapped.)
- `Router.location!` follows the stack. A query change re-reads in place.
- **Page guards.** On the web, a page's middleware runs on the server when the page is requested
  (a guard redirects to `/login`). A phone doesn't request pages, only endpoints. Proposed: the
  server answers a light route check (the page's middleware, its status and redirect, no render),
  which D-040's navigation can use too. Question 4.

## 9. Talking to the server

> **Status (2026-11-28, D-138, D-140):** one Rust client in `native/core` (question 5's), plain
> `http://` with keep-alive, `fetch`'s redirects, timeouts and a cookie jar in the app's files;
> server-sent events for `listen!` and the channels' `/rocx/live`. Not yet: rustls, the build's
> header.

- The server's origin is set at build (`rocx build --ios --server https://…`); `rocx dev --ios`
  points the simulator at the dev server.
- `Host.fetch!` goes through an HTTP client in `native/core` (rustls with the platform's roots,
  keep-alive), and a cookie jar kept in the app's files, so sessions work as in a browser. One
  implementation for both phones (question 5).
- `listen!`, channels and presence (`/rocx/live`) use the same client's streaming.
- Requests from the app carry a header naming its build, so the server can tell an old app (a
  phone app can't be reloaded the way a page can) and answer it plainly.
- No network shows the nearest `<Errored>`, as in a browser. Offline (a database on the phone) is
  out of scope.

## 10. `Browser.call!` and plugins

`Browser.call!(name, value)` dispatches to a registry of native handlers by name instead of page
JS. A plugin can ship a native half (Rust, Swift or Kotlin) beside its browser script: audio
(`AVAudioPlayer`, `SoundPool`), push (APNs, FCM), and for Plate the camera's barcode scanner
(AVFoundation, ML Kit), which is a V2 wish that Firefox can't do in the browser. An unregistered
name fails as the web's does, saying which plugin's native half it needs.

> **Status (2026-11-28, D-139):** the registry is Kotlin's (`Calls.kt`: `audio.play`,
> `vibrate.pattern`, `clipboard.write`), with D-138's page functions done on the engine's document
> (`calls.rs`). Extended to elements: an app's custom element whose page script does its work in a
> browser (`customElements.define`) gets a phone half, Kotlin in the app's `android/` folder (`object
> ImageUpload : ElementHalf("image-upload")`), built into its APK and told of every event on the
> element and inside it; it reads the element's attributes, tells the page events with values (which
> `on:<event>.value` reads), asks the app's server with its cookies, and uses the phone (the
> clipboard, a file's size in pixels). The dev client has none (it would load an app's Kotlin at run
> time). README.md, "Controls, media and custom elements' phone halves"; DECISIONS.md, D-139.
>
> **Status (2026-11-28, D-141):** page scripts that are no element's get page halves too (`object
> Confirm : PageHalf()`): told of the app's start, each navigation, the events they name before and
> after the page's handlers (holding one until a dialog's answer), Android's back, and
> `Browser.call!`'s page functions (an app's `window.rocxEffects`), which they answer before the
> shell's registry. README.md, "Page halves"; DECISIONS.md, D-141.

## 11. Building and the dev loop

- **The fork:** targets `arm64ios`, `arm64iossim` and `arm64android`, and whatever output Xcode
  needs to link (an object or a static library). The user opens these as PRs, as with other fork
  fixes.
- **`rocx build --ios`:** compiles the app's Roc for the simulator or a device, links it with
  `native/ios`'s library into the Xcode shell (generated per app: name, bundle id, icon), and runs
  `xcodebuild`. **`rocx build --android`:** the same with a `.so`, the Gradle shell and
  `./gradlew`.
- **`rocx dev --android` (built, README.md's Dev mode):** a dev client (the shell with the host as
  `libhost.so`, no app) loads each build's library from the dev server (`dlopen`) in place of the
  last: about a second from a save to the phone, a fresh start each time (as the browser's reload:
  no state kept, by choice), a failed build's error on
  a red screen, the phone's log in rocx dev's terminal over HTTP. `--lan` serves phones on Wi-Fi:
  a QR code for a page that opens (or installs) the dev client at the computer's address. Debug
  builds only: Play bans downloaded native code in a release.
- **`rocx dev --ios`:** the same on the simulator, which runs Mac code and loads a new library as
  the Android client does; a physical iPhone loads no downloaded code, so it reinstalls on save
  (`xcrun devicectl`, around 10 s). A reload is a fresh start on both.
- **Toolchains:** Xcode from Apple; the Android SDK and NDK and the Rust targets through Nix where
  they can be, as with the rest of the repo.
- Signing, TestFlight and Play's internal track are phase 4.

## 12. Testing

- **Conformance, on the Mac, no phone.** `native/core` with a recording renderer, linked with the
  web platform's test apps (`web/test/app/*.rocx`) compiled for `arm64mac`, a target the fork has.
  Each test's steps (mount, clicks, input, answers arriving, timers) run on both hosts; the native
  tree must equal Chromium's DOM after each step (tags, attributes, text; markers dropped). This
  keeps the two engines one in meaning, and it is cheap enough for `just check` (question 9).
- **Layout.** Fixtures of block, flex and grid boxes with fixed sizes, the frames Taffy computes
  compared with Chromium's `getBoundingClientRect`. Text is compared by line counts, since fonts
  differ.
- **On the phone.** Simulator screenshots of Plate's screens, as `just example-shots` takes the
  browser's.

## 13. Phases

**Since (2026-11-28):** the Android host navigates (D-138: links, `navigate!`, back, guards and
redirects through the page's document, a cookie jar, forms' redirects, keep-alive) and updates live
(D-140: `listen!`, channels), checked against a large app's dev server on the emulator; and lays its
views out as CSS does (D-137: Taffy for block, flex, grid and positioned boxes, text measured by the
platform, native scroll views, the CSS subset of §6.2 at run time), its pages looking as Chromium
shows them at a phone's width.

**Built (2026-11-23): the Android spike**, ahead of phase 0, at the user's request (Android first,
one simple screen, typed calls to the server). It took from phase 0 the engine (`native/core`, all
49 hosted functions, 40 of them as runtime.js does them, the rest stubs that say why), the recording
renderer (`native/mac`) and a first CSS subset; and from phase 3 the Kotlin applier, the APK and the
emulator. Not yet: the conformance suite against Chromium, Taffy, the CSS table at build time,
navigation, HTTPS and cookies. The phases below stand, with Android's moved before iOS's: phase 0
next (the engine trusted on `web/test/app`), then Plate's day screen on Android.

Background work, one phase at a time, each merged when it passes, none touching the web's code
paths except to add tests.

| Phase | What | Done when | Rough size |
|---|---|---|---|
| 0 | `native/core` on the Mac: the engine, the CSS table, Taffy, the recording renderer, the build's style check | The conformance suite passes for `web/test/app`; layout fixtures match Chromium | 2–3 weeks |
| 1 | iOS simulator: fork targets, the UIKit applier (view, text, image, button, field, scroll), HTTP and cookies | Plate's day screen works on the simulator against a local Plate server | ~2 weeks |
| 2 | Plate usable on iOS: navigation and route checks, forms and submissions, `select`, SVG, safe areas, the keyboard, dark mode, accessibility basics, `rocx build --ios`, `rocx dev --ios` | The user can log a day's food in Plate on the simulator | ~3 weeks |
| 3 | Android: fork target, the Kotlin applier, Gradle, the emulator | Phase 2's bar, on Android | 2–3 weeks |
| 4 | Reach: transitions and animations, virtual lists, channels, plugins' native halves (audio, push, camera), drag and drop, device builds and signing | Open-ended | Open-ended |

About two and a half to three months of background work to Plate on both phones.

## 14. Costs and risks

- **Two engines** (JS and Rust) that must agree. The conformance suite is the guard. Later, the
  Rust engine compiled to wasm could replace `runtime.js`'s engine and leave one; not now, as the
  web is primary and `runtime.js` is tuned.
- **CSS that looks right in a browser and off on a phone.** The phone user-agent stylesheet and
  the build's report soften it; some apps will want phone-only rules (`@media` on width already
  works).
- **Text measured by the platform, laid out by Taffy:** small mismatches, as React Native has.
- **The fork** carries three more targets and an output mode.
- **Every hosted function** added for the web needs a phone version (or a stub that reports it);
  the conformance suite fails when one is missing, as the platform reference's test fails on an
  undocumented effect.
- **Size:** the app's Roc plus a Rust host, no JS engine: likely a few MB (unmeasured), against
  Lynx's ~10 MB of native libraries per ABI.

## 15. Questions for the user

Each has a recommendation. The user answered 1, 2, 4 and 6 (the top of this file). The Android
spike took the recommendations for 5 (one Rust client), 7 (a small Kotlin applier) and 8
(`Browser.call!` kept, its native registry empty so far).

1. **CSS and tags a phone can't do:** report them and build anyway (recommended: the web is
   primary), or fail the phone build?
2. **Navigation chrome:** the app's own header and tab bar from its `.rocx`, with native back
   gestures (recommended: one codebase, matches D-040), or native navigation and tab bars from a
   config?
3. **Form controls:** native text fields, pickers, date pickers and sliders, with checkboxes and
   radios drawn by the CSS (recommended), or native switches for checkboxes?
4. **Page guards on a phone:** a light route-check request to the server, shared with D-040
   (recommended), or let pages rely on their endpoints answering 401?
5. **HTTP and cookies:** one Rust client in `native/core` for both phones (recommended), or each
   phone's own (`URLSession`, OkHttp)?
6. **First phone:** iOS, then Android once Plate works on iOS (recommended)?
7. **Shells:** a few lines of Swift and a small Kotlin applier are unavoidable (Android Views are
   Java objects). Fine?
8. **The bridge's name:** keep `Browser.call!` on phones (recommended: one API, a different
   registry), or add `Native.call!`?
9. **Phase 0's conformance suite in `just check`** (recommended: it needs only the Mac), or a
   separate `just native-check`?

## 16. What the spike changed

Where the Android spike (README.md) went otherwise than this design, and why:

- **No fork target.** The fork's `Archive` output and its static Linux target are enough: the app
  built for `arm64musl` with `inputs: [app]` is AArch64 ELF objects that need no C library, and the
  NDK's clang links them with the host into `libapp.so`. `web/platform` has `arm64musl` and
  `arm64mac` targets (the second for `native/mac`), not `arm64android`. An `arm64android` target
  with `output: Shared` is a nicety now (Roc linking the library itself), not a requirement. iOS
  will still need one (Mach-O for iOS isn't the Mac's).
- **Ops: a projection and a diff, not DOM-style calls.** The engine keeps a document of its own as
  the browser keeps the DOM (elements, text, a hole's range between two comments), so its code
  follows runtime.js line for line. After each flush, that document is projected onto native views
  (inline content into one text view, anonymous text beside blocks) and compared with the last
  batch sent, which says `CREATE`, `SET`, `CHILDREN` (a box's children, in order), `DESTROY`,
  `ROOT`, `TITLE`. The projection is where "a `<p>` is one text view" lives, in one function, and
  the applier stays small. Every view is made before any `CHILDREN` names it.
- **No Taffy at first.** One screen needed only a column of blocks: `LinearLayout`s, with CSS's
  margin collapsing between siblings done by the applier. *(D-137 brought Taffy: a render sends its
  views' changes, lays them out, then sends their frames, `FRAME` and `EXTENT`, which a `Box`
  ViewGroup places as they say.)*
- **CSS read on the phone.** The page carries its stylesheet (`Generated/Styles`, in a `<style>`),
  so the spike resolves it there, after a phone user-agent sheet, and warns once of what it ignores;
  `build.sh` mounts the app on the Mac to print those warnings at build time. The build-time table
  (file and line for each warning, nothing parsed on the phone) is still the plan.
- **No Gradle.** `native/android/build.sh` uses the SDK's tools (aapt2, kotlinc, R8, zipalign,
  apksigner): a changed `.rocx` rebuilds the APK in about 4.5 s. A Gradle shell is for when an app
  needs Android libraries.
- **A dev mode early.** The design had `rocx dev --ios` reinstall on save (a few seconds); the
  user asked for an Expo-like loop first. Roc's dev backend builds the phone's library in 0.2–0.4 s
  and its arm64 code ran the spike's screen correctly, so the dev client loads each build's
  library instead of reinstalling (README.md, Dev mode).
- **HTTP over plain sockets.** The engine's client is std's TCP and HTTP/1.1, plain `http://`, on a
  thread a request (question 5's one Rust client, without rustls and cookies yet).

## Later

- **Native code, no OTA (the user, 2026-11-23).** The app's Roc is native code on phones. Production
  over-the-air updates are ruled out: iOS can't run downloaded machine code, and Google Play bans
  downloaded `.so` files. A dev mode can still load a new `.so` in debug builds. OTA is deferred:
  revisit once the native path and an Expo-like dev mode exist; the preferred idea then is running
  the browser's `.wasm` in a WebAssembly interpreter on the same native host, not Roc's interpreter
  mode (which measured 40–250× slower than `--opt=speed` on the Mac).
- **The dev mode exists (2026-11-23, `rocx dev --android`)**, so OTA's precondition is half met: an
  iOS dev mode is the other half.
