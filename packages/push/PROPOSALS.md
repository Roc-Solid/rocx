# push: proposals

What packages/push needs from outside its folder, and what it does meanwhile. Two are open:

4. [Jobs: give up, or come back at a time](#4-jobs-give-up-or-come-back-at-a-time): a refusal that
   isn't retried, and `Retry-After`.
5. [`Browser.call!` with an answer](#5-browsercall-with-an-answer): how `<PushButton>` hears how a
   click went.

Sections 1 to 3 are built, and their text is in git history:

1. P-256 and AES-128-GCM in the host: `P256.ecdh!`, `P256.sign!` and `AesGcm.seal_with_nonce!`
   (D-080), and `P256.generate!` for VAPID keys without Node (D-097).
2. Server-only modules in packages: push is a plugin that names the server platform, with a
   `browser.roc` for the browser's half (D-033, D-051).
3. Static files in packages: the plugin's files, the service worker at the site's root (D-050).

[Open questions](#open-questions) for the user are at the end.

---

## 4. Jobs: give up, or come back at a time

**Problem.** Jobs are packages/jobs's (D-034). A job's `run!` answers `Ok` or `Err(why)`, and every
`Err` is tried again after the jobs plugin's `retry_ms` (1000 by default), doubled for each attempt
after. A push service's answers need two more:

- **Give up now.** A 400, 401, 403 or 413 won't change if the message is sent again, and
  re-sending a refused request to a push service only gets the server rate-limited. Today the job
  logs the refusal, notes it on the subscription and answers `Ok`, so the jobs page shows it
  **done**, and the jobs plugin's `on_failed!` (an error tracker's report) never hears of it.
- **Come back at a time.** A 408, 429 or 5xx with `Retry-After: 120` says when to come back, while
  the worker's backoff would try again in 1, 2, 4 and 8 seconds. Today the job queues a copy of
  itself for then (`Job.enqueue!` with `{ when: At(…) }`, counting the times in its input) and
  answers `Ok`.

**Options.**

1. **A richer answer, for a kind defined to give one:** `run!` may answer `Err(GiveUp(why))`
   (failed now, whatever its attempts) or `Err(RetryAt(ms, why))` (queued again at `ms`, counting
   an attempt), beside `Retry(why)`. The jobs plugin's worker (`JobWorker`) reads it: no platform
   change.
2. **Effects a job calls before answering `Err`:** `Job.give_up!({})`, `Job.retry_at!(ms)`. Easier
   to add, but the job's answer no longer says what happens.
3. Leave it to each job (today).

**Recommended: 1.** It says in the type what the worker will do, as Oban's `{:cancel, reason}` and
`{:snooze, seconds}` do.

```roc
Job.Outcome : [Retry(Str), RetryAt(U64, Str), GiveUp(Str)]
Job.define_outcomes : Str, { attempts : U64, timeout_ms : U64 }, (context, input => Try({}, Job.Outcome)) -> Kind(context, input)
```

**What in the package depends on it.** The `Refused` and `RetryAfter` branches of `deliver!`
(Push.roc). With option 1 they become `Err(GiveUp(why))` and `Err(RetryAt(now + ms, why))`,
and the `later` field of `Push.Input` goes.

**How it could be undone.** The plain `Err(Str)` stays as it is; removing the new kind
constructor touches only jobs that use it.

---

## 5. `Browser.call!` with an answer

**Problem.** Subscribing is asynchronous: the permission prompt, the service worker, the push
service, the POST to the server. Its outcome (on, blocked, failed and why) belongs in the
component's state. `Browser.call!` answers nothing, so `push.js` sets `value` on every
`[data-push-state]` element and dispatches a `pushstate` event, which `<PushButton>` hears with
`on:pushstate.value={set_said!}`. It works (custom event names are bound like any other), but it is
a side channel through the DOM. What the page finds as it loads (already subscribed?) comes the
same way: `push.js` listens for `rocx:ready` and `rocx:navigated` itself. An effect's `apply` runs
as a handler and may call `Browser.call!` now, so that look could start from `<PushButton>`
(`on_settled!`); its answer would still come by the event.

**Options.**

1. **`Browser.ask!(name, arg, answered!)`**: the page's function may return a value or a promise;
   when it settles, the runtime runs `answered!` as a handler with `Ok(json)` or `Err(why)`.
   `<PushButton>` would be
   `on:click={|| Browser.ask!("push.subscribe", { api: api }, |answer| set_state!(PushState.parse(answer ?? "failed:")))}`,
   and an `on_settled!` effect could ask once on load.
2. Keep the event for the answer, and start the look on load from `<PushButton>`'s `on_settled!`
   (possible today).
3. Keep the DOM event and the script's own listeners (today).

**Recommended: 1.** It is Solid's `createResource` shape for page functions, and Elm's
`port`/`subscription` pair in one call.

**What in the package depends on it.** `components/PushButton.rocx` (`data-push-state`,
`on:pushstate.value`), and `tell` and the `rocx:ready` and `rocx:navigated` listeners in
`static/push.js`.

**How it could be undone.** `Browser.call!` stays; `ask!` is additive.

---

## Open questions

1. **A 403 from a push service: delete the subscription or not?** Some push services answer 403
   when a subscription was made with another VAPID key, and it can then never be sent to. Every
   push service also answers 401 or 403 for a bad token, which is a mistake in the server's
   settings. The package deletes on 404 and 410 only, and logs 403s, so a wrong key in production
   doesn't delete every subscription. Is that the trade you want?
2. **Only browsers' push services, by default?** `Push.subscribe!` refuses an endpoint that isn't
   at Google's, Mozilla's, Apple's or Microsoft's push service (`Subscription.services`), since
   the server sends a request to whatever URL a subscription names. A new browser's push service
   would need adding to the list. Under `--dev`, an `http:` one on this machine is allowed too.
3. **Owners as text.** `push_subscriptions.owner` is `text` (`""` for a visitor), so an app with
   integer or UUID ids can use it, and packages/auth's ids (version 7 UUIDs, D-134) fit as they
   are. Would you rather it were `bigint`, or an app-defined column?
4. **The default TTL** is a day (Chrome keeps a message four weeks at most). Is a day right for
   the apps you have in mind?
5. **`<PushButton>`** is the package's opinion of the UI (its words, its states). Keep it, or
   leave the UI to each app and ship only `push.js` and `PushState`?
