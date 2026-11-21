# push

Web Push notifications for Roc Solid apps. A page asks the user's permission and subscribes; the
server keeps the subscription; later the server sends a notification, and the browser shows it even
with every tab of the site closed.

```roc
import push.Notification
import push.Options
import Push

# Somewhere on the server: a job, an endpoint.
Push.notify!(user_id, { ..Notification.new("New reply", "Ada answered your question"), url: "/questions/42" }, Options.defaults)
```

```roc
import push.PushButton

<PushButton api="/push" />
```

## Status

What works today:

- Everything that is plain Roc, checked by `expect`s against the RFCs' own examples:
  base64url keys, the VAPID token's header, claims and signing input (RFC 8292), the content coding's
  header, records, padding, keys and nonces (RFC 8188), the message's key derivation (RFC 8291,
  appendix A, reproduced up to the AES), the request's headers (RFC 8030), reading a
  `PushSubscription`'s JSON, and what each answer from a push service means.
- The server's glue (`server/`): the subscriptions table and its migration, saving and forgetting
  subscriptions, and a job that delivers a message to each, with retries. Built into an app and run
  against Postgres and a stand-in push service, it sends the request RFC 8030 and RFC 8291 describe
  and handles every answer.
- The browser's part: the service worker, the script that subscribes from a click, and
  `<PushButton>`.

What waits on a proposal (PROPOSALS.md):

- **Sending.** The server's host has no P-256 (the ECDH that encrypts a message, the ECDSA that
  signs the VAPID token) and only AES-256-GCM with random nonces, and Web Push needs AES-128-GCM
  with a derived nonce. Until the host has them, every delivery fails, saying so. The host functions
  are sketched on `ring`, which the host links already, and pass the RFC vectors.
- **Installing.** A package can't yet give an app server-only modules, migrations or static files,
  so today the glue is copied by hand (see Setting up).

## Three parts

**The pure package** (`main.roc`): plain Roc on no platform. `roc test packages/push/main.roc`
runs its `expect`s. HKDF, HMAC and base64url are `packages/crypto`'s, which this package names
itself: an app names `push` alone.

| Module | What it does |
|---|---|
| `Subscription` | A browser's subscription: `parse` (the page's JSON), `from_body` (an endpoint's body, `Subscription.Body`), `from_text` (a table row), `to_text`, `to_json`; `known_service` (is the endpoint at Chrome's, Firefox's, Safari's or Edge's push service?) |
| `Notification` | What the service worker shows: `title`, `body`, `url` (opened on a click), `tag` (a newer one replaces an older), `icon`; `Notification.new(title, body)`, `to_json`, `data` |
| `Options` | `ttl` (seconds a push service keeps it for an offline browser), `urgency` (`VeryLow`, `Low`, `Normal`, `High`), `topic` (a newer message replaces a waiting one); `defaults` (a day, `Normal`, none), `check`, `headers`, `remaining` (the TTL left for a retry) |
| `Delivery` | `request` (the POST to a subscription's endpoint); `outcome` (an answer: `Delivered`, `Gone`, `RetryAfter(ms)`, `Retry(why)`, `Refused(why)`), `retry_after`, `http_date` |
| `Vapid` | RFC 8292: `Keys` and `from_text` (from `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT`), `audience` (the endpoint's origin), `claims` (12 hours), `signing_input`, `token`, `authorization` (`vapid t=…, k=…`) |
| `WebPush` | RFC 8291: `key_info`, `input_keys`, `prepare` (everything before the AES: the header, the key, the nonce, the record), `body` (the header and the sealed record), `max_data` (3993 bytes) |
| `Ece` | RFC 8188's `aes128gcm` coding: `header`, `parse_header`, `pad`, `unpad`, `keys`, `nonce` (record `n`'s) |
| `PushState` | Where a browser stands (`On`, `Off`, `Blocked`, `Unsupported`, `Working`, `Failed(why)`), as the page's script says it; what `<PushButton>` shows |

**The server's glue** (`server/`): modules that import the server platform (`Db`, `Http`, `Job`,
`Env`), so they can't be in the package; and `migrations/0001_push_subscriptions.sql`.

| Module | What it does |
|---|---|
| `Push` | `subscribe!(body, owner)`, `unsubscribe!(endpoint, owner)`: for the app's endpoints. `notify!(owner, notification, options)`, `broadcast!(notification, options)`: queue a `deliver` job per subscription, how many. `public_key!`, `keys!` (from the environment). `deliver`: the job. `send!`: one attempt, given the host's primitives (`Primitives`) |
| `PushStore` | The `push_subscriptions` table: `save!` (one row per endpoint), `remove!`, `remove_id!`, `find!`, `of_owner!`, `everyone!`, `delivered!`, `refused!` |

`owner` is the app's id for a user, as text, or `""` for a visitor.

**The browser's part** (`static/`, `components/`):

- `static/push-sw.js`, the service worker: shows the notification a message carries; a click
  focuses a tab at its URL, or opens one (this site's pages only); when the push service replaces a
  subscription (`pushsubscriptionchange`), it tells the server.
- `static/push.js`, the page's script: the `push:subscribe` and `push:unsubscribe` effects a
  handler calls with `Browser.call!`. Subscribing asks permission first, while the click still
  counts as the user's (browsers prompt only then), then registers the service worker at `/`,
  subscribes with the server's key, and posts the subscription. Once the page is awake it says where
  the browser stands, and sends the server its subscription again once a visit.
- `<PushButton api="/push" />`: turns notifications on and off, and says why it can't (blocked, or a
  browser with no Web Push: on an iPhone or iPad, a site not added to the Home Screen).

## Setting up

`example/` is a small app with every step below: a page with `<PushButton>` and a button that
notifies everyone, and the three endpoints. Copy the glue into it (step 3) to build it. The docs
site's page for this package shows its files.

1. **Keys.** `node packages/push/vapid-keys.mjs` prints a pair. Give the server
   `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` (secret) and `VAPID_SUBJECT` (`mailto:` and an address,
   or an `https:` URL) in its environment. Browsers subscribed with one public key can only be sent
   to with that pair.

2. **The package**, in the app's header, as for any package:

   ```roc
   app [program] { push: "../packages/push/main.roc", pf: platform "…" }
   ```

3. **The glue, by hand for now**: copy `server/Push.roc` and `server/PushStore.roc` into the app's
   directory, and `migrations/0001_push_subscriptions.sql` into its `migrations/`. `rocx build`
   finds the `deliver` job and the migration there, as it finds the app's own.

4. **Three endpoints**, where `<PushButton api="/push">` looks for them:

   ```roc
   # routes/push/key/+server.roc
   get! : { request : Server.Request, params : {}, context : c } => Try(Str, Endpoint.Refusal)
   get! = |_| {
       key = Push.public_key!({})
       if key.is_empty() Err(Status(503, "the server has no VAPID_PUBLIC_KEY")) else Ok(key)
   }

   # routes/push/subscribe/+server.roc
   post! : { request : Server.Request, params : {}, context : c, body : Subscription.Body } => Try({}, Endpoint.Refusal)
   post! = |{ body, .. }|
       match Push.subscribe!(body, "") {     # an app with accounts gives its user's id
           Ok({}) => Ok({})
           Err(Invalid(why)) => Err(BadRequest(why))
           Err(DbErr(why)) => Err(Status(500, why))
       }

   # routes/push/unsubscribe/+server.roc
   post! : { request : Server.Request, params : {}, context : c, body : { endpoint : Str } } => Try({}, Endpoint.Refusal)
   post! = |{ body, .. }|
       match Push.unsubscribe!(body.endpoint, "") {
           Ok({}) => Ok({})
           Err(DbErr(why)) => Err(Status(500, why))
       }
   ```

5. **The browser's files.** The layout loads the script in its `<head>`, and the server serves
   `static/` beside the app's own files, so that the service worker is `/push-sw.js` and its scope
   the whole site:

   ```roc
   <script type="module" src="/push.js"></script>
   ```

   ```sh
   ./server --static build/client/static --static ../packages/push/static --database-url …
   ```

6. **A button**, anywhere: `<PushButton api="/push" />`.

## Sending

```roc
# To one user's browsers (every one they subscribed in), or to everyone: how many were queued.
Push.notify!(user_id, Notification.new("Your export is ready", "orders.csv, 3 MB"), Options.defaults)
Push.broadcast!({ ..Notification.new("Back online", "The maintenance is over"), tag: "status" }, { ..Options.defaults, ttl: 3600 })

# A status that changes: only the latest one waits at the push service.
Push.notify!(user_id, Notification.new("Order 17", "Shipped"), { ttl: 86_400, urgency: Normal, topic: "order-17" })
```

Each subscription gets a job (`push.deliver`), queued in the caller's transaction when there is one.
A worker sends it:

| The push service answers | The job |
|---|---|
| 201 (any 2xx) | is done; the subscription's `last_sent_at` is set |
| 404 or 410 | deletes the subscription: the browser unsubscribed, or it expired |
| 429 or 5xx with `Retry-After` | queues itself again then (five times at most), if the message's TTL lasts |
| 408, 429 or 5xx, or no answer | fails the attempt: the worker tries again, waiting longer each time (five attempts) |
| 400, 401, 403, 413, anything else | logs it, and notes it on the subscription (`last_error`); sending again wouldn't help |

A retry sends the TTL that is left, so a message never outlives its TTL. A 403 doesn't delete the
subscription: push services say it when the VAPID keys are wrong, and a mistake in the server's
settings shouldn't delete every subscription.

## Safety

- The server sends a request to whatever URL a subscription names, so `Push.subscribe!` takes only
  endpoints at browsers' push services (`Subscription.services`), `https:` only. Under `--dev` it
  also takes one on this machine (`http://localhost`, `http://127.0.0.1`), for a stand-in push
  service.
- The private key never leaves the server; the page gets only the public key.
- A notification's click opens only this site's pages.
- Messages are encrypted for the browser: the push service sees bytes.

## Limits, for now

- No sending until the host has P-256 and AES-128-GCM (PROPOSALS.md).
- A message holds 3993 bytes of data, the notification's JSON (`WebPush.max_data`).
- One record per message, as RFC 8291 asks; padding is supported by `WebPush.prepare` but not used.
- `<PushButton>` hears how a click went through a DOM event (`pushstate`) rather than an answer
  from `Browser.call!`, which answers nothing yet (PROPOSALS.md).
