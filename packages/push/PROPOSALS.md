# push: proposals

What packages/push needs from outside its folder. Sections 2 and 3 are done (push is a plugin,
D-051, on plugins' files and scripts, D-050); the rest isn't implemented. Each section says what the
package does meanwhile.

1. [P-256 and AES-128-GCM in the host](#1-p-256-and-aes-128-gcm-in-the-host): the crypto Web Push
   can't send without.
2. [Server-only modules in packages](#2-server-only-modules-in-packages): the glue and its
   migration. Done: `Push.plugin` (D-033, D-051).
3. [Static files in packages](#3-static-files-in-packages): the service worker, served at the
   site's root. Done: the plugin's files (D-050).
4. [Jobs: give up, or come back at a time](#4-jobs-give-up-or-come-back-at-a-time): a refusal that
   isn't retried, and `Retry-After`.
5. [`Browser.call!` with an answer](#5-browsercall-with-an-answer): how `<PushButton>` hears how a
   click went.

[Open questions](#open-questions) for the user are at the end.

---

## 1. P-256 and AES-128-GCM in the host

**Problem.** A Web Push message needs three things the server's host doesn't do:

- **ECDH on P-256** (RFC 8291): for each message, a new key pair, and the secret it shares with the
  subscription's `p256dh` key.
- **ES256 signatures** (RFC 8292): the VAPID token is a JWT signed with ECDSA on P-256 and SHA-256,
  by the server's private key. JWS writes the signature as 64 bytes, `r` then `s`, not DER.
- **AES-128-GCM with a given nonce** (RFC 8188): the content key is 16 bytes and the nonce is
  derived from the salt. `AesGcm.seal!` is AES-256 only (it refuses a 16-byte key) and draws a
  random nonce, which it puts in front of the ciphertext. Neither fits.

Elliptic-curve code in Roc is ruled out: it would be slow, not constant-time, and unreviewed.

**Options.**

1. **`ring`, which the host links already** (0.17.14 in Cargo.lock). It has everything Web Push
   needs:
   - `aead::AES_128_GCM` and `LessSafeKey` with the caller's nonce.
   - `signature::EcdsaKeyPair::from_private_key_and_public_key` takes raw keys (the 32-byte scalar,
     the 65-byte point), and `ECDSA_P256_SHA256_FIXED_SIGNING` gives `r‖s`.
   - `agreement::EphemeralPrivateKey` with `agree_ephemeral` is ECDH with a key pair made for one
     agreement, which is what RFC 8291 asks for.

   What ring can't do: ECDH with a private key the caller gives (so RFC 8291's ECDH step can't be
   replayed with its fixed keys, and is tested by a round trip instead), deterministic signatures
   (ring's are randomized, so tested by verifying), or handing back a generated private key (it
   comes out of the PKCS#8 document ring writes).
2. **The `p256` crate (RustCrypto).** It does ECDH with given keys (RFC 8291's whole appendix
   replays), RFC 6979 deterministic signatures, and raw key export. But it is a new dependency
   tree (`p256`, `elliptic-curve`, `ecdsa`, `primeorder`, `rfc6979`, `sha2`, `hmac`, …) for
   abilities only tests need.
3. **OpenSSL.** No: the host avoids C dependencies beyond ring's own.

**Recommended: 1.** Two new platform pieces: a `P256` module, and two functions in `AesGcm`. Keys
are bytes. A public key is an uncompressed point: 65 bytes, `0x04`, then `x` and `y`. A private key
is its 32-byte scalar. Text is base64url (`Base64.url_encode`), as the browser and
`web-push generate-vapid-keys` write them.

```roc
## server/platform/P256.roc (new)
import Host

## Elliptic-curve keys on P-256 (secp256r1), by the host (`ring`): Web Push's encryption (ECDH) and
## its VAPID tokens (ES256), and any JWT signed with ES256. A public key is an uncompressed point
## (65 bytes: 4, then x and y), a private key its 32-byte scalar.
P256 := [].{

	## A new key pair (a VAPID pair).
	generate! : {} => { private_key : List(U8), public_key : List(U8) }
	generate! = |{}| Host.p256_generate!({})

	## ECDH with a key pair made for this call alone, as RFC 8291 wants one per message: its public
	## key, and the 32-byte secret (the shared point's x) it shares with `peer`. `BadKey` unless
	## `peer` is an uncompressed point on the curve.
	ecdh_ephemeral! : List(U8) => Try({ public_key : List(U8), shared : List(U8) }, [BadKey])
	ecdh_ephemeral! = |peer| Host.p256_ecdh_ephemeral!(peer).map_err(|_| BadKey)

	## ES256: the 64-byte signature (`r` then `s`, as JWS writes it) of `message` by
	## `private_key`, whose public key is `public_key`. `BadKey` when they aren't a pair.
	sign! : List(U8), List(U8), List(U8) => Try(List(U8), [BadKey])
	sign! = |private_key, public_key, message| Host.p256_sign!(private_key, public_key, message).map_err(|_| BadKey)

	## Whether `signature` (64 bytes) is ES256's of `message` by `public_key`'s private key.
	verify! : List(U8), List(U8), List(U8) => Bool
	verify! = |public_key, message, signature| Host.p256_verify!(public_key, message, signature)
}
```

```roc
## server/platform/AesGcm.roc: two more, beside seal! and open!
	## AES-GCM with the caller's 12-byte nonce, which a protocol derives (RFC 8188) and must never
	## repeat under a key: AES-128 for a 16-byte key, AES-256 for a 32-byte one. The ciphertext,
	## then the 16-byte tag; nothing in front.
	seal_with! : List(U8), List(U8), List(U8) => Try(List(U8), [BadKey, BadNonce])

	## What `seal_with!` sealed, under the same key and nonce; `Forged` otherwise.
	open_with! : List(U8), List(U8), List(U8) => Try(List(U8), [BadKey, BadNonce, Forged])
```

```roc
## server/platform/Host.roc: the host's side ("bad key", "bad nonce", "forged" as the errors)
	p256_generate! : {} => { private_key : List(U8), public_key : List(U8) }
	p256_ecdh_ephemeral! : List(U8) => Try({ public_key : List(U8), shared : List(U8) }, Str)
	p256_sign! : List(U8), List(U8), List(U8) => Try(List(U8), Str)
	p256_verify! : List(U8), List(U8), List(U8) => Bool
	aes_gcm_seal_with! : List(U8), List(U8), List(U8) => Try(List(U8), Str)
	aes_gcm_open_with! : List(U8), List(U8), List(U8) => Try(List(U8), Str)
```

They are wired as `aes_gcm_seal!` is: `"roc_host_p256_sign": Host.p256_sign!` and so on in
server/platform/main.roc, `P256` in its `exposes`, the glue regenerated, and in
server/host/src/hosted.rs the functions below, each wrapped as `roc_host_aes_gcm_seal` is
(`taken_bytes`, `bytes_or_error(guarded(…))`).

```rust
use ring::{aead, agreement, rand::SystemRandom, signature};

pub fn p256_ecdh_ephemeral(peer: &[u8]) -> Result<(Vec<u8>, Vec<u8>), String> {
    if peer.len() != 65 || peer[0] != 4 {
        return Err("bad key".into());
    }
    let rng = SystemRandom::new();
    let mine = agreement::EphemeralPrivateKey::generate(&agreement::ECDH_P256, &rng).map_err(|_| "no random bytes".to_string())?;
    let public = mine.compute_public_key().map_err(|_| "no public key".to_string())?.as_ref().to_vec();
    let shared = agreement::agree_ephemeral(mine, &agreement::UnparsedPublicKey::new(&agreement::ECDH_P256, peer), |secret| secret.to_vec())
        .map_err(|_| "bad key".to_string())?;
    Ok((public, shared))
}

pub fn p256_sign(private: &[u8], public: &[u8], message: &[u8]) -> Result<Vec<u8>, String> {
    let rng = SystemRandom::new();
    let pair = signature::EcdsaKeyPair::from_private_key_and_public_key(&signature::ECDSA_P256_SHA256_FIXED_SIGNING, private, public, &rng)
        .map_err(|_| "bad key".to_string())?;
    Ok(pair.sign(&rng, message).map_err(|_| "no random bytes".to_string())?.as_ref().to_vec())
}

pub fn p256_verify(public: &[u8], message: &[u8], signature: &[u8]) -> bool {
    signature::UnparsedPublicKey::new(&signature::ECDSA_P256_SHA256_FIXED, public).verify(message, signature).is_ok()
}

pub fn p256_generate() -> Result<(Vec<u8>, Vec<u8>), String> {
    let rng = SystemRandom::new();
    let document = signature::EcdsaKeyPair::generate_pkcs8(&signature::ECDSA_P256_SHA256_FIXED_SIGNING, &rng).map_err(|_| "no random bytes".to_string())?;
    let pair = signature::EcdsaKeyPair::from_pkcs8(&signature::ECDSA_P256_SHA256_FIXED_SIGNING, document.as_ref(), &rng).map_err(|_| "no key".to_string())?;
    // ring hands back no scalar: it is the ECPrivateKey's OCTET STRING (version 1: 02 01 01, then 04 20).
    let bytes = document.as_ref();
    let at = bytes.windows(5).position(|w| w == [0x02, 0x01, 0x01, 0x04, 0x20]).ok_or("no private key")? + 5;
    Ok((bytes[at..at + 32].to_vec(), signature::KeyPair::public_key(&pair).as_ref().to_vec()))
}

fn aes(key: &[u8]) -> Result<aead::LessSafeKey, String> {
    let algorithm = match key.len() {
        16 => &aead::AES_128_GCM,
        32 => &aead::AES_256_GCM,
        _ => return Err("bad key".into()),
    };
    Ok(aead::LessSafeKey::new(aead::UnboundKey::new(algorithm, key).map_err(|_| "bad key".to_string())?))
}

pub fn aes_gcm_seal_with(key: &[u8], nonce: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, String> {
    let key = aes(key)?;
    let nonce = aead::Nonce::try_assume_unique_for_key(nonce).map_err(|_| "bad nonce".to_string())?;
    let mut sealed = plaintext.to_vec();
    key.seal_in_place_append_tag(nonce, aead::Aad::empty(), &mut sealed).map_err(|_| "too long to seal".to_string())?;
    Ok(sealed)
}

pub fn aes_gcm_open_with(key: &[u8], nonce: &[u8], sealed: &[u8]) -> Result<Vec<u8>, String> {
    let key = aes(key)?;
    let nonce = aead::Nonce::try_assume_unique_for_key(nonce).map_err(|_| "bad nonce".to_string())?;
    let mut buffer = sealed.to_vec();
    Ok(key.open_in_place(nonce, aead::Aad::empty(), &mut buffer).map_err(|_| "forged".to_string())?.to_vec())
}
```

This code is tested, outside the repo: a scratch crate on `ring = "0.17"` with these functions,
`cargo test --offline`, 8 tests passing. The tests to carry into the host (all values base64url):

| Function | Vector | Expect |
|---|---|---|
| `aes_gcm_seal_with` | RFC 8291 appendix A: key `oIhVW04MRdy2XN9CiKLxTg`, nonce `4h_95klXJ5E_qnoN`, "When I grow up, I want to be a watermelon" and `0x02` | `8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEsbI_0LpXMuGvnzQ`, and `open_with` gives the record back |
| `aes_gcm_seal_with` | RFC 8188 §3.1: key `_wniytB-ofscZDh4tbSjHw`, nonce `Bcs8gkIRKLI8GeI8`, "I am the walrus" and `0x02` | the example's body after its 21-byte header |
| `aes_gcm_*_with` | a 15-byte key; an 11-byte nonce; one flipped bit; a 32-byte key | "bad key"; "bad nonce"; "forged"; AES-256 round trip |
| `p256_verify` | RFC 8292's token: its signing input, signature `i3CYb7t4…vtoD1oA`, key `BA1Hxzyi…ClBPs` | true; false for another message |
| `p256_sign` | RFC 8291's application server pair (`yfWPiYE-…QoRw`, `BP4z9KsN…3jl7A8`) | 64 bytes that `p256_verify` accepts; "bad key" with another public key, or a 31-byte scalar |
| `p256_ecdh_ephemeral` | a peer key from `ring`'s own ephemeral pair | `(65 bytes from 4, 32 bytes)`, the same secret the peer computes; a new key pair each call |
| `p256_ecdh_ephemeral` | 64 bytes; a 65-byte point off the curve | "bad key" |
| `p256_generate` | | a 32-byte scalar and a 65-byte point that sign and verify; a new pair each call |

The package checks the rest of RFC 8291 already: from the ECDH secret on, `WebPush.prepare`
reproduces the appendix's `PRK_key`, `key_info`, IKM, PRK, CEK, nonce, header and record, and
`WebPush.body` with the sealed bytes above gives the appendix's message exactly.

**What in the package depends on it.** `Push.host` (Push.roc) is the only place. Today each
of its three functions answers "the server's host has no P-256 or AES-128-GCM yet…", and the
delivery job fails with that. With the proposal it becomes:

```roc
host = {
	ecdh!: |peer| P256.ecdh_ephemeral!(peer).map_ok(|{ public_key, shared }| { as_public: public_key, ecdh_secret: shared }).map_err(|_| "the subscription's p256dh isn't a P-256 point"),
	seal!: |key, nonce, record| AesGcm.seal_with!(key, nonce, record).map_err(|_| "AES-128-GCM refused the key or the nonce"),
	sign!: |private_key, public_key, message| P256.sign!(private_key, public_key, message).map_err(|_| "VAPID_PRIVATE_KEY and VAPID_PUBLIC_KEY aren't a pair"),
}
```

`Vapid.from_text` could then also check that the two keys are a pair (sign and verify once), and
`vapid-keys.mjs` could become `P256.generate!` behind a dev page or a CLI command.

**How it could be undone.** The additions are new functions and a new module, and nothing else
calls them. Removing them removes `Push.host`'s implementation, and the package goes back to
failing every delivery with a reason.

---

## 2. Server-only modules in packages

**Status (2026-11-23).** Done another way: push is a plugin (D-051). The package names the server
platform in its header (D-033: `browser.roc` lists what the browser can compile), with `Push` and
`PushStore` beside the pure modules; `Push.plugin({})` brings the endpoints, the table, the job
(`Job.call` and `Job.adopt!`: the jobs plugin runs a plugin's kind of job) and the browser's files
(section 3). What follows is the problem as it was.

**Problem.** `server/Push.roc` and `server/PushStore.roc` import the server platform (`pf.Db`,
`pf.Http`, `pf.Job`, `pf.Env`, `pf.Log`, `pf.Random`, `pf.Time`) and the pure package
(`push.WebPush`, …). The package needs four things from an app:

- these modules in the server half only;
- its job (`deliver = Job.define_with("push.deliver", …)`) in `program.jobs`;
- its table (`migrations/0001_push_subscriptions.sql`) in `program.migrations`;
- its static files (section 3).

Today a package can do none of these. `components/*.rocx` are copied into both halves, and
`jobsIn` skips `Generated/`, so a job copied there wouldn't be found either.

**What I found trying it.** With the glue copied by hand into the app's directory (as `Push.roc`
and `PushStore.roc`, the SQL file into `migrations/`), `rocx build` already does the rest. It lists
`Job.handler(Push.deliver)` and the migration in `Generated/App.roc`, and the browser's copy
compiles: the page imports `../Push` only for a server function's body, and the copy drops that
import. Both halves pass `roc check`. The server built and ran against Postgres. The migration was
applied, the endpoints saved and refused subscriptions, and the job was queued, tried 5 times and
failed with the reason.

A second experiment: **a Roc package may name the server platform itself**, and the server half
uses it. `serverpkg/main.roc` was

```roc
package [Push, PushStore] { pf: platform "../../server/platform/main.roc", push: "../main.roc" }
```

and the server's `main.roc` named it as `push_server: "…"`, then `import push_server.Push` and
`jobs: [Job.handler(Push.deliver)]`. `roc check` passed, and a type error put in `PushStore.roc`
was reported. The compiler's rule ("a package names only the app's platform") holds, because the
server half is an app on that platform. What breaks is rocx's browser copy, which copies every
package in the header into the web platform's app.

**Options.**

1. **rocx build copies a package's `server/` into the server half only.** It goes to
   `Generated/<alias>/` beside the components, with `import push.X` rewritten to the app's alias
   (as `components/` is now), and is never copied into `--client`'s output. `jobsIn` also walks
   `Generated/<alias>/` for packages. `migrationsIn` adds the package's `migrations/*.sql` as
   `<alias>/<file>`, before the app's own (the app's may refer to a package's table). An app imports
   `Generated/push/Push` (or `push.Push`, rewritten, as components are). Nothing is pinned to a
   platform path, so it works as well with a platform from a URL.
2. **A server-only package that names the server platform** (`packages/push/server/main.roc`, as
   tried above). This already compiles. rocx build would need to drop such a package from the
   browser's header (any package whose `main.roc` names a platform other than the web one), find
   its jobs (`jobsIn` over its modules; `Generated/App` imports them as `push_server.Push`), and
   add its `migrations/`. The cost: the package names the platform by a path or URL, which must be
   exactly the app's, so a package and an app on different copies of the platform don't mix.
3. Keep copying by hand (today's README). This works, but every app carries a copy that drifts.

**Recommended: 1**, with 2 as a fallback if the coordinator prefers no copying. Both keep the pure
logic in the pure package. The code rocx build needs for 1 (src/routes.mjs, bin/rocx.mjs):

```js
// rocx build: for each package the server's header names, beside components/:
for (const file of files(join(pkg, "server"), ".roc")) copyRewritten(file, join(app, GENERATED, alias, basename(file)), alias);   // server half only
// jobsIn(dir): walk Generated/<alias>/ for every package too (module "Generated/<alias>/Push")
// migrationsIn(dir): [...packages.flatMap((p) => sqlFiles(join(p.dir, "migrations")).map((f) => `${p.alias}/${f}`)), ...appSqlFiles]
// --client: skip Generated/<alias>/ files that came from server/
```

**What in the package depends on it.** `server/Push.roc`, `server/PushStore.roc` and
`migrations/0001_push_subscriptions.sql`, and setup steps 3 and 5 of README.md. With the change,
setup step 3 goes away.

**How it could be undone.** Delete the copying, and apps copy by hand again (option 3); the
package's files don't change.

---

## 3. Static files in packages

**Status (2026-11-23).** Done another way: a plugin's files (D-050), served by the host before the
app and its middleware, `push-sw.js` at the root (`at: Root`) and `push.js` loaded by every page (a
plugin's script). A copy of a site as files gets them too (site/build.mjs). What follows is the
problem as it was.

**Problem.** A service worker controls only pages under its script's directory, so `push-sw.js`
must be served from the site's root (`/push-sw.js`), with a JavaScript content type. The page
script `push.js` has to be served too.

**What works today.** The host takes several `--static` directories, so
`--static packages/push/static` beside the app's own serves `/push.js` and `/push-sw.js` as
`text/javascript`, at the root. This was tried in the scratch app.

**Options.**

1. **rocx build copies a package's `static/` into the client's `static/`** (where `rocx/start.js`
   goes). Whatever serves that directory then serves the package's files. A name that clashes with
   the app's is an error at build time.
2. **Document the extra `--static`** (today). This works, but every deployment must remember it.
3. A route in the app that answers `/push-sw.js` from a string. It needs a `Str` import of the
   file, and a content type set by hand.

**Recommended: 1.** It mirrors `components/`, and a site served as files (`dist/`) gets them too.

**What in the package depends on it.** README setup step 5. `push.js` registers `/push-sw.js`
and assumes it is at the root.

**How it could be undone.** Drop the copy, and go back to the `--static` flag.

---

## 4. Jobs: give up, or come back at a time

**Status (2026-11-22).** Jobs are packages/jobs's (D-034): the backoff is the jobs plugin's
`retry_ms`, and the kinds are its `jobs` (`App.jobs`), not `program.jobs`; the options below would be
that package's to build.

**Problem.** A job's `run!` answers `Ok` or `Err(why)`, and every `Err` is retried with the
worker's backoff (`--job-retry-ms`, doubled each time). A push service's answers need two more:

- **Give up now.** A 400, 401, 403 or 413 won't change if the message is sent again, and
  re-sending a refused request to a push service only gets the server rate-limited. Today the job
  logs the refusal, notes it on the subscription and answers `Ok`, so the jobs page shows it
  **done**.
- **Come back at a time.** A 429 or 503 with `Retry-After: 120` says when to come back, while the
  worker's backoff would retry in 1, 2, 4 and 8 seconds. Today the job queues a copy of itself
  for then (`Job.enqueue!` with `At(…)`, counting the times in its input) and answers `Ok`.

**Options.**

1. **A richer answer, behind `Job.define_with`'s kind:** `run!` may answer
   `Err(GiveUp(why))` (failed now, whatever its attempts) or `Err(RetryAt(ms, why))` (queued again
   at `ms`, counting an attempt), beside the plain `Err(Str)`. `Job.handler` turns them into the
   `program.jobs` string the worker reads (a reserved prefix), so the platform's `requires`
   doesn't change.
2. **Effects a job calls before answering `Err`:** `Job.give_up!({})`, `Job.retry_at!(ms)`. Easier
   to add, but the job's answer no longer says what happens.
3. Leave it to each job (today).

**Recommended: 1.** It says in the type what the worker will do, as Oban's `{:cancel, reason}` and
`{:snooze, seconds}` do.

```roc
Job.Outcome : [Retry(Str), RetryAt(U64, Str), GiveUp(Str)]
Job.define_outcomes : Str, { attempts : U64, timeout_ms : U64 }, (input => Try({}, Job.Outcome)) -> Kind(input)
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
a side channel through the DOM. Also, what the page script finds on load (already subscribed?)
arrives only because `push.js` listens for `rocx:ready` itself: an effect can't call
`Browser.call!`.

**Options.**

1. **`Browser.ask!(name, arg, answered!)`**: the page's function may return a value or a promise;
   when it settles, the runtime runs `answered!` as a handler with `Ok(json)` or `Err(why)`.
   `<PushButton>` would be
   `on:click={|| Browser.ask!("push.subscribe", { api: api }, |answer| set_state!(PushState.parse(answer ?? "failed:")))}`,
   and an `on_settled!` effect could ask once on load.
2. Let effects' `apply` call `Browser.call!` (it is "a handler's" now), and keep the event for the
   answer.
3. Keep the DOM event (today).

**Recommended: 1.** It is Solid's `createResource` shape for page functions, and Elm's
`port`/`subscription` pair in one call.

**What in the package depends on it.** `components/PushButton.rocx` (`data-push-state`,
`on:pushstate.value`) and `tell` and the `rocx:ready` listener in `static/push.js`.

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
   would need adding to the list. Under `--dev`, `http://localhost` is allowed too.
3. **Owners as text.** `push_subscriptions.owner` is `text` (`""` for a visitor), so an app with
   integer or UUID ids can use it. Would you rather it were `bigint`, or an app-defined column?
4. **The default TTL** is a day (Chrome keeps a message four weeks at most). Is a day right for
   the apps you have in mind?
5. **`<PushButton>`** is the package's opinion of the UI (its words, its states). Keep it, or
   leave the UI to each app and ship only `push.js` and `PushState`?
6. **`ring` or `p256`** for section 1: `ring` adds nothing to the build, but its ECDH can't replay
   RFC 8291's fixed keys (it is tested by a round trip instead).
