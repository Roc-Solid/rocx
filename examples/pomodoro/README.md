# Pomodoro: a focus timer, in a browser and on a phone

A Pomodoro timer: 25 minutes to focus, then 5 to rest. A ring empties as the time goes, and the tab's
title counts down while it runs. When a session ends, a chime plays, the phone buzzes, a focus
session is counted for today, and the next session waits to be started. A bar under the buttons
fills toward a good day's eight sessions.

It is the smallest example with a page and a database, and the first meant for two screens. The same
`routes/+page.rocx` runs in a browser and, unchanged, as an Android phone's own native views, with
no WebView and no JavaScript. Read it to learn how to keep a timer by a deadline, play a sound and
buzz the phone through plugins, record something with an action that isn't a form, and run one page
on the web and on Android.

## Run it

From the repository's root, after `just setup`:

```sh
cd examples/pomodoro && ../../bin/rocx dev
```

Open http://localhost:8080. `rocx dev` builds the app (the server and the browser's half), serves it
under `--dev` along with the app's `static/` (the chime), and builds it again each time you save a
file.

Run it from the example's directory. The sessions are in SQLite:
`database: Sqlite("data/pomodoro.db")` in `main.roc` is a path relative to where the server starts,
so the file is `examples/pomodoro/data/pomodoro.db` (gitignored). The server makes the file and
migrates it as it starts. `rocx dev --port 8081` serves on another port.

To make the chime again: `node sounds.mjs`.

To build it to deploy (the server optimized for speed, the wasm for size, the chime with the
browser's files):

```sh
cd examples/pomodoro
../../bin/rocx build                  # dist/server and dist/static
dist/server --static dist/static      # on PORT, 8080 unless set
```

`rocx build --image` makes a container image instead, `pomodoro.tar`, with `/app/data` for the
database's volume. The phone has no release build yet: `rocx dev --android` is the way onto it.

### On an Android phone

```sh
cd examples/pomodoro && ../../bin/rocx dev --android          # an emulator, or a phone on USB
cd examples/pomodoro && ../../bin/rocx dev --android --lan    # also phones on this Wi-Fi
```

With `--android`, `rocx dev` does what it always does and also builds the app's Roc for the phone on
each build. The first time, it builds a dev client app (about a minute). If `adb` sees an emulator
or a phone on USB, it installs the dev client there and opens it on your app; each save reloads it.
With `--lan`, the server listens on your network too, and `rocx dev` prints a QR code that a phone
on the same Wi-Fi scans to get the dev client and connect.

It needs the Android SDK (`$ANDROID_HOME`, else `~/Library/Android/sdk`), the Android NDK
(`$ANDROID_NDK`), Rust's `aarch64-linux-android` target, Java and the Kotlin compiler.
[spike/native-apps/README.md](../../spike/native-apps/README.md) ("Setting up" and "Dev mode") says
how to get each, and how the phone runs the page.

On the phone, the ring is drawn natively from the SVG, and the chime and the buzz come from the
phone's host (it fetches the chime from the server). `screens/android.webp` is the page on the
emulator; the docs site's page for this example shows it.

Not yet: while the app is in the background, the phone keeps time, but it doesn't tell you a session
ended until you come back to the app. An alarm the system raises is listed in the repository's
TODO.md.

## A tour

- **The timer** (`routes/+page.rocx`) keeps a moment, not a count of ticks. Started, the clock runs
  until `now + left` (`Pomodoro.Clock` is `Paused` or `Until(ms)`). While it runs, an interval reads
  the time four times a second (`Time.now_millis!`) and shows what is left. A tab the browser slows
  down in the background, or a phone that put the app to sleep, shows the right time again on its
  next tick. The interval is started in an effect that follows the clock, so the effect's cleanup
  stops it when the clock pauses or starts again.
- **A session's end** plays `static/sounds/done.wav` (packages/audio), buzzes 300 ms on, 150 ms off,
  300 ms on (packages/vibrate), and records a focus session with `use_action!`. After the action,
  the page's reads are read again, so today's count follows.
- **The ring** is SVG: a circle whose `stroke-dasharray` is the share of time left, out of a
  `pathLength` of 1000, turned to start at the top. The time and the mode are `<text>` inside it.
- **Today's count** is a memo that reads `GET /api/today`, shown inside `<Loading>` (while it is on
  its way) and `<Errored>` (if it fails, with a button that tries again).
- **The rules** (`Pomodoro.roc`) are pure Roc: the lengths, what follows a session, `25:00` rounded
  up to the second, the ring's share, the bar's width. Its `expect`s test them.
- **The server** keeps each focus session in SQLite (`migrations/0001_sessions.sql`, `Store.roc`),
  with the day it ended on as the server's clock has it (`date('now', 'localtime')`), so the browser
  and the phone agree on when today began. `GET /api/today` counts today's sessions, and
  `POST /api/sessions` adds one and answers with the new count.

## What it shows

| Feature | Where to look |
|---|---|
| One page, the same on the web and on Android | `routes/+page.rocx`; `rocx dev --android` |
| A timer kept by a deadline, not by counting ticks | `create_effect!` + `set_interval!` + `Time.now_millis!` in `routes/+page.rocx`; `Pomodoro.left` |
| A sound and a buzz, each from a plugin with a browser half and a phone half | `Audio.play!`, `Vibrate.pattern!` in the page; `plugins: [AudioPlayer.plugin({}), Vibrator.plugin({})]` in `main.roc`; the phone's `native/android/app/src/dev/rocx/phone/Calls.kt` |
| An action without a form, and the reads it refreshes | `use_action!(Api.post_api_sessions({}))`; `today!` |
| `<Loading>` and `<Errored>` around a read | the "today" section of `routes/+page.rocx` |
| SVG, and a percentage width, drawn natively on the phone | the ring, and the bar's `style:width={Pomodoro.progress(…)}` |
| The tab's title from the page, while the timer runs | `<Title>` in `routes/+page.rocx` |
| Endpoints with a typed body and answer, and a refusal | `routes/api/sessions/+server.roc`, `routes/api/today/+server.roc` |

## Test it

From the repository's root:

```sh
just examples pomodoro           # build, type-check, lint, the SQL, the expects and the node tests
just examples-release pomodoro   # rocx build, then the node tests against a server built --opt=speed
```

`just examples` checks the SQL against SQLite (`rocx check --sql`) too. To run the parts yourself:

```sh
bin/rocx fmt --check examples/pomodoro
bin/rocx check examples/pomodoro   # build it, type-check both programs; problems at their .rocx lines
bin/rocx check --sql examples/pomodoro   # each statement prepared against the migrations
bin/rocx test examples/pomodoro    # the expects: lengths, the clock, the shares
node --test 'examples/pomodoro/test/*.test.mjs'   # over HTTP, and in Chromium
```

- **`test/http.test.mjs`**: the page rendered on the server (25:00, Focus, Start, today's count); a
  session recorded and `GET /api/today` agreeing; sessions of no minutes or longer than a day
  refused; the chime and the plugins' scripts served.
- **`test/browser.test.mjs`**, in Chromium: start, pause and reset, with the title counting down;
  and a whole focus session gone by, with the chime and the buzz, the session recorded and the
  break set up. Rather than wait 25 minutes, the test moves the page's clock on (`Date.now`, which
  `Time.now_millis!` reads), and it records what the sound and the buzz are asked to do instead of
  playing them.

## What it asked of the platform

Built in the platform for this app, so that the same page works on a phone:

- **Sound and vibration on the phone.** `Browser.call!` had no native half on Android. The phone's
  host now has native handlers (`Calls.kt`): `audio.play` (Android's MediaPlayer) and
  `vibrate.pattern` (its Vibrator). Vibration is a new package, packages/vibrate, whose browser half
  is `navigator.vibrate`.
- **SVG on the phone.** An `<svg>` is one native view, drawn from shapes the host makes of it
  (`native/core/src/svg.rs`: paths made plain, arcs as curves, transforms, paint and dashes
  resolved).
- **Percentages on the phone.** `width: 75%`, `max-width` and the like become sizes once the box
  they are in is measured (`Box.kt`).
- **Scoped styles on the phone.** rocx's scoped selectors put the scope in `:where()`, which the
  phone's CSS didn't read; it does now. A flex column's `align-items: center` now sizes its children
  to what they hold, and the body's background fills the screen.
- **The stylesheet outside `<NoHydration>`.** A phone renders the document itself (it gets no server
  render), so the layout puts `{Styles.style}` (a `<link>`) outside `<NoHydration>`, where the
  phone's host can see it (`routes/+layout.rocx`).
