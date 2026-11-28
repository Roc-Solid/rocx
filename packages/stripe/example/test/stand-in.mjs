// A stand-in for Stripe's API, for packages/stripe's tests: the endpoints the package calls, each
// answering with the objects Stripe's API reference shows for version 2025-03-31.basil (the one the
// package pins), kept in memory; and what Stripe itself would do, for a test to do instead: complete
// a Checkout Session, change a subscription, delete a customer, give a customer a card, bill a
// subscription, and make an event, signed as Stripe signs it for a webhook. The real Stripe is never
// asked. A completed checkout's subscription is charged to a Visa ending 4242 (`CARD`), and has its
// first invoice.
//
//   const stripe = await standIn();           // STRIPE_API_URL=stripe.origin, STRIPE_SECRET_KEY=SECRET_KEY
//   const { session, subscription } = stripe.complete(id);
//   const body = JSON.stringify(stripe.event("customer.subscription.updated", subscription));
//   fetch(`${app}/stripe/webhook`, { method: "POST", headers: { "stripe-signature": sign(body) }, body });
import { createHmac, randomBytes } from "node:crypto";
import { createServer } from "node:http";

/** The secret key the stand-in takes (`Authorization: Bearer …`); any other is a 401. */
export const SECRET_KEY = "sk_test_51StandIn0000000000000000000000";

/** The webhook endpoint's signing secret, as `stripe listen` prints one. */
export const WEBHOOK_SECRET = "whsec_standin0000000000000000000000000000";

/** The API version its objects are written in. */
export const API_VERSION = "2025-03-31.basil";

/** The prices it has: two monthly, one once. */
export const PRICES = {
	price_basic: { product: "prod_basic", unit_amount: 500, recurring: { interval: "month", interval_count: 1, usage_type: "licensed" }, lookup_key: "basic_monthly" },
	price_pro: { product: "prod_pro", unit_amount: 1500, recurring: { interval: "month", interval_count: 1, usage_type: "licensed" }, lookup_key: "pro_monthly" },
	price_ebook: { product: "prod_ebook", unit_amount: 900, recurring: null, lookup_key: null },
};

/** The card a completed checkout's subscription is charged to, as Checkout keeps the one typed there. */
export const CARD = { brand: "visa", last4: "4242", exp_month: 12, exp_year: 2034 };

/** Now, in seconds, as Stripe's times are. */
export const now = () => Math.floor(Date.now() / 1000);

/**
 * The `Stripe-Signature` Stripe sends with `body` (the request's text, as it goes): `t=<seconds>,v1=<HMAC-SHA256
 * of "<t>.<body>" under the secret, in hex>`.
 */
export function sign(body, { secret = WEBHOOK_SECRET, t = now() } = {}) {
	return `t=${t},v1=${createHmac("sha256", secret).update(`${t}.${body}`).digest("hex")}`;
}

/** The fields of a form named `<prefix>[name]`, as an object (Stripe's `metadata[…]`). */
function nested(form, prefix) {
	const found = {};
	for (const [name, value] of Object.entries(form)) {
		const match = /^(.+)\[([^\]]+)\]$/.exec(name);
		if (match && match[1] === prefix) found[match[2]] = value;
	}
	return found;
}

/** Stripe's error answer. */
const refused = (status, message, extra = {}) => ({ status, body: { error: { type: "invalid_request_error", message, ...extra } } });

/** A price as Stripe writes one. */
function price(id) {
	const known = PRICES[id];
	return {
		id,
		object: "price",
		active: true,
		billing_scheme: "per_unit",
		created: 1700000000,
		currency: "usd",
		livemode: false,
		lookup_key: known.lookup_key,
		metadata: {},
		nickname: null,
		product: known.product,
		recurring: known.recurring ? { ...known.recurring, meter: null, trial_period_days: null } : null,
		tax_behavior: "unspecified",
		type: known.recurring ? "recurring" : "one_time",
		unit_amount: known.unit_amount,
		unit_amount_decimal: String(known.unit_amount),
	};
}

/** Starts the stand-in on a port of its own. */
export async function standIn() {
	let counter = 0;
	const id = (prefix) => `${prefix}_test_${(++counter).toString(36).padStart(4, "0")}${randomBytes(6).toString("hex")}`;
	const customers = new Map();
	const sessions = new Map();
	const subscriptions = new Map();
	/** Payment methods (`pm_…`), each a card. */
	const paymentMethods = new Map();
	/** Invoices (`in_…`), each a customer's. */
	const invoices = new Map();
	/** What a session was made with, kept as Stripe keeps its line items. */
	const lines = new Map();
	/** Answers by `Idempotency-Key`: the same key is the same answer. */
	const answered = new Map();
	/** Every request, as it came: `{ method, path, form, query, headers }`. */
	const requests = [];

	function customer(form) {
		const made = { id: id("cus"), object: "customer", address: null, balance: 0, created: now(), currency: null, default_source: null, delinquent: false, description: null, email: form.email ?? null, invoice_prefix: "B7D2A1C4", invoice_settings: { custom_fields: null, default_payment_method: null, footer: null, rendering_options: null }, livemode: false, metadata: nested(form, "metadata"), name: null, phone: null, preferred_locales: [], shipping: null, tax_exempt: "none", test_clock: null };
		customers.set(made.id, made);
		return { status: 200, body: made };
	}

	function checkout(form) {
		const mode = form.mode;
		if (!["payment", "subscription", "setup"].includes(mode)) return refused(400, "Invalid mode: must be one of payment, setup, or subscription", { param: "mode" });
		if (form.customer && !customers.has(form.customer)) return refused(400, `No such customer: '${form.customer}'`, { code: "resource_missing", param: "customer", doc_url: "https://stripe.com/docs/error-codes/resource-missing" });
		if (!/^https?:\/\//.test(form.success_url ?? "")) return refused(400, "Not a valid URL", { param: "success_url" });
		const items = [];
		for (let i = 0; `line_items[${i}][price]` in form; i++) {
			const asked = form[`line_items[${i}][price]`];
			if (!PRICES[asked]) return refused(400, `No such price: '${asked}'`, { code: "resource_missing", param: `line_items[${i}][price]` });
			items.push({ price: asked, quantity: Number(form[`line_items[${i}][quantity]`] ?? 1) });
		}
		if (items.length === 0) return refused(400, "line_items is required in payment and subscription mode.", { param: "line_items" });
		const recurring = items.some((item) => PRICES[item.price].recurring);
		if (mode === "subscription" && !recurring) return refused(400, "You must provide at least one recurring price in `subscription` mode when using prices.", { param: "line_items" });
		if (mode === "payment" && recurring) return refused(400, "You specified `payment` mode but passed a recurring price. Either switch to `subscription` mode or use only one-time prices.", { param: "line_items" });
		const total = items.reduce((sum, item) => sum + PRICES[item.price].unit_amount * item.quantity, 0);
		const created = now();
		const session = {
			id: id("cs"),
			object: "checkout.session",
			adaptive_pricing: { enabled: false },
			after_expiration: null,
			allow_promotion_codes: form.allow_promotion_codes === "true" ? true : null,
			amount_subtotal: total,
			amount_total: total,
			automatic_tax: { enabled: false, liability: null, provider: null, status: null },
			billing_address_collection: null,
			cancel_url: form.cancel_url ?? null,
			client_reference_id: form.client_reference_id ?? null,
			client_secret: null,
			collected_information: null,
			consent: null,
			consent_collection: null,
			created,
			currency: "usd",
			custom_fields: [],
			custom_text: { after_submit: null, shipping_address: null, submit: null, terms_of_service_acceptance: null },
			customer: form.customer ?? null,
			customer_creation: form.customer ? null : "if_required",
			customer_details: null,
			customer_email: null,
			discounts: [],
			expires_at: created + 86400,
			invoice: null,
			invoice_creation: null,
			livemode: false,
			locale: null,
			metadata: nested(form, "metadata"),
			mode,
			payment_intent: null,
			payment_link: null,
			payment_method_collection: "always",
			payment_method_types: ["card"],
			payment_status: "unpaid",
			phone_number_collection: { enabled: false },
			recovered_from: null,
			saved_payment_method_options: null,
			setup_intent: null,
			shipping_address_collection: null,
			shipping_cost: null,
			status: "open",
			submit_type: null,
			subscription: null,
			success_url: form.success_url,
			total_details: { amount_discount: 0, amount_shipping: 0, amount_tax: 0 },
			ui_mode: "hosted",
			url: null,
			wallet_options: null,
		};
		session.url = `https://checkout.stripe.com/c/pay/${session.id}#fidkdWxOYHwnPyd1blpxYHZxWjA0`;
		sessions.set(session.id, session);
		lines.set(session.id, { items, subscriptionMetadata: nested(form, "subscription_data[metadata]"), trialDays: Number(form["subscription_data[trial_period_days]"] ?? 0) });
		return { status: 200, body: session };
	}

	function portal(form) {
		if (!customers.has(form.customer)) return refused(400, `No such customer: '${form.customer}'`, { code: "resource_missing", param: "customer" });
		// A flow (`flow_data[type]`): the portal opened at one thing, and where it goes after.
		const type = form["flow_data[type]"];
		if (type && !["payment_method_update", "subscription_cancel", "subscription_update", "subscription_update_confirm"].includes(type)) return refused(400, `Invalid flow_data[type]: ${type}`, { param: "flow_data[type]" });
		const after = form["flow_data[after_completion][type]"];
		const flow = type ? { type, after_completion: { type: after ?? "portal_homepage", redirect: after === "redirect" ? { return_url: form["flow_data[after_completion][redirect][return_url]"] ?? null } : null, hosted_confirmation: null }, coupon: null, subscription_cancel: null, subscription_update: null, subscription_update_confirm: null } : null;
		return { status: 200, body: { id: id("bps"), object: "billing_portal.session", configuration: "bpc_test_standin", created: now(), customer: form.customer, flow, livemode: false, locale: null, on_behalf_of: null, return_url: form.return_url ?? null, url: `https://billing.stripe.com/p/session/test_${randomBytes(12).toString("hex")}${type ? "/flow" : ""}` } };
	}

	/** A card payment method for `customer`, as `pm_…`. */
	function paymentMethod(customer, card) {
		const made = { id: id("pm"), object: "payment_method", allow_redisplay: "always", billing_details: { address: null, email: null, name: null, phone: null }, card: { brand: card.brand, checks: { address_line1_check: null, address_postal_code_check: null, cvc_check: "pass" }, country: "US", display_brand: card.brand, exp_month: card.exp_month, exp_year: card.exp_year, funding: "credit", last4: card.last4, networks: { available: [card.brand], preferred: null }, wallet: null }, created: now(), customer, livemode: false, metadata: {}, type: "card" };
		paymentMethods.set(made.id, made);
		return made.id;
	}

	/** `object` with the payment method at `field` (an id) put in its place, as `expand[]` asks. */
	function expanded(object, field) {
		const pm = object?.[field];
		return typeof pm === "string" && paymentMethods.has(pm) ? { ...object, [field]: paymentMethods.get(pm) } : object;
	}

	/** An invoice of `subscription` (basil: the subscription is its `parent`'s), kept. */
	function invoiceOf(subscription, { status = "paid", amount, billing_reason = "subscription_cycle", created = now(), attempt_count } = {}) {
		const due = amount ?? subscription.items.data.reduce((sum, item) => sum + item.price.unit_amount * item.quantity, 0);
		const paid = status === "paid" ? due : 0;
		const count = [...invoices.values()].filter((each) => each.customer === subscription.customer).length + 1;
		const made = { id: id("in"), object: "invoice", account_country: "US", account_name: "Example", amount_due: due, amount_paid: paid, amount_remaining: due - paid, attempt_count: attempt_count ?? (status === "draft" ? 0 : 1), attempted: status !== "draft", auto_advance: status !== "paid", billing_reason, collection_method: "charge_automatically", created, currency: "usd", customer: subscription.customer, customer_email: customers.get(subscription.customer)?.email ?? null, hosted_invoice_url: status === "draft" ? null : `https://invoice.stripe.com/i/acct_test/test_${randomBytes(8).toString("hex")}`, invoice_pdf: status === "draft" ? null : `https://pay.stripe.com/invoice/acct_test/test_${randomBytes(8).toString("hex")}/pdf`, livemode: false, metadata: {}, next_payment_attempt: status === "open" ? now() + 3 * 86400 : null, number: status === "draft" ? null : `B7D2A1C4-${String(count).padStart(4, "0")}`, parent: { quote_details: null, subscription_details: { metadata: subscription.metadata, subscription: subscription.id }, type: "subscription_details" }, period_end: created, period_start: created - 30 * 86400, status, total: due };
		invoices.set(made.id, made);
		return made;
	}

	/** `subscription` set to end at its period's end, or to go on (`POST /v1/subscriptions/:id`). */
	function changed(subscription, form) {
		const end = Math.max(...subscription.items.data.map((item) => item.current_period_end));
		if ("cancel_at_period_end" in form) {
			if (!["true", "false"].includes(form.cancel_at_period_end)) return refused(400, "Invalid boolean: " + form.cancel_at_period_end, { param: "cancel_at_period_end" });
			const at_end = form.cancel_at_period_end === "true";
			subscription.cancel_at_period_end = at_end;
			subscription.cancel_at = at_end ? end : null;
			subscription.canceled_at = at_end ? now() : null;
		}
		if ("cancel_at" in form) {
			subscription.cancel_at = form.cancel_at === "" ? null : Number(form.cancel_at);
			if (form.cancel_at === "") subscription.canceled_at = null;
		}
		return { status: 200, body: structuredClone(subscription) };
	}

	function answer(method, path, form, query) {
		let match;
		if (method === "POST" && path === "/v1/customers") return customer(form);
		if (method === "POST" && path === "/v1/checkout/sessions") return checkout(form);
		if (method === "POST" && path === "/v1/billing_portal/sessions") return portal(form);
		if (method === "POST" && path === "/v1/refunds") return { status: 200, body: { id: id("re"), object: "refund", amount: Number(form.amount ?? 900), payment_intent: form.payment_intent ?? null, status: "succeeded" } };
		if (method === "GET" && (match = /^\/v1\/checkout\/sessions\/([^/]+)$/.exec(path))) {
			const session = sessions.get(decodeURIComponent(match[1]));
			if (!session) return refused(404, `No such checkout.session: '${decodeURIComponent(match[1])}'`, { code: "resource_missing", param: "id" });
			const expanded = query.getAll("expand[]").includes("subscription") && session.subscription ? subscriptions.get(session.subscription) : session.subscription;
			return { status: 200, body: { ...session, subscription: expanded } };
		}
		if (method === "GET" && path === "/v1/prices") {
			// Its prices by lookup key (`lookup_keys[]`), the active ones (all of them are).
			const keys = query.getAll("lookup_keys[]");
			const data = Object.keys(PRICES)
				.filter((id) => keys.length === 0 || keys.includes(PRICES[id].lookup_key))
				.map(price);
			return { status: 200, body: { object: "list", data: data.slice(0, Number(query.get("limit") ?? 10)), has_more: false, url: "/v1/prices" } };
		}
		if ((match = /^\/v1\/subscriptions\/([^/]+)$/.exec(path))) {
			const subscription = subscriptions.get(decodeURIComponent(match[1]));
			if (!subscription) return refused(404, `No such subscription: '${decodeURIComponent(match[1])}'`, { code: "resource_missing", param: "id" });
			if (method === "POST") {
				if (["canceled", "incomplete_expired"].includes(subscription.status)) return refused(400, "A canceled subscription can only update its cancellation_details and metadata.");
				return changed(subscription, form);
			}
			if (method === "GET") return { status: 200, body: query.getAll("expand[]").includes("default_payment_method") ? expanded(subscription, "default_payment_method") : subscription };
		}
		if (method === "GET" && (match = /^\/v1\/customers\/([^/]+)$/.exec(path))) {
			const customer = customers.get(decodeURIComponent(match[1]));
			if (!customer) return refused(404, `No such customer: '${decodeURIComponent(match[1])}'`, { code: "resource_missing", param: "id" });
			const settings = query.getAll("expand[]").includes("invoice_settings.default_payment_method") ? expanded(customer.invoice_settings, "default_payment_method") : customer.invoice_settings;
			return { status: 200, body: { ...customer, invoice_settings: settings } };
		}
		if (method === "GET" && path === "/v1/invoices") {
			// A customer's (`customer`), the newest first, as Stripe lists them.
			const customer = query.get("customer");
			const data = [...invoices.values()].filter((each) => !customer || each.customer === customer).sort((a, b) => b.created - a.created);
			const limit = Number(query.get("limit") ?? 10);
			return { status: 200, body: { object: "list", data: data.slice(0, limit), has_more: data.length > limit, url: "/v1/invoices" } };
		}
		return refused(404, `Unrecognized request URL (${method}: ${path}).`);
	}

	const server = createServer(async (request, response) => {
		let text = "";
		for await (const chunk of request) text += chunk;
		const url = new URL(request.url, "http://stand-in");
		const form = Object.fromEntries(new URLSearchParams(request.method === "POST" ? text : ""));
		const headers = { authorization: request.headers.authorization, "stripe-version": request.headers["stripe-version"], "idempotency-key": request.headers["idempotency-key"], "content-type": request.headers["content-type"] };
		requests.push({ method: request.method, path: url.pathname, form, query: url.searchParams, headers });
		let reply;
		const key = request.headers["idempotency-key"];
		if (request.headers.authorization !== `Bearer ${SECRET_KEY}`) reply = refused(401, "Invalid API Key provided: sk_test_****");
		else if (key && answered.has(key)) reply = answered.get(key);
		else {
			reply = answer(request.method, url.pathname, form, url.searchParams);
			if (key && request.method === "POST") answered.set(key, reply);
		}
		response.writeHead(reply.status, { "content-type": "application/json", "request-id": `req_${randomBytes(7).toString("hex")}`, "stripe-version": API_VERSION });
		response.end(JSON.stringify(reply.body, null, 2));
	});
	await new Promise((done) => server.listen(0, "127.0.0.1", done));

	return {
		/** Where it listens: STRIPE_API_URL. */
		origin: `http://127.0.0.1:${server.address().port}`,
		/** Every request it was sent, oldest first. */
		requests,
		customers,
		sessions,
		subscriptions,
		paymentMethods,
		invoices,

		/**
		 * As if the session's customer paid on Checkout's page: the session complete and paid (or,
		 * `paid: false`, waiting for a payment that takes days), and in subscription mode its
		 * subscription made, active, for a month. Its objects, as Stripe has them now.
		 */
		complete(sessionId, { paid = true } = {}) {
			const session = sessions.get(sessionId);
			const { items, subscriptionMetadata, trialDays } = lines.get(sessionId);
			session.status = "complete";
			session.payment_status = paid ? "paid" : "unpaid";
			session.url = null;
			session.customer_details = { address: null, email: customers.get(session.customer)?.email ?? null, name: null, phone: null, tax_exempt: "none", tax_ids: [] };
			let subscription = null;
			if (session.mode === "subscription") {
				const start = now();
				const end = start + 30 * 86400;
				const subscriptionId = id("sub");
				subscription = {
					id: subscriptionId,
					object: "subscription",
					application: null,
					automatic_tax: { disabled_reason: null, enabled: false, liability: null },
					billing_cycle_anchor: start,
					cancel_at: null,
					cancel_at_period_end: false,
					canceled_at: null,
					cancellation_details: { comment: null, feedback: null, reason: null },
					collection_method: "charge_automatically",
					created: start,
					currency: "usd",
					customer: session.customer,
					days_until_due: null,
					default_payment_method: paymentMethod(session.customer, CARD),
					discounts: [],
					ended_at: null,
					items: {
						object: "list",
						data: items.map((item) => ({ id: id("si"), object: "subscription_item", created: start, current_period_end: end, current_period_start: start, discounts: [], metadata: {}, price: price(item.price), quantity: item.quantity, subscription: subscriptionId, tax_rates: [] })),
						has_more: false,
						total_count: items.length,
						url: `/v1/subscription_items?subscription=${subscriptionId}`,
					},
					latest_invoice: null,
					livemode: false,
					metadata: subscriptionMetadata,
					pending_update: null,
					start_date: start,
					status: trialDays > 0 ? "trialing" : "active",
					trial_end: trialDays > 0 ? start + trialDays * 86400 : null,
					trial_start: trialDays > 0 ? start : null,
				};
				subscriptions.set(subscriptionId, subscription);
				// Its first invoice: the first month's, or nothing for a trial's.
				subscription.latest_invoice = invoiceOf(subscription, { amount: trialDays > 0 ? 0 : undefined, billing_reason: "subscription_create", created: start }).id;
				session.subscription = subscriptionId;
			} else if (paid) {
				session.payment_intent = id("pi");
			}
			return { session: structuredClone(session), subscription: structuredClone(subscription) };
		},

		/** As if the subscription changed at Stripe (in the portal, or a payment): its object now. */
		update(subscriptionId, changes) {
			const subscription = subscriptions.get(subscriptionId);
			Object.assign(subscription, changes);
			return structuredClone(subscription);
		},

		/** As if the customer was deleted in Stripe's Dashboard. */
		deleteCustomer(customerId) {
			const gone = customers.get(customerId);
			customers.delete(customerId);
			return { id: customerId, object: "customer", deleted: true, ...(gone ? { email: gone.email } : {}) };
		},

		/** An invoice of a subscription (basil: the subscription is its `parent`'s), its payment tried and failed: kept, and listed. */
		failedInvoice(subscription) {
			return structuredClone(invoiceOf(subscription, { status: "open" }));
		},

		/** As if Stripe billed the subscription (`subscriptionId`): an invoice, `paid` unless `status` says (`open`, `draft`), made at `created` (seconds). Kept, and listed. */
		bill(subscriptionId, options = {}) {
			return structuredClone(invoiceOf(subscriptions.get(subscriptionId), options));
		},

		/** As if `customerId` saved a card as their default (`invoice_settings.default_payment_method`), in the portal or the Dashboard: its `pm_…`. */
		giveCard(customerId, card = CARD) {
			const pm = paymentMethod(customerId, card);
			customers.get(customerId).invoice_settings.default_payment_method = pm;
			return pm;
		},

		/** An event of `type` about `object`, as Stripe sends it to a webhook endpoint. */
		event(type, object, { created = now(), previous } = {}) {
			return { id: id("evt"), object: "event", api_version: API_VERSION, created, data: { object: structuredClone(object), ...(previous ? { previous_attributes: previous } : {}) }, livemode: false, pending_webhooks: 1, request: { id: null, idempotency_key: null }, type };
		},

		/** The requests sent since the first `since`, as `METHOD /path`. */
		since(since) {
			return requests.slice(since).map((each) => `${each.method} ${each.path}`);
		},

		close: () => new Promise((done) => server.close(done)),
	};
}
