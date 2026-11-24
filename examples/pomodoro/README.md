# Pomodoro: a focus timer, in a browser and on a phone

A Pomodoro timer: 25 minutes to focus, then 5 to rest. A ring empties as the time goes, and the tab's
title counts down while it runs. When a session ends, a chime plays, the phone buzzes, a focus
session is counted for today, and the next session waits to be started. A bar under the buttons
fills toward a good day's eight.

It is the smallest app with a page and a database, and the first meant for two screens. The same
`routes/+page.rocx` runs in a browser and, unchanged, as an Android phone's own views (D-063: no
WebView and no JavaScript). `rocx dev examples/pomodoro --android` puts it on a phone.

## A tour

- **The timer** (`routes/+page.rocx`) keeps a moment, not a count of ticks. Started, the clock runs
  until `now + left` (`Pomodoro.Clock`). While it runs, an interval reads the time four times a
  second and shows what is left. A tab the browser slows down in the background, or a phone that put
  the app to sleep, shows the right time again on its next tick. The interval is started in an
  effect that follows the clock, so it stops itself when the clock stops.
- **A session's end** plays `static/sounds/done.wav` (packages/audio), buzzes 300 ms, 150 ms off,
  300 ms (packages/vibrate), and records a focus session with `use_action!`. The submission's answer
  has the page's reads read again, so today's count follows.
- **The ring** is SVG: a circle whose `stroke-dasharray` is the share left, in a `pathLength` of
  1000, turned to start at the top. The time and the mode are `<text>` in it.
- **The rules** (`Pomodoro.roc`) are pure Roc: lengths, what follows a session, `25:00` rounded up
  to the second, the ring's share, the bar's width. Its `expect`s test them.
- **The server** keeps each focus session in SQLite (`migrations/0001_sessions.sql`), with the day
  it ended on as the server's clock has it (`date('now', 'localtime')`). `GET /api/today` counts
  today's, and `POST /api/sessions` adds one and answers with the count.

## What it shows

| What | Where |
|---|---|
| One page, the same on the web and on Android | `routes/+page.rocx`; `rocx dev --android` |
| A timer kept by a deadline, not by ticks | `create_effect!` + `set_interval!` in `routes/+page.rocx` |
| A sound and a buzz from a timer's tick, each a plugin with a phone half | `Audio.play!`, `Vibrate.pattern!`; native/android's `Calls.kt` |
| An action without a form, and the reads it refreshes | `use_action!(Api.post_api_sessions({}))` |
| SVG and a percentage width, drawn natively on the phone | the ring, and the bar's `style:width` |
| The title from a page, while the timer runs | `<Title>` |

## Build and run it

You need the repository's toolchain (`just setup`), and nothing else. From the repository's root:

```sh
bin/rocx dev examples/pomodoro --port 18170   # bin/rocx: any repo script builds it
```

Then http://localhost:18170. To make the chime again: `node examples/pomodoro/sounds.mjs`.

## On a phone

With an Android phone on USB (or an emulator; `--lan` for a phone on Wi-Fi), the same command
with `--android` installs the dev client, opens the app on the phone, and reloads it at each save
(spike/native-apps/README.md):

```sh
bin/rocx dev examples/pomodoro --port 18170 --android
```

The phone draws the ring with its own canvas and plays the chime from the server. Its handlers for
`audio.play` and `vibrate.pattern` buzz and play without a script. While the app is in the
background, the phone keeps time but doesn't tell you a session ended until you come back (an
alarm the system raises is in TODO.md). `screens/android.webp` is the page on the emulator; the
docs page shows it.

## Test it

```sh
bin/rocx fmt --check examples/pomodoro
bin/rocx check -- .tools/roc-active test examples/pomodoro/main.roc   # the expects: lengths, the clock, the shares
node --test 'examples/pomodoro/test/*.test.mjs'                       # over HTTP, and in Chromium
```

The browser tests move the page's clock on (`Date.now`, which `Time.now_millis!` reads) rather than
waiting 25 minutes, and keep what the sound and the buzz are asked for instead of playing them.

## What it asked of the platform

- **Sound and vibration on the phone**: `Browser.call!` had no native half on Android. The host now
  has native handlers (`Calls.kt`): `audio.play` (MediaPlayer) and `vibrate.pattern` (the
  `Vibrator`, a new package, packages/vibrate, whose browser half is `navigator.vibrate`).
- **SVG on the phone**: an `<svg>` is one view, drawn from shapes the host makes of it
  (native/core/src/svg.rs: paths made plain, arcs as curves, transforms, paint and dashes resolved).
- **Percentages on the phone**: `width: 75%`, `max-width` and the like, made sizes once the box
  they are in is measured (`Box.kt`).
- **Scoped styles on the phone**: rocx's scoped selectors put the scope in `:where()`, which the
  phone's CSS didn't read; a flex column's `align-items: center` now sizes its children to what they
  hold, and the body's background fills the screen.
- **The stylesheet outside `<NoHydration>`**: a phone renders the document itself, so the layout's
  `{=Styles.style}` (a `<link>`) stays where its host can see it.
