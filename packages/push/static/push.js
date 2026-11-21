// Web Push for Roc Solid (packages/push): the page's part. A <PushButton>'s click calls these with
// Browser.call! ("push:subscribe" and "push:unsubscribe", each given { api }), so the permission
// prompt comes from the click, as browsers require. Each says how it went with a `pushstate` event
// on every [data-push-state] element, its `value` the state: unsupported, blocked, off, working, on,
// or failed:<why> (the package's PushState reads it).
//
// The app's layout loads it in its <head>:
//
//     <script type="module" src="/push.js"></script>
//
// and the server serves this directory (`--static packages/push/static`), so that the service
// worker is /push-sw.js, and its scope the whole site. The app answers `GET {api}/key` (the VAPID
// public key, as JSON), `POST {api}/subscribe` (the subscription, as `toJSON()` gives it) and
// `POST {api}/unsubscribe` (`{ endpoint }`).

const WORKER = "/push-sw.js";

/** Whether this browser can do Web Push here (a secure page, a service worker, the Push API). */
const supported = () => window.isSecureContext && "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;

/** Tells every <PushButton> on the page. */
function tell(state) {
	for (const element of document.querySelectorAll("[data-push-state]")) {
		element.value = state;
		element.dispatchEvent(new Event("pushstate"));
	}
}

/** Base64url (the server's key) as bytes, for `applicationServerKey`. */
function bytes(base64url) {
	const base64 = base64url.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(base64url.length / 4) * 4, "=");
	return Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
}

const sameBytes = (a, b) => a.length === b.length && a.every((byte, i) => byte === b[i]);

async function post(url, body) {
	const answer = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, credentials: "same-origin", body: JSON.stringify(body) });
	if (!answer.ok) throw new Error(`${url} answered ${answer.status}${answer.statusText ? ` ${answer.statusText}` : ""}`);
}

/** The server's VAPID public key: asked for once a page. */
const keys = new Map();
function publicKey(api) {
	if (!keys.has(api)) {
		keys.set(
			api,
			fetch(`${api}/key`, { headers: { accept: "application/json" }, credentials: "same-origin" }).then(async (answer) => {
				if (!answer.ok) throw new Error(`${api}/key answered ${answer.status}`);
				const key = await answer.json();
				if (typeof key !== "string" || key === "") throw new Error("the server has no VAPID key");
				return key;
			}),
		);
		keys.get(api).catch(() => keys.delete(api));
	}
	return keys.get(api);
}

/** The service worker, registered for the whole site; told where the app's endpoints are, for when
 * the push service changes the subscription (`pushsubscriptionchange`). */
async function worker(api) {
	await navigator.serviceWorker.register(`${WORKER}?api=${encodeURIComponent(api)}`, { scope: "/" });
	return navigator.serviceWorker.ready;
}

async function subscribe({ api }) {
	if (!supported()) return tell("unsupported");
	// First, while the click still counts as the user's: the prompt (or the answer given before).
	const asked = Notification.requestPermission();
	tell("working");
	try {
		const key = publicKey(api);
		const permission = await asked;
		if (permission !== "granted") return tell(permission === "denied" ? "blocked" : "off");
		const wanted = bytes(await key);
		const registration = await worker(api);
		let subscription = await registration.pushManager.getSubscription();
		// One made with another key (the server's keys changed) can't be sent to: make another.
		const made = subscription?.options?.applicationServerKey;
		if (subscription && made && !sameBytes(new Uint8Array(made), wanted)) {
			await subscription.unsubscribe();
			subscription = null;
		}
		subscription ??= await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: wanted });
		await post(`${api}/subscribe`, subscription.toJSON());
		sessionStorage.setItem("rocx-push", subscription.endpoint);
		tell("on");
	} catch (error) {
		tell(`failed:${error?.message ?? error}`);
	}
}

async function unsubscribe({ api }) {
	if (!supported()) return tell("unsupported");
	tell("working");
	try {
		const registration = await navigator.serviceWorker.getRegistration("/");
		const subscription = await registration?.pushManager.getSubscription();
		if (subscription) {
			const { endpoint } = subscription;
			await subscription.unsubscribe();
			await post(`${api}/unsubscribe`, { endpoint });
		}
		sessionStorage.removeItem("rocx-push");
		tell("off");
	} catch (error) {
		tell(`failed:${error?.message ?? error}`);
	}
}

/** Once the page is awake: where this browser stands. A subscription the browser has is sent to
 * the server again once a visit, in case it lost it, or the push service changed it. */
async function look() {
	if (!supported()) return tell("unsupported");
	if (Notification.permission === "denied") return tell("blocked");
	const registration = await navigator.serviceWorker.getRegistration("/");
	const subscription = Notification.permission === "granted" ? await registration?.pushManager.getSubscription() : null;
	if (!subscription) return tell("off");
	const api = new URL(registration.active?.scriptURL ?? location.href).searchParams.get("api");
	if (api && sessionStorage.getItem("rocx-push") !== subscription.endpoint) {
		try {
			await post(`${api}/subscribe`, subscription.toJSON());
			sessionStorage.setItem("rocx-push", subscription.endpoint);
		} catch (error) {
			return tell(`failed:${error?.message ?? error}`);
		}
	}
	tell("on");
}

window.rocxEffects = { ...window.rocxEffects, "push:subscribe": subscribe, "push:unsubscribe": unsubscribe };
document.addEventListener("rocx:ready", () => look().catch((error) => tell(`failed:${error?.message ?? error}`)));
