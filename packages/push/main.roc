## Push: Web Push notifications for Roc Solid apps, as a plugin. The parts that are plain Roc: A subscription
## read from the browser's JSON (`Subscription`); the message encrypted as RFC 8291 says, on the
## content coding of RFC 8188 (`WebPush`, `Ece`); the server's VAPID token,
## RFC 8292 (`Vapid`); the notification the service worker shows (`Notification`) and the request's
## options, RFC 8030 (`Options`); what a push service's answer means: delivered, a subscription
## gone, try again later, or refused (`Delivery`); and where a browser stands, for a button
## (`PushState`). Keys travel as base64url. HKDF, HMAC and Base64 are packages/crypto's.
##
## These are on no platform, so `expect`s check them against the RFCs' own examples. What needs
## elliptic curves (the ECDH that encrypts, the ECDSA signature VAPID wants) and AES-128-GCM is the
## server platform's (`P256`, `AesGcm`: D-080). And the plugin (`Push.plugin`, D-051), on the server
## platform, which this header names: the endpoints, the subscriptions' table (`PushStore`, with
## `migrations/`), the job that encrypts, signs and sends, and the browser's files it serves
## (`static/`: the page's script, and the service worker at the site's root). The browser's half sees the modules on no platform (`browser.roc`);
## `<PushButton>` is in `components/`, which `rocx build` copies into an app. See README.md and
## PROPOSALS.md.
package [Delivery, Ece, Notification, Options, Push, PushState, PushStore, Subscription, Vapid, WebPush] { crypto: "../crypto/main.roc", jobs: "../jobs/main.roc", pf: platform "../../server/platform/main.roc" }
