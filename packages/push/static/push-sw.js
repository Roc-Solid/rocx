// Web Push for Roc Solid (packages/push): the service worker. The browser runs it when a push
// message comes, even with no tab of the site open, and it shows the notification the message
// carries (the package's Notification, as JSON: title, body, url, tag, icon). A click on it
// focuses a tab already at its URL, or opens one; only this site's pages are opened.
//
// Served at the site's root (/push-sw.js), so its scope is the whole site. push.js registers it
// with `?api=…`, where the app's push endpoints are, for when the push service changes a
// subscription.

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

/** The notification a message carries: its JSON, or its text as the body, or nothing. */
function read(data) {
	if (!data) return {};
	try {
		const message = data.json();
		return message && typeof message === "object" ? message : { body: String(message) };
	} catch {
		return { body: data.text() };
	}
}

self.addEventListener("push", (event) => {
	const message = read(event.data);
	const title = typeof message.title === "string" && message.title !== "" ? message.title : new URL(self.registration.scope).host;
	const options = {
		body: typeof message.body === "string" ? message.body : "",
		data: { url: typeof message.url === "string" && message.url !== "" ? message.url : "/" },
	};
	if (typeof message.tag === "string" && message.tag !== "") {
		options.tag = message.tag;
		// A newer notification with the tag replaces the older one, and says so.
		options.renotify = true;
	}
	if (typeof message.icon === "string" && message.icon !== "") options.icon = message.icon;
	// Every push must show a notification (`userVisibleOnly`): browsers stop a site's pushes that don't.
	event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
	event.notification.close();
	const target = new URL(event.notification.data?.url ?? "/", self.registration.scope);
	if (target.origin !== self.location.origin) return;
	event.waitUntil(
		(async () => {
			const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
			const open = windows.find((client) => client.url === target.href);
			if (open) return open.focus();
			return self.clients.openWindow(target.href);
		})(),
	);
});

// The push service ended the subscription and (maybe) made another: the server is told, so it
// sends to the new one, and deletes the old.
self.addEventListener("pushsubscriptionchange", (event) => {
	const api = new URL(self.location.href).searchParams.get("api");
	const post = (url, body) => fetch(url, { method: "POST", headers: { "content-type": "application/json" }, credentials: "same-origin", body: JSON.stringify(body) });
	event.waitUntil(
		(async () => {
			const old = event.oldSubscription;
			const key = old?.options?.applicationServerKey;
			const fresh = event.newSubscription ?? (key ? await self.registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key }) : null);
			if (!api) return;
			if (old) await post(`${api}/unsubscribe`, { endpoint: old.endpoint });
			if (fresh) await post(`${api}/subscribe`, fresh.toJSON());
		})(),
	);
});
