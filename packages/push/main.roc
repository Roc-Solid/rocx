## Push: Web Push notifications for Roc Solid apps, the parts that are plain Roc. A subscription
## read from the browser's JSON (`Subscription`); the message encrypted as RFC 8291 says, on the
## content coding of RFC 8188 (`WebPush`, `Ece`, with HKDF in `Kdf`); the server's VAPID token,
## RFC 8292 (`Vapid`); the notification the service worker shows (`Notification`) and the request's
## options, RFC 8030 (`Options`); what a push service's answer means: delivered, a subscription
## gone, try again later, or refused (`Delivery`); and where a browser stands, for a button
## (`PushState`). Keys travel as base64url (`Base64Url`).
##
## It is on no platform, so `expect`s check it against the RFCs' own examples. What needs elliptic
## curves (the ECDH that encrypts, the ECDSA signature VAPID wants) and AES-128-GCM is the host's
## to do. Beside this: `<PushButton>` (`components/`, which `rocx build` copies into an app), the
## server's glue that keeps subscriptions and sends (`server/`, with `migrations/`), and the
## browser's scripts (`static/`: the page's, and the service worker). See README.md and
## PROPOSALS.md.
package [Base64Url, Delivery, Ece, Kdf, Notification, Options, PushState, Subscription, Vapid, WebPush] {}
