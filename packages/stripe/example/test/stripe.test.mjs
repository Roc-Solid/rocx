// packages/stripe (D-082), through its example app, against a stand-in for Stripe's API
// (stand-in.mjs: the endpoints the package calls, answering as Stripe's reference shows), never the
// real one: Checkout made for a signed-in user (their customer made once, reused, and made again when
// Stripe no longer has it), the webhook's signature (accepted, forged, too old, missing, one of
// several), an event handled once however often it comes, a subscription's events in any order (a
// late one never puts an older state back; two in one second are asked of Stripe), the success page
// settling a checkout before the events come, a one-time payment fulfilled by the app's `on_event!`
// (and rolled back when that fails), the Customer Portal (and opened at the card), a deleted customer
// forgotten, billing from the app (the card, the invoices, cancelling and keeping), and the pages only
// payers see. The example is built for SQLite (always) and for Postgres (when
// DATABASE_URL is set), each in build/<database>/app.
//
//   node --test 'packages/stripe/example/test/*.test.mjs'
import { describe, test, before, after } from "node:test";
import assert from "node:assert/strict";
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildForTests, startServer, testDatabase, testSqlite, until } from "../../../testing/index.mjs";
import { API_VERSION, SECRET_KEY, WEBHOOK_SECRET, now, sign, standIn } from "./stand-in.mjs";

/** A route the tests add: a refund asked of Stripe (`Stripe.post_with!`) with the app's own idempotency key, as a job run again after a crash would ask it. */
const refundRoute = `import pf.Server
import pf.Endpoint
import stripe.Stripe

## POST /test/refund: a refund of \`payment_intent\`, keyed \`refund-<payment_intent>\`: Stripe's
## answer. Written by packages/stripe's tests into the app they build; the example has none.
post! : { request : Server.Request, params : {}, context : {}, body : { payment_intent : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }|
	match Stripe.post_with!({ path: "/v1/refunds", fields: [("payment_intent", body.payment_intent)], idempotency_key: "refund-\${body.payment_intent}" }) {
		Ok(answer) => Ok(answer)
		Err(StripeErr(why)) => Err(Status(502, why))
	}
`;

const priceRoute = `import pf.Server
import pf.Endpoint
import stripe.Stripe

## POST /test/price: the id of the active price whose lookup key is \`key\` (\`Stripe.price!\`), 404
## for none. Written by packages/stripe's tests into the app they build; the example has none.
post! : { request : Server.Request, params : {}, context : {}, body : { key : Str } } => Try({ price : Str }, Endpoint.Refusal)
post! = |{ body, .. }|
	match Stripe.price!(body.key) {
		Ok(price) => Ok({ price: price })
		Err(NoPrice) => Err(NotFound)
		Err(StripeErr(why)) => Err(Status(502, why))
	}
`;

const example = join(dirname(fileURLToPath(import.meta.url)), "..");

/** The example for `database`, in build/<database>/app: its folder. */
function app(database) {
	const dir = join(example, "build", database, "app");
	rmSync(dir, { recursive: true, force: true });
	mkdirSync(dir, { recursive: true });
	for (const each of ["routes", "migrations", "Accounts.roc", "Billing.roc", "Middlewares.roc", "Plans.roc"]) cpSync(join(example, each), join(dir, each), { recursive: true });
	const main = readFileSync(join(example, "main.roc"), "utf8")
		.replaceAll('"../', '"../../../../')
		.replace('database: Sqlite("data/stripe.db")', `database: ${database === "sqlite" ? 'Sqlite("data/stripe.db")' : "Postgres"}`);
	writeFileSync(join(dir, "main.roc"), main);
	mkdirSync(join(dir, "routes", "test", "refund"), { recursive: true });
	writeFileSync(join(dir, "routes", "test", "refund", "+server.roc"), refundRoute);
	mkdirSync(join(dir, "routes", "test", "price"), { recursive: true });
	writeFileSync(join(dir, "routes", "test", "price", "+server.roc"), priceRoute);
	return dir;
}

const databases = ["sqlite", ...(process.env.DATABASE_URL ? ["postgres"] : [])];

/** The Checkout Session a redirect to Stripe's Checkout is for. */
const sessionOf = (location) => /\/c\/pay\/(cs_test_[0-9a-z]+)/.exec(location)?.[1];

for (const database of databases) {
	describe(`on ${database === "sqlite" ? "SQLite" : "Postgres"}`, () => {
		let stripe;
		let built;
		let db;
		let server;

		before(async () => {
			stripe = await standIn();
			built = await buildForTests(app(database), { client: false, opt: process.env.ROCX_TEST_OPT ?? "dev" });
			db = database === "sqlite" ? testSqlite() : await testDatabase();
			server = await startServer(built.server, { database: db.url, dev: true, env: { STRIPE_SECRET_KEY: SECRET_KEY, STRIPE_WEBHOOK_SECRET: WEBHOOK_SECRET, STRIPE_API_URL: stripe.origin } });
		});

		after(async () => {
			await server?.stop();
			await db?.drop();
			await stripe?.close();
		});

		/** Someone at a browser, signed in as `email` (packages/auth's dev sign-in), and their user's id. */
		async function signedIn(email) {
			const client = server.client();
			const signed = await client.post("/auth/dev", { email, then: "/" });
			assert.equal(signed.status, 303, signed.text);
			const [{ id }] = await db.query(`select id from users where email = '${email}'`);
			return { client, user: id };
		}

		/** `client` off to Checkout for `price`: the session's id. */
		async function checkout(client, price) {
			const off = await client.post("/api/billing/checkout", { price });
			assert.equal(off.status, 303, off.text);
			assert.ok(off.location.startsWith("https://checkout.stripe.com/c/pay/cs_test_"), off.location);
			return sessionOf(off.location);
		}

		/** `event` sent to the webhook as Stripe sends it, signed (or as `options` say): the answer. */
		async function deliver(event, { secret, t, signature, body = typeof event === "string" ? event : JSON.stringify(event) } = {}) {
			const header = signature ?? sign(typeof event === "string" ? event : JSON.stringify(event), { secret, t });
			const answer = await fetch(`${server.url}/stripe/webhook`, { method: "POST", headers: { "content-type": "application/json; charset=utf-8", "user-agent": "Stripe/1.0 (+https://stripe.com/docs/webhooks)", ...(header ? { "stripe-signature": header } : {}) }, body });
			return { status: answer.status, text: await answer.text() };
		}

		/** The account page's data for `client`. */
		const account = (client) => client.read("/api/account");

		/** How many rows `sql` counts (`select count(*) as n …`). */
		const count = async (sql) => Number((await db.query(sql))[0].n);

		test("the keys are looked at once the server has started: test mode", async () => {
			const said = await until(() => server.logs().find((line) => line.check === "stripe.keys"), { what: "the check's line" });
			assert.equal(said.msg, "test mode, Stripe-Version 2025-03-31.basil, webhooks at POST /stripe/webhook");
		});

		test("without its keys: under --dev the server starts with Stripe off (the webhook refuses every event, 503, a signature under an empty key too; a checkout says why); outside --dev it doesn't start", async () => {
			const empty = { STRIPE_SECRET_KEY: "", STRIPE_WEBHOOK_SECRET: "", STRIPE_API_URL: stripe.origin };
			const offDb = database === "sqlite" ? testSqlite() : await testDatabase();
			const off = await startServer(built.server, { database: offDb.url, dev: true, env: empty });
			try {
				const said = await until(() => off.logs().find((line) => line.check === "stripe.keys"), { what: "the check's line" });
				assert.equal(said.msg, "off under --dev: no STRIPE_SECRET_KEY or STRIPE_WEBHOOK_SECRET (each call answers StripeErr, the webhook 503)");
				const body = JSON.stringify(stripe.event("invoice.paid", {}));
				const refused = await fetch(`${off.url}/stripe/webhook`, { method: "POST", headers: { "content-type": "application/json; charset=utf-8", "stripe-signature": sign(body, { secret: "" }) }, body });
				assert.equal(refused.status, 503, await refused.text());
				const client = off.client();
				assert.equal((await client.post("/auth/dev", { email: "off@example.com", then: "/" })).status, 303);
				const from = stripe.requests.length;
				const checkout = await client.json("/api/billing/checkout", { price: "price_pro" });
				assert.equal(checkout.status, 502, checkout.text);
				assert.equal(stripe.requests.length, from, "Stripe isn't asked");
			} finally {
				await off.stop();
				await offDb.drop();
			}
			const stoppedDb = database === "sqlite" ? testSqlite() : await testDatabase();
			try {
				await assert.rejects(startServer(built.server, { database: stoppedDb.url, dev: false, env: empty }), /STRIPE_SECRET_KEY and STRIPE_WEBHOOK_SECRET not set/);
			} finally {
				await stoppedDb.drop();
			}
		});

		test("checkout: off to Stripe's Checkout, the user's customer made once and used again, the form as Stripe takes it", async () => {
			const { client, user } = await signedIn("ann@example.com");
			const from = stripe.requests.length;
			const subscription = await checkout(client, "price_pro");
			assert.deepEqual(stripe.since(from), ["POST /v1/customers", "POST /v1/checkout/sessions"]);
			const [made, session] = stripe.requests.slice(from);
			for (const each of [made, session]) {
				assert.equal(each.headers.authorization, `Bearer ${SECRET_KEY}`);
				assert.equal(each.headers["stripe-version"], API_VERSION);
				assert.equal(each.headers["content-type"], "application/x-www-form-urlencoded");
			}
			assert.equal(made.form.email, "ann@example.com");
			assert.equal(made.form["metadata[app_user_id]"], user);
			assert.match(made.headers["idempotency-key"], /^rocx-customer-[0-9a-f]{40}$/, "a customer's key is the same for the same user");
			const customer = [...stripe.customers.values()].find((each) => each.email === "ann@example.com").id;
			assert.deepEqual(
				{ ...session.form },
				{
					mode: "subscription",
					customer,
					client_reference_id: user,
					success_url: `${server.url}/billing/done?session_id={CHECKOUT_SESSION_ID}`,
					cancel_url: `${server.url}/`,
					"line_items[0][price]": "price_pro",
					"line_items[0][quantity]": "1",
					"metadata[app_user_id]": user,
					"subscription_data[metadata][app_user_id]": user,
				},
			);
			assert.match(session.headers["idempotency-key"], /^rocx-[A-Za-z0-9_-]{24}$/);
			// The e-book: the same customer, none made.
			const again = stripe.requests.length;
			const ebook = await checkout(client, "price_ebook");
			assert.deepEqual(stripe.since(again), ["POST /v1/checkout/sessions"]);
			const paying = stripe.requests[again].form;
			assert.equal(paying.mode, "payment");
			assert.equal(paying.customer, customer);
			assert.equal(paying["payment_intent_data[metadata][app_user_id]"], user);
			assert.equal(await count(`select count(*) as n from stripe_customers where user_id = '${user}' and customer_id = '${customer}'`), 1);
			const kept = await db.query(`select id, mode, prices, status from stripe_checkouts where user_id = '${user}' order by mode`);
			assert.deepEqual(
				kept.map((row) => [row.id, row.mode, JSON.parse(row.prices), row.status]),
				[
					[ebook, "payment", [{ price: "price_ebook", quantity: 1 }], "open"],
					[subscription, "subscription", [{ price: "price_pro", quantity: 1 }], "open"],
				],
			);
			// A price the page doesn't offer, and a signed-out request, go nowhere near Stripe.
			const before = stripe.requests.length;
			assert.equal((await client.json("/api/billing/checkout", { price: "price_anything" })).status, 400);
			assert.equal((await server.client().json("/api/billing/checkout", { price: "price_pro" })).status, 401);
			assert.equal(stripe.requests.length, before);
		});

		test("a customer Stripe no longer has (deleted in its Dashboard) is made again at the next checkout; its customer.deleted event forgets it", async () => {
			const { client, user } = await signedIn("dee@example.com");
			await checkout(client, "price_basic");
			const [{ customer_id: first }] = await db.query(`select customer_id from stripe_customers where user_id = '${user}'`);
			stripe.deleteCustomer(first);
			const from = stripe.requests.length;
			await checkout(client, "price_basic");
			assert.deepEqual(stripe.since(from), ["POST /v1/checkout/sessions", "POST /v1/customers", "POST /v1/checkout/sessions"]);
			const [{ customer_id: second }] = await db.query(`select customer_id from stripe_customers where user_id = '${user}'`);
			assert.notEqual(second, first);
			assert.equal(stripe.requests.at(-1).form.customer, second);
			// Deleted again, and this time Stripe says so: the customer is forgotten, so there is no portal to go to.
			const deleted = await deliver(stripe.event("customer.deleted", stripe.deleteCustomer(second)));
			assert.equal(deleted.status, 200, deleted.text);
			assert.equal(await count(`select count(*) as n from stripe_customers where user_id = '${user}'`), 0);
			const portal = await client.post("/api/billing/portal", {});
			assert.equal(portal.status, 303);
			assert.equal(portal.location, "/");
		});

		test("the webhook takes Stripe's signature only: forged, too old, missing or of another body is a 400; one good v1 among several will do", async () => {
			const event = stripe.event("invoice.paid", { id: "in_test_standalone", object: "invoice", customer: "cus_test_nobody", subscription: null, status: "paid", amount_due: 0, amount_paid: 0, currency: "usd" });
			const body = JSON.stringify(event);
			const t = now();
			assert.equal((await deliver(body, { secret: "whsec_someone_else" })).status, 400);
			const stale = await deliver(body, { t: t - 301 });
			assert.equal(stale.status, 400);
			assert.match(stale.text, /s old, more than 300/);
			assert.equal((await deliver(body, { signature: "" })).status, 400, "no Stripe-Signature");
			assert.equal((await deliver(body, { signature: `t=${t}` })).status, 400, "no v1");
			assert.equal((await deliver(body, { signature: `v1=${"0".repeat(64)}` })).status, 400, "no t");
			assert.equal((await deliver(body, { signature: sign(body), body: body.replace("invoice.paid", "invoice.voided") })).status, 400, "the body changed after it was signed");
			assert.equal(await count(`select count(*) as n from stripe_events where id = '${event.id}'`), 0, "none of them kept");
			// Within five minutes, and with several v1 values (Stripe sends one per secret while a secret is rolled), one matching.
			const good = sign(body, { t: t - 299 });
			const signed = await deliver(body, { signature: `${good.split(",")[0]},v1=${"0".repeat(64)},${good.split(",")[1]},v0=${"f".repeat(64)}` });
			assert.equal(signed.status, 200, signed.text);
			assert.deepEqual(JSON.parse(signed.text), { received: true });
			assert.equal(await count(`select count(*) as n from stripe_events where id = '${event.id}'`), 1);
			const refused = server.logs().filter((line) => line.msg === "stripe: a webhook was refused");
			assert.ok(refused.some((line) => /isn't the webhook secret's/.test(line.reason)), JSON.stringify(refused));
		});

		test("a subscription: Checkout completed, its events in any order, the pro pages and the portal; a late event never puts an older state back, and two in one second are asked of Stripe", async () => {
			const { client, user } = await signedIn("eve@example.com");
			assert.equal((await client.get("/pro")).location, "/?subscribe=1", "not a subscriber yet");
			const id = await checkout(client, "price_pro");
			const { session, subscription } = stripe.complete(id);
			const t = now();
			// Stripe sends them in this order; they come the other way round.
			const created = stripe.event("customer.subscription.created", { ...subscription, status: "incomplete" }, { created: t });
			const updated = stripe.event("customer.subscription.updated", subscription, { created: t, previous: { status: "incomplete" } });
			const completed = stripe.event("checkout.session.completed", session, { created: t });
			for (const event of [updated, completed, created]) {
				const answer = await deliver(event);
				assert.equal(answer.status, 200, `${event.type}: ${answer.text}`);
			}
			const end = subscription.items.data[0].current_period_end * 1000;
			assert.deepEqual(await account(client), { email: "eve@example.com", plan: "Pro", status: "active", until: new Date(end).toISOString().slice(0, 10), ending: false, customer: true, orders: [] });
			assert.deepEqual(await client.read("/api/pro"), { email: "eve@example.com" });
			assert.equal((await client.get("/pro")).status, 200);
			const [row] = await db.query(`select status, user_id, items, version from stripe_subscriptions where id = '${subscription.id}'`);
			assert.equal(row.user_id, user);
			assert.deepEqual(JSON.parse(row.items), [{ price: "price_pro", product: "prod_pro", quantity: 1 }]);
			assert.equal(Number(row.version), t * 4 + 1, "the update's version: its second, then its kind");
			const [kept] = await db.query(`select status, payment_status, subscription_id from stripe_checkouts where id = '${id}'`);
			assert.deepEqual({ ...kept }, { status: "complete", payment_status: "paid", subscription_id: subscription.id });
			// Subscribed already: a plan's button goes to the account (and its portal), not to Checkout again.
			assert.equal((await client.post("/api/billing/checkout", { price: "price_basic" })).location, "/account");

			// The portal: off to Stripe's, coming back to the account.
			const from = stripe.requests.length;
			const portal = await client.post("/api/billing/portal", {});
			assert.equal(portal.status, 303, portal.text);
			assert.match(portal.location, /^https:\/\/billing\.stripe\.com\/p\/session\/test_/);
			assert.deepEqual(stripe.since(from), ["POST /v1/billing_portal/sessions"]);
			assert.deepEqual({ ...stripe.requests[from].form }, { customer: subscription.customer, return_url: `${server.url}/account` });

			// Cancelled there, at the period's end: it says so, and the pro pages stay until then.
			const cancelling = stripe.update(subscription.id, { cancel_at_period_end: true, cancel_at: subscription.items.data[0].current_period_end });
			assert.equal((await deliver(stripe.event("customer.subscription.updated", cancelling, { created: t + 10 }))).status, 200);
			assert.equal((await account(client)).ending, true);
			assert.equal((await client.get("/pro")).status, 200);

			// Two changes in one second: the newer (resumed) comes first, then the older (cancelling). They
			// stand level, so the package asks Stripe, which has the newer.
			const resumed = stripe.update(subscription.id, { cancel_at_period_end: false, cancel_at: null });
			assert.equal((await deliver(stripe.event("customer.subscription.updated", resumed, { created: t + 20 }))).status, 200);
			const asked = stripe.requests.length;
			assert.equal((await deliver(stripe.event("customer.subscription.updated", cancelling, { created: t + 20 }))).status, 200);
			assert.deepEqual(stripe.since(asked), [`GET /v1/subscriptions/${subscription.id}`]);
			assert.equal((await account(client)).ending, false, "Stripe's word: resumed");
			// An event from before both comes last: it changes nothing.
			assert.equal((await deliver(stripe.event("customer.subscription.updated", cancelling, { created: t + 5 }))).status, 200);
			assert.equal((await account(client)).ending, false);

			// A renewal whose payment failed: the app's on_event! logs it, for the subscription's user.
			const invoice = stripe.failedInvoice(resumed);
			assert.equal((await deliver(stripe.event("invoice.payment_failed", invoice, { created: t + 25 }))).status, 200);
			const failed = server.logs().find((line) => line.msg === "billing: a payment failed" && line.invoice === invoice.id);
			assert.ok(failed, "on the log");
			assert.equal(failed.user, user);
			assert.equal(failed.pay_at, invoice.hosted_invoice_url);

			// Deleted: it has ended, the pro pages are closed, and a late update can't open them again.
			const ended = stripe.update(subscription.id, { status: "canceled", canceled_at: t + 30, ended_at: t + 30 });
			assert.equal((await deliver(stripe.event("customer.subscription.deleted", ended, { created: t + 30 }))).status, 200);
			assert.equal((await account(client)).status, "canceled");
			assert.equal((await client.get("/pro")).location, "/?subscribe=1");
			assert.equal((await deliver(stripe.event("customer.subscription.updated", resumed, { created: t + 40 }))).status, 200);
			assert.equal((await account(client)).status, "canceled", "an ended subscription stays ended");
			assert.equal((await client.request("/api/pro", { headers: { accept: "application/json" } })).status, 303);
		});

		test("the page Checkout comes back to settles the checkout before Stripe's events come; someone else's session is a 404", async () => {
			const { client } = await signedIn("fay@example.com");
			const id = await checkout(client, "price_basic");
			const { subscription } = stripe.complete(id);
			assert.equal((await client.get("/pro")).location, "/?subscribe=1", "no event has come");
			const from = stripe.requests.length;
			const back = await client.get(`/billing/done?session_id=${id}`);
			assert.equal(back.status, 200, back.text);
			assert.match(back.text, /You&#39;re subscribed to Basic\.|You're subscribed to Basic\./);
			assert.deepEqual(stripe.since(from), [`GET /v1/checkout/sessions/${id}`]);
			assert.deepEqual(stripe.requests[from].query.getAll("expand[]"), ["subscription"]);
			assert.deepEqual(await client.read("/api/pro"), { email: "fay@example.com" }, "subscribed, as Stripe said");
			assert.equal((await account(client)).plan, "Basic");
			// The events, when they come, count as ever.
			assert.equal((await deliver(stripe.event("customer.subscription.created", subscription))).status, 200);
			assert.equal((await account(client)).status, "active");
			// Another user's session id, or something that isn't one.
			const { client: other } = await signedIn("gus@example.com");
			assert.equal((await other.request(`/api/billing/done?session_id=${id}`, { headers: { accept: "application/json" } })).status, 404);
			assert.equal((await other.request("/api/billing/done?session_id=..%2Fv1%2Fcustomers", { headers: { accept: "application/json" } })).status, 404);
			assert.equal((await other.get("/pro")).location, "/?subscribe=1");
		});

		test("a one-time payment refunded in full, or disputed, isn't paid for any more (a late checkout event doesn't give it back); a dispute won gives it back; a part refunded doesn't take it", async () => {
			const bought = async (email) => {
				const { client, user } = await signedIn(email);
				const { session } = stripe.complete(await checkout(client, "price_ebook"));
				assert.equal((await deliver(stripe.event("checkout.session.completed", session))).status, 200);
				assert.equal((await client.get("/ebook")).status, 200, "bought");
				return { client, user, session };
			};
			const charge = (session, fields) => ({ id: `ch_test_${session.payment_intent}`, object: "charge", amount: 900, customer: session.customer, payment_intent: session.payment_intent, ...fields });
			// Refunded: a part, still theirs; all of it, not; the completed event sent again doesn't give it back.
			const { client: kim, session: kims } = await bought("kim@example.com");
			assert.equal((await deliver(stripe.event("charge.refunded", charge(kims, { refunded: false, amount_refunded: 100 })))).status, 200);
			assert.equal((await kim.get("/ebook")).status, 200, "a part refunded: still theirs");
			assert.equal((await deliver(stripe.event("charge.refunded", charge(kims, { refunded: true, amount_refunded: 900 })))).status, 200);
			assert.equal((await kim.get("/ebook")).location, "/", "refunded in full: not theirs");
			assert.equal((await db.query(`select payment_status from stripe_checkouts where id = '${kims.id}'`))[0].payment_status, "refunded");
			assert.equal((await deliver(stripe.event("checkout.session.completed", kims))).status, 200);
			assert.equal((await kim.get("/ebook")).location, "/", "a late checkout event doesn't give it back");
			// Disputed: held; lost, still held. Another's dispute won: theirs again.
			const { client: lee, session: lees } = await bought("lee@example.com");
			const dispute = (status) => ({ id: `dp_test_${lees.payment_intent}`, object: "dispute", amount: 900, charge: `ch_test_${lees.payment_intent}`, payment_intent: lees.payment_intent, status });
			assert.equal((await deliver(stripe.event("charge.dispute.created", dispute("needs_response")))).status, 200);
			assert.equal((await lee.get("/ebook")).location, "/", "disputed: held");
			assert.equal((await deliver(stripe.event("charge.dispute.closed", dispute("lost")))).status, 200);
			assert.equal((await lee.get("/ebook")).location, "/", "lost: still held");
			assert.equal((await db.query(`select payment_status from stripe_checkouts where id = '${lees.id}'`))[0].payment_status, "disputed");
			const { client: max, session: maxs } = await bought("max@example.com");
			const maxDispute = (status) => ({ id: `dp_test_${maxs.payment_intent}`, object: "dispute", amount: 900, payment_intent: maxs.payment_intent, status });
			assert.equal((await deliver(stripe.event("charge.dispute.created", maxDispute("needs_response")))).status, 200);
			assert.equal((await max.get("/ebook")).location, "/");
			assert.equal((await deliver(stripe.event("charge.dispute.closed", maxDispute("won")))).status, 200);
			assert.equal((await max.get("/ebook")).status, 200, "won: theirs again");
		});

		test("Stripe.price!: a price by its lookup key, the active one, asked of Stripe; none for a key no price has", async () => {
			const asked = await server.client().json("/test/price", { key: "pro_monthly" });
			assert.equal(asked.status, 200, asked.text);
			assert.deepEqual(await asked.json(), { price: "price_pro" });
			const request = stripe.requests.findLast((each) => each.path === "/v1/prices");
			assert.deepEqual([request.method, request.query.getAll("lookup_keys[]"), request.query.get("active")], ["GET", ["pro_monthly"], "true"]);
			assert.equal((await server.client().json("/test/price", { key: "no_such_key" })).status, 404);
		});

		test("Stripe.post_with!: the app's own idempotency key, the same each time the same thing is asked, so a call made again makes one refund", async () => {
			const since = stripe.requests.length;
			const first = await server.client().json("/test/refund", { payment_intent: "pi_test_again" });
			const again = await server.client().json("/test/refund", { payment_intent: "pi_test_again" });
			assert.equal(first.status, 200, first.text);
			const asked = stripe.requests.slice(since).filter((each) => each.path === "/v1/refunds");
			assert.deepEqual(
				asked.map((each) => each.headers["idempotency-key"]),
				["refund-pi_test_again", "refund-pi_test_again"],
			);
			assert.equal(JSON.parse(again.json()).id, JSON.parse(first.json()).id, "Stripe answered the key it had seen as it did the first time");
		});

		test("a one-time payment: fulfilled by on_event! once however often its event comes; an on_event! that fails rolls the event back, and Stripe's next try lands", async () => {
			const { client, user } = await signedIn("hal@example.com");
			const id = await checkout(client, "price_ebook");
			const { session } = stripe.complete(id);
			assert.equal((await client.get("/ebook")).location, "/", "not bought yet");
			const completed = stripe.event("checkout.session.completed", session);
			// The app's table is away: its on_event! fails, so nothing of the event is kept and Stripe is told to send it again.
			await db.query("alter table orders rename to orders_away");
			const failed = await deliver(completed);
			await db.query("alter table orders_away rename to orders");
			assert.equal(failed.status, 500);
			assert.match(failed.text, /The app couldn't handle the event: the order couldn't be written/);
			assert.equal(await count(`select count(*) as n from stripe_events where id = '${completed.id}'`), 0);
			assert.equal((await db.query(`select status from stripe_checkouts where id = '${id}'`))[0].status, "open", "the package's own record rolled back with it");
			// Sent again, and again: handled once.
			for (const _ of [1, 2, 3]) assert.equal((await deliver(completed)).status, 200);
			const orders = await db.query(`select session_id, what, amount, currency from orders where user_id = '${user}'`);
			assert.deepEqual(
				orders.map((row) => ({ ...row, amount: Number(row.amount) })),
				[{ session_id: id, what: "The e-book", amount: 900, currency: "usd" }],
			);
			assert.equal(await count(`select count(*) as n from stripe_events where id = '${completed.id}'`), 1);
			assert.deepEqual(await client.read("/api/ebook"), { title: "A small book about Roc", chapters: ["Values", "Functions", "Records and tags", "Effects"] });
			const mine = await account(client);
			assert.deepEqual([mine.plan, mine.orders.map((order) => order.what)], ["", ["The e-book"]]);
			// Someone else hasn't bought it.
			const { client: other } = await signedIn("ivy@example.com");
			assert.equal((await other.get("/ebook")).location, "/");
			// Sent five times at once (Stripe's tries can overlap): one handles it, the rest wait for it and answer.
			const { client: jo, user: joId } = await signedIn("jo@example.com");
			const once = stripe.event("checkout.session.completed", stripe.complete(await checkout(jo, "price_ebook")).session);
			const answers = await Promise.all([1, 2, 3, 4, 5].map(() => deliver(once)));
			assert.deepEqual(
				answers.map((answer) => answer.status),
				[200, 200, 200, 200, 200],
			);
			assert.equal(await count(`select count(*) as n from orders where user_id = '${joId}'`), 1);
		});

		test("billing from the app: the card (the subscription's, else the customer's default, else none) and the invoices, the newest first, asked of Stripe; cancelling at the period's end and keeping it after all, kept at once; the portal opened at the card", async () => {
			const billing = (client) => client.read("/api/billing");
			const { client } = await signedIn("nell@example.com");
			// Never checked out: no card, no invoices, nothing to cancel, no portal, and Stripe isn't asked.
			let from = stripe.requests.length;
			assert.deepEqual(await billing(client), { card: "", invoices: [] });
			assert.equal((await client.post("/api/billing/cancel", {})).location, "/account");
			assert.equal((await client.post("/api/billing/keep", {})).location, "/account");
			assert.equal((await client.post("/api/billing/card", {})).location, "/");
			assert.deepEqual(stripe.since(from), []);

			const id = await checkout(client, "price_pro");
			const { subscription } = stripe.complete(id);
			const t = now();
			assert.equal((await deliver(stripe.event("customer.subscription.created", subscription, { created: t }))).status, 200);

			// The card Checkout kept, the subscription's; its first invoice.
			from = stripe.requests.length;
			const first = await billing(client);
			assert.equal(first.card, "visa ending 4242, expires 12/2034");
			assert.deepEqual(stripe.since(from), [`GET /v1/subscriptions/${subscription.id}`, "GET /v1/invoices"]);
			assert.deepEqual(stripe.requests[from].query.getAll("expand[]"), ["default_payment_method"]);
			assert.equal(stripe.requests[from + 1].query.get("customer"), subscription.customer);
			assert.deepEqual(first.invoices.map((each) => [each.id, each.status, each.amount_paid, each.currency]), [[subscription.latest_invoice, "paid", 1500, "usd"]]);

			// A month later, another: the newest first, with its number, day and PDF.
			const later = stripe.bill(subscription.id, { created: t + 60 });
			const listed = (await billing(client)).invoices;
			assert.deepEqual(listed.map((each) => each.id), [later.id, subscription.latest_invoice]);
			assert.equal(listed[0].number, later.number);
			assert.equal(listed[0].day, new Date(later.created * 1000).toISOString().slice(0, 10));
			assert.equal(listed[0].pdf, later.invoice_pdf);
			assert.match(listed[0].pdf, /^https:\/\/pay\.stripe\.com\/invoice\//);

			// No card on the subscription: the customer's default, asked for expanded; neither, none.
			stripe.update(subscription.id, { default_payment_method: null });
			assert.equal((await billing(client)).card, "");
			stripe.giveCard(subscription.customer, { brand: "mastercard", last4: "4444", exp_month: 1, exp_year: 2030 });
			from = stripe.requests.length;
			assert.equal((await billing(client)).card, "mastercard ending 4444, expires 1/2030");
			assert.deepEqual(stripe.since(from), [`GET /v1/subscriptions/${subscription.id}`, `GET /v1/customers/${subscription.customer}`, "GET /v1/invoices"]);
			assert.deepEqual(stripe.requests[from + 1].query.getAll("expand[]"), ["invoice_settings.default_payment_method"]);

			// Cancelled from the app: Stripe told, and the account says so at once, before any event; paid for until then.
			from = stripe.requests.length;
			assert.equal((await client.post("/api/billing/cancel", {})).location, "/account");
			assert.deepEqual(stripe.since(from), [`POST /v1/subscriptions/${subscription.id}`]);
			assert.deepEqual({ ...stripe.requests[from].form }, { cancel_at_period_end: "true" });
			assert.ok(stripe.requests[from].headers["idempotency-key"], "an idempotency key");
			assert.equal(stripe.subscriptions.get(subscription.id).cancel_at_period_end, true);
			assert.equal((await account(client)).ending, true);
			assert.equal((await client.get("/pro")).status, 200);
			// Its event, when it comes, says the same.
			assert.equal((await deliver(stripe.event("customer.subscription.updated", stripe.subscriptions.get(subscription.id), { created: t + 5 }))).status, 200);
			assert.equal((await account(client)).ending, true);

			// Kept after all.
			from = stripe.requests.length;
			assert.equal((await client.post("/api/billing/keep", {})).location, "/account");
			assert.deepEqual({ ...stripe.requests[from].form }, { cancel_at_period_end: "false" });
			assert.equal(stripe.subscriptions.get(subscription.id).cancel_at, null);
			assert.equal((await account(client)).ending, false);

			// An end set in the Dashboard (a cancel_at of its own) is unset the same way.
			const dated = stripe.update(subscription.id, { cancel_at: t + 86400 });
			assert.equal((await deliver(stripe.event("customer.subscription.updated", dated, { created: t + 10 }))).status, 200);
			assert.equal((await account(client)).ending, true);
			from = stripe.requests.length;
			assert.equal((await client.post("/api/billing/keep", {})).location, "/account");
			assert.deepEqual({ ...stripe.requests[from].form }, { cancel_at: "" });
			assert.equal((await account(client)).ending, false);

			// The portal opened at the card, coming back to the account.
			from = stripe.requests.length;
			const portal = await client.post("/api/billing/card", {});
			assert.equal(portal.status, 303, portal.text);
			assert.match(portal.location, /^https:\/\/billing\.stripe\.com\/p\/session\/test_[0-9a-f]+\/flow$/);
			assert.deepEqual(stripe.since(from), ["POST /v1/billing_portal/sessions"]);
			assert.deepEqual({ ...stripe.requests[from].form }, {
				customer: subscription.customer,
				return_url: `${server.url}/account`,
				"flow_data[type]": "payment_method_update",
				"flow_data[after_completion][type]": "redirect",
				"flow_data[after_completion][redirect][return_url]": `${server.url}/account`,
			});

			// Ended: nothing to cancel or keep, and Stripe isn't asked.
			const ended = stripe.update(subscription.id, { status: "canceled", canceled_at: t + 30, ended_at: t + 30 });
			assert.equal((await deliver(stripe.event("customer.subscription.deleted", ended, { created: t + 30 }))).status, 200);
			from = stripe.requests.length;
			assert.equal((await client.post("/api/billing/cancel", {})).location, "/account");
			assert.equal((await client.post("/api/billing/keep", {})).location, "/account");
			assert.deepEqual(stripe.since(from), []);
			assert.equal((await account(client)).status, "canceled");
		});
	});
}
