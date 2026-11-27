# push

Web Push notifications for Roc Solid apps, as a plugin. A page asks the user's permission and
subscribes; the server keeps the subscription; later the server sends a notification, and the
browser shows it even with every tab of the site closed. Subscriptions are kept in the app's
database, Postgres or SQLite. Each message is encrypted for its browser (RFC 8291) and signed for
its push service (VAPID, RFC 8292), with the server platform's `P256` and `AesGcm` (D-080).

The user guide is the docs site's [Push page](https://roc-solid.github.io/ecosystem/push); this file
is the reference.

## Installing it

1. **Keys.** Under `rocx dev` there is nothing to do at first: with no keys, each run of the
   server makes a VAPID pair of its own (`P256.generate!`) and logs the two settings that keep it:

   ```
   WARN  push: no VAPID keys, so this run made a pair, which the next start replaces (a browser subscribed with it then subscribes again); to keep it, put these in .env, a line each: VAPID_PUBLIC_KEY=BKx… VAPID_PRIVATE_KEY=3q…
   ```

   A pair made for a run is gone when the server restarts (`rocx dev` restarts it at each change to
   the server's code), and a browser subscribed with it then has to subscribe again (its button
   shows off). Put the two settings in the app's `.env`, a line each, to keep it. Without
   `VAPID_SUBJECT` such a server tells push services `mailto:dev@example.com`, and says so on its
   log.

   A deployed server needs all three in its environment: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`
   (secret) and `VAPID_SUBJECT` (`mailto:` and an address, or an `https:` URL). Give it a pair of
   its own, from the running dev server, which answers a new one each time it is asked:

   ```sh
   curl -s localhost:8080/__rocx/push/keys
   VAPID_PUBLIC_KEY=BNc…
   VAPID_PRIVATE_KEY=Hw…
   ```

   (`npx web-push generate-vapid-keys` makes a pair too.) A browser that subscribed with one public
   key can only be sent to with that pair. Outside `--dev`, if a key or the subject is missing, or
   the keys don't belong together, the server doesn't start, and says why and how to make a pair.

2. **The plugin.** Name the package in the app's header and list its plugin, with the jobs plugin
   (`packages/jobs`), whose workers run the `push.deliver` job:

   ```roc
   app [program] { jobs: "…/packages/jobs/main.roc", pf: platform "…/server/platform/main.roc", push: "…/packages/push/main.roc" }

   import jobs.Job
   import push.Push
   import Generated/App

   program = App.program({
   	# …
   	plugins: [Job.plugin({ jobs: App.jobs }), Push.plugin({ middleware: Middleware.none({}) })],
   })
   ```

   That is all the server needs: the endpoints (`GET /push/key`, `POST /push/subscribe`,
   `POST /push/unsubscribe`), the table, the job, the service worker and the page's script, and
   under `--dev` `GET /__rocx/push/keys`. The plugin needs a database.

3. **A button**, on any page:

   ```roc
   import push.PushButton

   <PushButton api="/push" />
   ```

4. **Sending**, from a job or an endpoint on the server:

   ```roc
   import push.Notification
   import push.Options
   import push.Push

   Push.notify!(user_id, { ..Notification.new("New reply", "Ada answered your question"), url: "/questions/42" }, Options.defaults)
   ```

`example/` is a small app with every step: a page with `<PushButton>` and a button that notifies
everyone.

### Plugin options

`Push.plugin(setup)` takes `{ middleware, at ?? "/push", owner ?? (|_| "") }`:

- `middleware` is what the endpoints are behind, which the app must say: its
  `routes/+middleware.roc` isn't around a plugin's routes (D-114). `Middleware.none({})` for a site
  of visitors; the middleware that knows who is signed in for one with accounts (below).
- `at` is where the endpoints are: `Push.plugin({ at: "/notifications" })` answers
  `GET /notifications/key` and so on (then `<PushButton api="/notifications" />`).
- `owner` says whose a subscription is: a function from the context `middleware` handed on
  to the app's id for the user, as text. An app with accounts gives
  `Push.plugin({ middleware: Middlewares.member, owner: |context| context.member })`, and `notify!(member, …)` sends to that user's
  browsers. Without it, every subscription is a visitor's (`""`).

## Sending

```roc
# To one user's browsers (every one they subscribed in), or to everyone: how many were queued.
Push.notify!(user_id, Notification.new("Your export is ready", "orders.csv, 3 MB"), Options.defaults)
Push.broadcast!({ ..Notification.new("Back online", "The maintenance is over"), tag: "status" }, { ..Options.defaults, ttl: 3600 })

# A status that changes: only the latest one waits at the push service.
Push.notify!(user_id, Notification.new("Order 17", "Shipped"), { ttl: 86_400, urgency: Normal, topic: "order-17" })
```

`notify!` and `broadcast!` check the options' topic and the notification's size, then queue a
`push.deliver` job for each subscription, and answer how many (`Try(U64, Str)`). Inside a
transaction (`Db.transaction!`), the jobs are queued only if it commits. A jobs worker sends each:

| The push service answers | The job |
|---|---|
| 201 (any 2xx) | is done; the subscription's `last_sent_at` is set |
| 404 or 410 | deletes the subscription: the browser unsubscribed, or it expired |
| 408, 429 or 5xx with `Retry-After` | queues itself again for then (five times at most), if the message's TTL lasts |
| 408, 429 or 5xx without it, or no answer | fails the attempt; the worker tries again, waiting longer each time (five attempts) |
| 400, 401, 403, 413, anything else | logs it and notes it on the subscription (`last_error`); sending again wouldn't help |

A retry sends the TTL that is left, so a message never outlives its TTL; a message whose TTL ran
out before it was sent is dropped, with a log line. A 403 doesn't delete the subscription: push
services answer 403 when the VAPID keys are wrong, and a mistake in the server's settings shouldn't
delete every subscription.

### A notification and its options

| `Notification` field | Is |
|---|---|
| `title : Str` | the notification's first line (empty: the site's host name) |
| `body : Str` | the text under it |
| `url : Str` | the page a click opens, on this site only (empty: the front page) |
| `tag : Str` | a newer notification with the same tag replaces this one |
| `icon : Str` | an image's URL |

`Notification.new(title, body)` leaves the rest empty; empty fields are left out of the JSON.

| `Options` field | Is |
|---|---|
| `ttl : U64` | seconds a push service keeps the message for an offline browser; 0 is now or never; more than four weeks (`Options.max_ttl`) is sent as four weeks |
| `urgency : [VeryLow, Low, Normal, High]` | how soon it must arrive; a phone on battery may hold the low ones back |
| `topic : Str` | a newer message with the same topic replaces one still waiting; 32 characters at most, of letters, digits, `-` and `_` |

`Options.defaults` is a day, `Normal`, and no topic.

## API

### Plain Roc

On no platform, checked by `expect`s (`roc test packages/push/main.roc`). The browser's half of an
app sees these too (`browser.roc` exposes them). HMAC, HKDF and base64url are `packages/crypto`'s,
which this package names itself: an app names `push` alone.

| Module | What it has |
|---|---|
| `Subscription` | A browser's subscription (`{ endpoint, p256dh, auth }`, the keys as bytes): `parse` (the page's JSON), `from_body` (an endpoint's body, `Subscription.Body`), `from_text` (a table row), `to_text`, `to_json`; `services` and `known_service` (is the endpoint at Chrome's, Firefox's, Safari's or Edge's push service, over `https:`?) |
| `Notification` | What the service worker shows: `{ title, body, url, tag, icon }`; `new(title, body)`, `to_json`, `data` (the JSON's bytes) |
| `Options` | `{ ttl, urgency, topic }`; `defaults`, `max_ttl`, `check` (the topic: `BadTopic`), `headers` (`TTL`, `Urgency`, `Topic`), `remaining` (the TTL left for a retry, or `Expired`) |
| `Delivery` | `request` (the POST to a subscription's endpoint: `Authorization`, the options' headers, and the encrypted body); `outcome` (an answer as `Delivered`, `Gone`, `RetryAfter(ms)`, `Retry(why)` or `Refused(why)`), `retry_after` (seconds or an HTTP date), `http_date` |
| `Vapid` | RFC 8292: `Keys` and `from_text` (from `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT`), `contact`, `audience` (the endpoint's origin), `claims` (valid 12 hours), `header_json`, `claims_json`, `signing_input`, `token`, `authorization` (`vapid t=…, k=…`) |
| `WebPush` | RFC 8291: `key_info`, `input_keys`, `prepare` (everything before the AES: the header, the key, the nonce, the record), `body` (the header and the sealed record), `max_data` (3993 bytes), `record_size` |
| `Ece` | RFC 8188's `aes128gcm` coding: `header`, `parse_header`, `pad`, `unpad`, `keys`, `nonce` (record `n`'s), `key_info`, `nonce_info`, `tag_size` |
| `PushState` | Where a browser stands, as the page's script reports it: `Unknown`, `Unsupported`, `Blocked`, `Off`, `Working`, `On`, `Failed(why)`; `parse`, `to_str`, `is_on`, `is_stuck`, `label` and `note` (what `<PushButton>` shows) |

### The server's part

On the server platform (`Db`, `Http`, `Plugin`, `Env`) and `packages/jobs` (`Job`), which the
package names in its header (`main.roc`); the browser's half doesn't see these. `owner` is the app's
id for a user, as text, or `""` for a visitor.

| Module | What it has |
|---|---|
| `Push` | `plugin(setup)`, the plugin ([options](#plugin-options)). `subscribe!(body, owner)`: saves a subscription the page posted, if its endpoint is at a browser's push service (`Invalid(why)` if not). `unsubscribe!(endpoint, owner)`. `notify!(owner, notification, options)` and `broadcast!(notification, options)`: queue a `deliver` job per subscription, and answer how many. `public_key!` and `keys!` (from the environment; under `--dev` without keys, the pair the run made, kept in `Kv`). `deliver`: the job (`push.deliver`, 5 attempts, a minute each). `send!(keys, subscription, data, options)`: one attempt, encrypted (`P256.ecdh!`, `AesGcm.seal_with_nonce!`) and signed (`P256.sign!`), and what the push service's answer means |
| `PushStore` | The `push_subscriptions` table: `save!` (one row per endpoint; subscribing again updates it), `remove!`, `remove_id!`, `find!`, `of_owner!`, `everyone!`, `delivered!`, `refused!`. Each statement runs on Postgres and SQLite; `delivered!` asks `Db.backend!` which to run |

The table's migration is `migrations/0001_push_subscriptions.sql` on Postgres and
`migrations/0001_push_subscriptions_sqlite.sql` on SQLite (whose times are milliseconds). Each makes
the table only if it isn't there, so a table an app made by hand is kept.

### The browser's part

- `components/PushButton.rocx`, `<PushButton api="/push" />` (`rocx build` copies `components/`
  into the app): turns notifications on and off, and says why it can't (blocked, or a browser
  without Web Push: on an iPhone or iPad, a site not added to the Home Screen). `aria-pressed` says
  whether they are on; the note beside it is `aria-live`.
- `static/push.js`, the page's script, which every page loads (`/rocx/plugins/push/push.js`): the
  `push.subscribe` and `push.unsubscribe` effects the button calls with `Browser.call!`.
  Subscribing asks permission first, while the click still counts as the user's (browsers prompt
  only then), then registers the service worker at the site's root, subscribes with the server's
  key (making a new subscription if the server's key changed), and posts the subscription. Since
  `Browser.call!` answers nothing, it reports each step with a `pushstate` event on every
  `[data-push-state]` element. Once the page is awake it reports where the browser stands, and
  sends the server its subscription again once a visit. On a site served under a base path
  (`/rocx/`), every URL is under it.
- `static/push-sw.js`, the service worker, which the plugin serves at the site's root
  (`/push-sw.js`, a file `at: Root`), so its scope is the whole site. It shows the notification a
  message carries; a click focuses a tab at its URL, or opens one (this site's pages only); when the
  push service replaces a subscription (`pushsubscriptionchange`), it tells the server.

## Safety

- The server sends a request to whatever URL a subscription names, so `Push.subscribe!` takes only
  endpoints at the browsers' push services (`Subscription.services`), over `https:`. When the server
  runs with `--dev`, it also takes an `http:` one on this machine (`localhost`, `127.0.0.1`), for a
  stand-in push service. It refuses a key that isn't a point on P-256 (an ECDH with it is tried), so
  a subscription it keeps can be sent to.
- A new ECDH key pair and a new salt for each message, as RFC 8291 asks; the pair's private key is
  the host's for that one call, and never reaches Roc.
- The private key never leaves the server; the page gets only the public key. Under `--dev` alone
  a pair is logged (one the run made) and answered (at `/__rocx/push/keys`), on the developer's
  machine; a deployed server never makes, logs or answers one.
- A click on a notification opens only this site's pages.
- Messages are encrypted for the browser: the push service sees only bytes.

## Status

What works today:

- Everything that is plain Roc, checked by `expect`s against the RFCs' own examples: base64url
  keys, the VAPID token's header, claims and signing input (RFC 8292), the content coding's header,
  records, padding, keys and nonces (RFC 8188), the message's key derivation (RFC 8291, appendix A,
  reproduced up to the AES), the request's headers (RFC 8030), reading a `PushSubscription`'s
  JSON, and what each answer from a push service means. The server platform's tests check the rest
  (server/test/server.test.mjs): `AesGcm.seal_with_nonce!` gives RFC 8291's and RFC 8188's
  ciphertexts, `P256.ecdh!` agrees with Node's ECDH, Node verifies `P256.sign!`'s signatures, and
  `P256.generate!`'s pairs are pairs Node takes (its public key the private key's).
- The plugin, in `example/test/push.test.mjs`, which builds the example on SQLite (always) and on
  Postgres (when `DATABASE_URL` is set) and asks it over HTTP: the key, subscribing (and a
  subscription at an unknown service, or with a key off the curve, refused), each of `PushStore`'s
  statements, and unsubscribing. Sending: a broadcast is delivered to a push service the test runs
  (`--dev` lets a subscription's endpoint be on this machine), which plays the browsers too: it
  makes each subscription's keys with Node's crypto, checks each request's VAPID token (its claims,
  and its ES256 signature against `VAPID_PUBLIC_KEY`), decrypts each message as RFC 8291 says, and
  checks the notification inside. It answers 201, 410 (the subscription is deleted) or 403 (noted
  on its row). The server's HTTPS proxy is that push service, which refuses every connection, so
  nothing reaches a real one. VAPID keys that aren't a pair stop the server as it starts, and so do
  none (or one alone, or no subject) without `--dev`, saying how to make a pair. Under `--dev` with
  none, the server makes a pair, logs it (Node checks it is one), sends with it (the push service
  checks the token against the logged key) and tells push services `mailto:dev@example.com`;
  `/__rocx/push/keys` answers a new pair each time. In
  Chromium (when there is one), behind a guard that refuses every script the app would serve, the
  plugin's script and service worker come through, the worker registers at the root with the whole
  site as its scope, and the button subscribes (the browser's push service stood in for, as headless
  Chromium has none). Run it with `node --test 'packages/push/example/test/*.test.mjs'`.

No test sends to a real push service (Google's, Mozilla's, Apple's or Microsoft's).

What waits on a proposal (`PROPOSALS.md`):

- **Jobs that give up, or come back at a set time.** Today a refused message ends its job as done,
  and a `Retry-After` queues a copy of the job for then.
- **`Browser.call!` with an answer**, so `<PushButton>` could hear how a click went without the
  `pushstate` event.

Limits:

- A message holds 3993 bytes of data, the notification's JSON (`WebPush.max_data`); `notify!` and
  `broadcast!` refuse a longer one.
- One record per message, as RFC 8291 asks; `WebPush.prepare` supports padding, but the plugin
  doesn't use it.
