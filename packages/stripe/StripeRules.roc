import pf.Server
import crypto.Hex
import crypto.Hmac
import crypto.Sha256

## packages/stripe's rules, plain Roc: no effect, so `expect`s check each. A webhook's signature
## (`verify`, and `signature` to make one, as Stripe does), the fields of Stripe's objects read out
## of their JSON whatever API version wrote them (`at`, `text`, `int`, …, then `event`,
## `subscription`, `session` and `invoice`), the order events are kept in (`version`), the form a
## Checkout Session is made with (`checkout_form`), and where Checkout goes back to. `Stripe` puts
## the effects around them.
StripeRules := [].{

	## How old a webhook's signature may be, in seconds: five minutes, as Stripe's own libraries
	## allow, so a request someone kept can't be sent again later.
	tolerance_s : I64
	tolerance_s = 300

	## The metadata key the package names the app's user by, on the customers, Checkout Sessions and
	## subscriptions it makes.
	user_key : Str
	user_key = "app_user_id"

	## Whether `header` (a `Stripe-Signature`: `t=1700000000,v1=…,v1=…`) signs `body` (the request's
	## bytes, as they came) under `secret` (the endpoint's `whsec_…`) at `now_s`: one of its `v1`
	## values is the HMAC-SHA256 of `"<t>.<body>"`, compared in constant time, and `t` is at most
	## `tolerance_s` old. `Unsigned`: no `t` or no `v1` (or no secret to check with); `Stale(age)`:
	## too old; `Forged`: no `v1` matches.
	verify : Str, List(U8), Str, I64 -> Try({}, [Unsigned, Stale(I64), Forged])
	verify = |header, body, secret, now_s| {
		pairs = header.split_on(",").keep_oks(|part| part.trim().split_first("=").map_ok(|{ before, after }| (before, after)))
		stamp = pairs.find_first(|(name, _)| name == "t").map_ok(|(_, value)| value) ?? ""
		given = pairs.keep_if(|(name, _)| name == "v1").map(|(_, value)| value)
		match I64.from_str(stamp) {
			Ok(t) if !given.is_empty() and !secret.is_empty() =>
				if now_s - t > StripeRules.tolerance_s {
					Err(Stale(now_s - t))
				} else {
					expected = Hmac.sha256(secret.to_utf8(), "${stamp}.".to_utf8().concat(body))
					if (given.any(|each| Hmac.equal(expected, Hex.decode(each) ?? []))) Ok({}) else Err(Forged)
				}
			_ => Err(Unsigned)
		}
	}

	## The `Stripe-Signature` Stripe sends with `body` at `t` (seconds) under `secret`: for tests, and
	## a stand-in for Stripe.
	signature : Str, I64, List(U8) -> Str
	signature = |secret, t, body| "t=${t.to_str()},v1=${Hex.encode(Hmac.sha256(secret.to_utf8(), "${t.to_str()}.".to_utf8().concat(body)))}"

	## The JSON of the value at `path` (each a field's name) in the JSON document `json`, as it is
	## written there (`{"id":"x"}`, `"x"`, `12`, `null`); `Missing` when a field on the way isn't
	## there or isn't an object.
	at : Str, List(Str) -> Try(Str, [Missing])
	at = |json, path| {
		bytes = json.to_utf8()
		start = skip(bytes, 0)
		match span(bytes, start, path) {
			Ok((from, to)) => Ok(Str.from_utf8_lossy(bytes.sublist({ start: from, len: to - from })))
			Err(_) => Err(Missing)
		}
	}

	## The string at `path`, its escapes read; "" when it is null, missing, or not a string.
	text : Str, List(Str) -> Str
	text = |json, path|
		match StripeRules.at(json, path) {
			Ok(found) if found.starts_with("\"") => {
				read : Try(Str, _)
				read = Json.parse(found)
				read ?? ""
			}
			_ => ""
		}

	## The id at `path`: the string there, or the `id` of the object there (Stripe writes an object
	## in place of its id when it was asked to `expand` it); "" when there is neither.
	id_at : Str, List(Str) -> Str
	id_at = |json, path|
		match StripeRules.at(json, path) {
			Ok(found) if found.starts_with("{") => StripeRules.text(found, ["id"])
			Ok(found) if found.starts_with("\"") => StripeRules.text(json, path)
			_ => ""
		}

	## The whole number at `path`; 0 when it is null, missing, or not one.
	int : Str, List(Str) -> I64
	int = |json, path|
		match StripeRules.at(json, path) {
			Ok(found) => I64.from_str(found) ?? 0
			Err(_) => 0
		}

	## Whether the value at `path` is `true`.
	bool : Str, List(Str) -> Bool
	bool = |json, path| StripeRules.at(json, path) == Ok("true")

	## The first price's id in a list of prices (`GET /v1/prices`'s answer); `NoPrice` when it has
	## none.
	price_in : Str -> Try(Str, [NoPrice, ..others])
	price_in = |json| {
		listed = StripeRules.elements(StripeRules.at(json, ["data"]) ?? "[]")
		match listed.first() {
			Ok(first) if !StripeRules.text(first, ["id"]).is_empty() => Ok(StripeRules.text(first, ["id"]))
			_ => Err(NoPrice)
		}
	}

	## The JSON of each item of the array `json` is; none when it isn't one.
	elements : Str -> List(Str)
	elements = |json| {
		bytes = json.to_utf8()
		start = skip(bytes, 0)
		match items(bytes, start) {
			Ok(spans) => spans.map(|(from, to)| Str.from_utf8_lossy(bytes.sublist({ start: from, len: to - from })))
			Err(_) => []
		}
	}

	## Each field of the object `json` is, with its string value (a value that isn't a string is
	## left out): an object's `metadata`.
	strings : Str -> List((Str, Str))
	strings = |json| {
		bytes = json.to_utf8()
		start = skip(bytes, 0)
		match members(bytes, start) {
			Ok(found) =>
				found.keep_oks(
					|member| {
						value = Str.from_utf8_lossy(bytes.sublist({ start: member.start, len: member.end - member.start }))
						if value.starts_with("\"") {
							read : Try(Str, _)
							read = Json.parse(value)
							read.map_ok(|decoded| (member.name, decoded)).map_err(|_| NotText)
						} else {
							Err(NotText)
						}
					},
				)
			Err(_) => []
		}
	}

	## An event, as Stripe sends it to a webhook: its id (`evt_…`), its type
	## (`customer.subscription.updated`), when it happened (seconds since 1970), whether it is live,
	## and its object (`data.object`), as JSON.
	Event : { id : Str, type : Str, created : I64, livemode : Bool, object : Str }

	## The event a webhook's body is, or why it isn't one.
	event : Str -> Try(StripeRules.Event, Str)
	event = |json| {
		id = StripeRules.text(json, ["id"])
		type = StripeRules.text(json, ["type"])
		match StripeRules.at(json, ["data", "object"]) {
			Ok(object) if !id.is_empty() and !type.is_empty() and object.starts_with("{") =>
				Ok({ id: id, type: type, created: StripeRules.int(json, ["created"]), livemode: StripeRules.bool(json, ["livemode"]), object: object })
			_ => Err("it isn't a Stripe event: it has no id, type or data.object")
		}
	}

	## A price a subscription or a checkout is for, its product, and how many.
	Item : { price : Str, product : Str, quantity : U64 }

	## A subscription as its object says (times in seconds since 1970, 0 for none): its id
	## (`sub_…`), its customer, its status as Stripe writes it (`active`), its items, when its period
	## ends, whether it ends then, when it is set to end, when its trial ends, and the app's user its
	## metadata names ("" when none).
	Subscription : { id : Str, customer : Str, status : Str, items : List(StripeRules.Item), current_period_end : I64, cancel_at_period_end : Bool, cancel_at : I64, trial_end : I64, user : Str }

	## The subscription `json` is (a subscription object), from any API version: before 2025-03-31
	## its period's end is the subscription's own, since then each item's.
	subscription : Str -> Try(StripeRules.Subscription, Str)
	subscription = |json| {
		id = StripeRules.text(json, ["id"])
		if !id.starts_with("sub_") or StripeRules.text(json, ["status"]).is_empty() {
			return Err("it isn't a subscription: it has no sub_ id or no status")
		}
		listed = StripeRules.elements(StripeRules.at(json, ["items", "data"]) ?? "[]")
		ends = listed.map(|item| StripeRules.int(item, ["current_period_end"]))
		own = StripeRules.int(json, ["current_period_end"])
		Ok({
			id: id,
			customer: StripeRules.id_at(json, ["customer"]),
			status: StripeRules.text(json, ["status"]),
			items: listed.map(|item| { price: StripeRules.id_at(item, ["price"]), product: StripeRules.id_at(item, ["price", "product"]), quantity: StripeRules.int(item, ["quantity"]).to_u64_wrap() }),
			current_period_end: if (own != 0) own else ends.fold(0, |most, each| if (each > most) each else most),
			cancel_at_period_end: StripeRules.bool(json, ["cancel_at_period_end"]),
			cancel_at: StripeRules.int(json, ["cancel_at"]),
			trial_end: StripeRules.int(json, ["trial_end"]),
			user: StripeRules.text(json, ["metadata", StripeRules.user_key]),
		})
	}

	## A Checkout Session as its object says: its id (`cs_…`), its mode (`payment`, `subscription`,
	## `setup`), its status (`open`, `complete`, `expired`), its payment's (`paid`, `unpaid`,
	## `no_payment_required`), the app's user (its `client_reference_id`, else its metadata's), its
	## customer and subscription ("" for none), its total in the currency's smallest unit, its
	## currency, its URL (while it is open), its metadata, and the PaymentIntent (`pi_…`) a payment's
	## charge is for ("" for none: a subscription's, or one not paid yet).
	Session : { id : Str, mode : Str, status : Str, payment_status : Str, user : Str, customer : Str, subscription : Str, amount_total : I64, currency : Str, url : Str, metadata : List((Str, Str)), payment_intent : Str }

	## The Checkout Session `json` is.
	session : Str -> Try(StripeRules.Session, Str)
	session = |json| {
		id = StripeRules.text(json, ["id"])
		if !id.starts_with("cs_") {
			return Err("it isn't a Checkout Session: it has no cs_ id")
		}
		reference = StripeRules.text(json, ["client_reference_id"])
		Ok({
			id: id,
			mode: StripeRules.text(json, ["mode"]),
			status: StripeRules.text(json, ["status"]),
			payment_status: StripeRules.text(json, ["payment_status"]),
			user: if (reference.is_empty()) StripeRules.text(json, ["metadata", StripeRules.user_key]) else reference,
			customer: StripeRules.id_at(json, ["customer"]),
			subscription: StripeRules.id_at(json, ["subscription"]),
			amount_total: StripeRules.int(json, ["amount_total"]),
			currency: StripeRules.text(json, ["currency"]),
			url: StripeRules.text(json, ["url"]),
			metadata: StripeRules.strings(StripeRules.at(json, ["metadata"]) ?? "{}"),
			payment_intent: StripeRules.id_at(json, ["payment_intent"]),
		})
	}

	## What a charge's event (its object, `json`) does to the one-time payment it was for, by its
	## PaymentIntent (`pi_…`): refunded in full (`charge.refunded`, `refunded`), the payment is taken
	## back (`Refunded`); a dispute opened (`charge.dispute.created`, an inquiry too) holds it
	## (`Disputed`) until it closes in the seller's favor (`charge.dispute.closed`, `won` or
	## `warning_closed`: `Settled`). Anything else (a part refunded, a dispute lost, which stays
	## held, a charge of no PaymentIntent): `Unchanged`.
	charge_change : Str, Str -> [Refunded(Str), Disputed(Str), Settled(Str), Unchanged]
	charge_change = |type, json| {
		intent = StripeRules.id_at(json, ["payment_intent"])
		if intent.is_empty() {
			Unchanged
		} else {
			match type {
				"charge.refunded" => if (StripeRules.bool(json, ["refunded"])) Refunded(intent) else Unchanged
				"charge.dispute.created" => Disputed(intent)
				"charge.dispute.closed" => if (["won", "warning_closed"].contains(StripeRules.text(json, ["status"]))) Settled(intent) else Unchanged
				_ => Unchanged
			}
		}
	}

	## An invoice as its object says: its id (`in_…`), its customer, the subscription it bills ("" for
	## none), its status (`paid`, `open`, …), what it asks and what was paid (the currency's smallest
	## unit), its currency, the page where it can be paid, how many times its payment was tried, why
	## it was made (`subscription_cycle`, `subscription_create`, …), when it was made (seconds since
	## 1970), its number (`B7D2A1C4-0001`, "" while it is a draft), and its PDF's URL ("" for none).
	Invoice : { id : Str, customer : Str, subscription : Str, status : Str, amount_due : I64, amount_paid : I64, currency : Str, hosted_url : Str, attempt_count : U64, billing_reason : Str, created : I64, number : Str, pdf_url : Str }

	## The invoice `json` is, from any API version: before 2025-03-31 its subscription is its own
	## field, since then its `parent`'s.
	invoice : Str -> Try(StripeRules.Invoice, Str)
	invoice = |json| {
		id = StripeRules.text(json, ["id"])
		if !id.starts_with("in_") {
			return Err("it isn't an invoice: it has no in_ id")
		}
		own = StripeRules.id_at(json, ["subscription"])
		Ok({
			id: id,
			customer: StripeRules.id_at(json, ["customer"]),
			subscription: if (own.is_empty()) StripeRules.id_at(json, ["parent", "subscription_details", "subscription"]) else own,
			status: StripeRules.text(json, ["status"]),
			amount_due: StripeRules.int(json, ["amount_due"]),
			amount_paid: StripeRules.int(json, ["amount_paid"]),
			currency: StripeRules.text(json, ["currency"]),
			hosted_url: StripeRules.text(json, ["hosted_invoice_url"]),
			attempt_count: StripeRules.int(json, ["attempt_count"]).to_u64_wrap(),
			billing_reason: StripeRules.text(json, ["billing_reason"]),
			created: StripeRules.int(json, ["created"]),
			number: StripeRules.text(json, ["number"]),
			pdf_url: StripeRules.text(json, ["invoice_pdf"]),
		})
	}

	## The invoices in a list of them (`GET /v1/invoices`'s answer), the newest first; one that can't
	## be read is left out.
	invoices_in : Str -> List(StripeRules.Invoice)
	invoices_in = |json|
		StripeRules.elements(StripeRules.at(json, ["data"]) ?? "[]")
			.keep_oks(StripeRules.invoice)
			.sort_with(|a, b| if (a.created > b.created) Before else if (a.created < b.created) After else Same)

	## A card, as a payment method's `card` says it: its brand as Stripe writes it (`visa`,
	## `mastercard`, `amex`, …), its last four digits, and the month and year it expires.
	Card : { brand : Str, last4 : Str, exp_month : U64, exp_year : U64 }

	## The card of the payment method at `path` in `json` (an object Stripe was asked to `expand`):
	## `NoCard` when there is none there (null, an id alone), or it isn't a card (a bank account,
	## Link).
	card_at : Str, List(Str) -> Try(StripeRules.Card, [NoCard, ..others])
	card_at = |json, path|
		match StripeRules.at(json, path) {
			Ok(method) if method.starts_with("{") and StripeRules.text(method, ["type"]) == "card" and !StripeRules.text(method, ["card", "last4"]).is_empty() =>
				Ok({
					brand: StripeRules.text(method, ["card", "brand"]),
					last4: StripeRules.text(method, ["card", "last4"]),
					exp_month: StripeRules.int(method, ["card", "exp_month"]).to_u64_wrap(),
					exp_year: StripeRules.int(method, ["card", "exp_year"]).to_u64_wrap(),
				})
			_ => Err(NoCard)
		}

	## The form of a Customer Portal session for `customer` opened at changing their card
	## (`flow_data[type]=payment_method_update`), going back to `return_url` once it is changed, and
	## from the portal's own link back.
	card_portal_form : Str, Str -> List((Str, Str))
	card_portal_form = |customer, return_url| [
		("customer", customer),
		("return_url", return_url),
		("flow_data[type]", "payment_method_update"),
		("flow_data[after_completion][type]", "redirect"),
		("flow_data[after_completion][redirect][return_url]", return_url),
	]

	## The form that sets whether a subscription ends at its period's end (`cancel!`: `Bool.True`),
	## or goes on (`keep!`). Going on undoes either way it was set to end: `cancel_at_period_end`
	## (which sets `cancel_at` to the period's end too), or a `cancel_at` of its own (set in the
	## Dashboard), which an empty value unsets. `cancel_at_ms` is the subscription's (0: none).
	ends_form : Bool, Bool, I64 -> List((Str, Str))
	ends_form = |at_end, cancel_at_period_end, cancel_at_ms|
		if at_end {
			[("cancel_at_period_end", "true")]
		} else if !cancel_at_period_end and cancel_at_ms != 0 {
			[("cancel_at", "")]
		} else {
			[("cancel_at_period_end", "false")]
		}

	## Where an event about a subscription stands among the others about it: its time (seconds) four
	## times over, and within one second `created` first, then any other, then `deleted`. A kept
	## subscription is changed only by an event that stands as high or higher, so one that comes late
	## never puts an older state back.
	version : I64, Str -> I64
	version = |created, type| created * 4 + StripeRules.rank(type)

	## Where an event's type stands within one second: `customer.subscription.created` 0, `deleted`
	## 2, any other 1.
	rank : Str -> I64
	rank = |type|
		if type == "customer.subscription.created" {
			0
		} else if type == "customer.subscription.deleted" {
			2
		} else {
			1
		}

	## The form a Checkout Session is made with (`POST /v1/checkout/sessions`): its mode, the customer,
	## the app's user (as `client_reference_id`, and in the session's metadata, and its subscription's
	## or payment's), each price and quantity, where it goes after, a trial (`trial_days`, a
	## subscription's; 0 for none), whether promotion codes may be typed, and the app's own metadata.
	checkout_form : { mode : Str, customer : Str, user : Str, prices : List({ price : Str, quantity : U64 }), success_url : Str, cancel_url : Str, trial_days : U64, promotion_codes : Bool, metadata : List((Str, Str)) } -> List((Str, Str))
	checkout_form = |asked| {
		lines = List.join(asked.prices.map_with_index(|line, i| [("line_items[${i.to_str()}][price]", line.price), ("line_items[${i.to_str()}][quantity]", line.quantity.to_str())]))
		tagged = [(StripeRules.user_key, asked.user)].concat(asked.metadata.drop_if(|(name, _)| name == StripeRules.user_key))
		about = if (asked.mode == "subscription") "subscription_data" else "payment_intent_data"
		trial = if (asked.mode == "subscription" and asked.trial_days > 0) [("subscription_data[trial_period_days]", asked.trial_days.to_str())] else []
		promotion = if (asked.promotion_codes) [("allow_promotion_codes", "true")] else []
		[("mode", asked.mode), ("customer", asked.customer), ("client_reference_id", asked.user), ("success_url", asked.success_url), ("cancel_url", asked.cancel_url)]
			.concat(lines)
			.concat(tagged.map(|(name, value)| ("metadata[${name}]", value)))
			.concat([("${about}[metadata][${StripeRules.user_key}]", asked.user)])
			.concat(trial)
			.concat(promotion)
	}

	## `url` as Stripe needs it, whole: a path of this site (`/billing/done`) after its public URL.
	absolute : Str, Str -> Str
	absolute = |url, public| if (url.starts_with("/") and !url.starts_with("//")) "${public}${url}" else url

	## The success URL with `session_id={CHECKOUT_SESSION_ID}` in its query, which Stripe fills in, so
	## the page it lands on knows the session; as it is when it names `{CHECKOUT_SESSION_ID}` already.
	with_session_id : Str -> Str
	with_session_id = |url|
		if url.contains("{CHECKOUT_SESSION_ID}") {
			url
		} else {
			(before, fragment) =
				match url.split_first("#") {
					Ok({ before: start, after }) => (start, "#${after}")
					Err(_) => (url, "")
				}
			joiner = if (before.contains("?")) "&" else "?"
			"${before}${joiner}session_id={CHECKOUT_SESSION_ID}${fragment}"
		}

	## The `Idempotency-Key` a customer for `user` (with `email`) is made with: the same for the same
	## two, so two checkouts at once make one customer.
	customer_key : Str, Str -> Str
	customer_key = |user, email| "rocx-customer-${Str.from_utf8_lossy(Sha256.hex("${user}\n${email}".to_utf8()).to_utf8().take_first(40))}"

	## What Stripe's error answer (`{"error":{"message":…}}`, with its status) says went wrong.
	problem : U16, Str -> Str
	problem = |status, json| {
		said = StripeRules.text(json, ["error", "message"])
		if (said.is_empty()) "Stripe answered ${status.to_str()}" else said
	}

	## Whether Stripe's error answer says the customer it was given isn't there (deleted, or of
	## another account or mode).
	no_customer : Str -> Bool
	no_customer = |json| StripeRules.text(json, ["error", "code"]) == "resource_missing" and StripeRules.text(json, ["error", "param"]) == "customer"

	## Whether `id` has the shape of a Checkout Session's id (`cs_test_…`, `cs_live_…`), so nothing
	## else is put in a URL.
	is_session_id : Str -> Bool
	is_session_id = |id| id.starts_with("cs_") and id.to_utf8().len() <= 255 and id.to_utf8().all(|byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '_')

	## A path of Stripe's API with `id` as its last segment, encoded.
	api_path : Str, Str -> Str
	api_path = |base, id| "${base}/${Server.encode_segment(id)}"
}

## The index of the first byte at or after `i` that isn't white space.
skip : List(U8), U64 -> U64
skip = |bytes, i| {
	var $at = i
	while $at < bytes.len() and is_space(bytes.get($at) ?? 0) {
		$at = $at + 1
	}
	$at
}

is_space : U8 -> Bool
is_space = |byte| byte == ' ' or byte == '\n' or byte == '\r' or byte == '\t'

## The value at `path` under the value at `start`: where it begins and ends.
span : List(U8), U64, List(Str) -> Try((U64, U64), [Missing, Malformed])
span = |bytes, start, path|
	match path {
		[] => value_end(bytes, start).map_ok(|end| (start, end))
		[name, .. as rest] => {
			fields = members(bytes, start)?
			match fields.find_first(|member| member.name == name) {
				Ok(member) => span(bytes, member.start, rest)
				Err(_) => Err(Missing)
			}
		}
	}

## The fields of the object at `open`: each one's name, and where its value begins and ends.
members : List(U8), U64 -> Try(List({ name : Str, start : U64, end : U64 }), [Missing, Malformed])
members = |bytes, open| {
	if bytes.get(open) != Ok('{') {
		return Err(Missing)
	}
	var $out = []
	var $at = skip(bytes, open + 1)
	var $more = bytes.get($at) != Ok('}')
	while $more {
		name_end = string_end(bytes, $at)?
		name = Str.from_utf8_lossy(bytes.sublist({ start: $at + 1, len: name_end - $at - 2 }))
		colon = skip(bytes, name_end)
		if bytes.get(colon) != Ok(':') {
			return Err(Malformed)
		}
		from = skip(bytes, colon + 1)
		to = value_end(bytes, from)?
		$out = $out.append({ name: name, start: from, end: to })
		after = skip(bytes, to)
		if bytes.get(after) == Ok(',') {
			$at = skip(bytes, after + 1)
		} else if bytes.get(after) == Ok('}') {
			$more = Bool.False
		} else {
			return Err(Malformed)
		}
	}
	Ok($out)
}

## The items of the array at `open`: where each begins and ends.
items : List(U8), U64 -> Try(List((U64, U64)), [Missing, Malformed])
items = |bytes, open| {
	if bytes.get(open) != Ok('[') {
		return Err(Missing)
	}
	var $out = []
	var $at = skip(bytes, open + 1)
	var $more = bytes.get($at) != Ok(']')
	while $more {
		to = value_end(bytes, $at)?
		$out = $out.append(($at, to))
		after = skip(bytes, to)
		if bytes.get(after) == Ok(',') {
			$at = skip(bytes, after + 1)
		} else if bytes.get(after) == Ok(']') {
			$more = Bool.False
		} else {
			return Err(Malformed)
		}
	}
	Ok($out)
}

## Where the value that begins at `i` ends: the index after its last byte.
value_end : List(U8), U64 -> Try(U64, [Missing, Malformed])
value_end = |bytes, i|
	match bytes.get(i) {
		Ok('"') => string_end(bytes, i)
		Ok('{') => nested_end(bytes, i)
		Ok('[') => nested_end(bytes, i)
		Ok(_) => {
			var $at = i
			while $at < bytes.len() and !is_stop(bytes.get($at) ?? ',') {
				$at = $at + 1
			}
			if ($at == i) Err(Malformed) else Ok($at)
		}
		Err(_) => Err(Malformed)
	}

## Whether a number or a literal (`true`, `null`) ends at `byte`.
is_stop : U8 -> Bool
is_stop = |byte| byte == ',' or byte == '}' or byte == ']' or is_space(byte)

## Where the string whose `"` is at `i` ends: the index after its closing `"`.
string_end : List(U8), U64 -> Try(U64, [Missing, Malformed])
string_end = |bytes, i| {
	if bytes.get(i) != Ok('"') {
		return Err(Malformed)
	}
	var $at = i + 1
	while $at < bytes.len() and bytes.get($at) != Ok('"') {
		$at = $at + (if (bytes.get($at) == Ok(92)) 2 else 1)
	}
	if ($at < bytes.len()) Ok($at + 1) else Err(Malformed)
}

## Where the object or array whose `{` or `[` is at `i` ends: the index after its closing bracket
## (strings in it skipped, so a bracket in one doesn't count).
nested_end : List(U8), U64 -> Try(U64, [Missing, Malformed])
nested_end = |bytes, i| {
	var $depth = 0
	var $at = i
	var $end = 0
	while $at < bytes.len() and $end == 0 {
		byte = bytes.get($at) ?? 0
		if byte == '"' {
			$at = string_end(bytes, $at)?
		} else {
			if byte == '{' or byte == '[' {
				$depth = $depth + 1
			} else if byte == '}' or byte == ']' {
				$depth = $depth - 1
				if $depth == 0 {
					$end = $at + 1
				}
			}
			$at = $at + 1
		}
	}
	if ($end == 0) Err(Malformed) else Ok($end)
}

# ---- signatures ----
sample : List(U8)
sample = "{\"id\":\"evt_1\",\"object\":\"event\"}".to_utf8()

# Made with Node: crypto.createHmac("sha256", "whsec_test").update("1700000000." + sample).digest("hex").
expect StripeRules.signature("whsec_test", 1700000000, sample) == "t=1700000000,v1=4c15fb2a43f93ef61eaa3e0893866d57cad9cad4223242cfb96f362480cb4021"
expect StripeRules.verify(StripeRules.signature("whsec_test", 1700000000, sample), sample, "whsec_test", 1700000100) == Ok({})
expect StripeRules.verify("t=1700000000,v1=00,v1=4c15fb2a43f93ef61eaa3e0893866d57cad9cad4223242cfb96f362480cb4021,v0=ab", sample, "whsec_test", 1700000000) == Ok({})
expect StripeRules.verify(StripeRules.signature("whsec_other", 1700000000, sample), sample, "whsec_test", 1700000000) == Err(Forged)
expect StripeRules.verify(StripeRules.signature("whsec_test", 1700000000, sample), "{}".to_utf8(), "whsec_test", 1700000000) == Err(Forged)
expect StripeRules.verify(StripeRules.signature("whsec_test", 1700000000, sample), sample, "whsec_test", 1700000301) == Err(Stale(301))
expect StripeRules.verify("t=1700000000", sample, "whsec_test", 1700000000) == Err(Unsigned)
expect StripeRules.verify("v1=4c15fb2a", sample, "whsec_test", 1700000000) == Err(Unsigned)
expect StripeRules.verify("", sample, "whsec_test", 1700000000) == Err(Unsigned)
expect StripeRules.verify(StripeRules.signature("", 1700000000, sample), sample, "", 1700000000) == Err(Unsigned)

# ---- reading JSON ----
doc : Str
doc = "{ \"id\": \"sub_1\", \"n\": -12, \"ok\": true, \"none\": null, \"s\": \"a \\\"b\\\" {c}\", \"o\": { \"id\": \"cus_9\", \"deep\": [1, {\"x\": \"]\"}, 3] }, \"list\": [ {\"a\": 1}, {\"a\": 2} ] }"

expect StripeRules.text(doc, ["id"]) == "sub_1"
expect StripeRules.text(doc, ["s"]) == "a \"b\" {c}"
expect StripeRules.int(doc, ["n"]) == -12
expect StripeRules.int(doc, ["none"]) == 0
expect StripeRules.bool(doc, ["ok"]) and !StripeRules.bool(doc, ["n"])
expect StripeRules.text(doc, ["none"]) == "" and StripeRules.text(doc, ["nowhere"]) == "" and StripeRules.text(doc, ["id", "x"]) == ""
expect StripeRules.id_at(doc, ["o"]) == "cus_9" and StripeRules.id_at(doc, ["id"]) == "sub_1" and StripeRules.id_at(doc, ["none"]) == ""
expect StripeRules.at(doc, ["o", "deep"]) == Ok("[1, {\"x\": \"]\"}, 3]")
expect StripeRules.elements(StripeRules.at(doc, ["list"]) ?? "") == ["{\"a\": 1}", "{\"a\": 2}"]
expect StripeRules.elements("[]") == [] and StripeRules.elements("{}") == []
expect StripeRules.strings("{\"app_user_id\":\"u1\",\"n\":2,\"plan\":\"pro\"}") == [("app_user_id", "u1"), ("plan", "pro")]
expect StripeRules.at("{\"a\": ", ["a"]).is_err()
expect StripeRules.event("{\"id\":\"evt_1\",\"type\":\"invoice.paid\",\"created\":1700000000,\"livemode\":false,\"data\":{\"object\":{\"id\":\"in_1\"}}}") == Ok({ id: "evt_1", type: "invoice.paid", created: 1700000000, livemode: Bool.False, object: "{\"id\":\"in_1\"}" })
expect StripeRules.event("{\"id\":\"evt_1\"}").is_err()

# ---- objects, from two API versions ----
# 2025-03-31.basil: the period's end is each item's.
basil : Str
basil = "{\"id\":\"sub_1\",\"object\":\"subscription\",\"customer\":\"cus_1\",\"status\":\"active\",\"cancel_at_period_end\":true,\"cancel_at\":1702592000,\"trial_end\":null,\"metadata\":{\"app_user_id\":\"u1\"},\"items\":{\"object\":\"list\",\"data\":[{\"id\":\"si_1\",\"current_period_end\":1702592000,\"price\":{\"id\":\"price_pro\",\"product\":\"prod_pro\",\"unit_amount\":900},\"quantity\":2}]}}"

# Before: the subscription's own.
acacia : Str
acacia = "{\"id\":\"sub_2\",\"customer\":{\"id\":\"cus_2\",\"object\":\"customer\"},\"status\":\"past_due\",\"current_period_end\":1700000000,\"cancel_at_period_end\":false,\"cancel_at\":null,\"trial_end\":1690000000,\"metadata\":{},\"items\":{\"data\":[{\"price\":{\"id\":\"price_basic\",\"product\":{\"id\":\"prod_basic\"}},\"quantity\":null}]}}"

expect StripeRules.subscription(basil) == Ok({ id: "sub_1", customer: "cus_1", status: "active", items: [{ price: "price_pro", product: "prod_pro", quantity: 2 }], current_period_end: 1702592000, cancel_at_period_end: Bool.True, cancel_at: 1702592000, trial_end: 0, user: "u1" })
expect StripeRules.subscription(acacia) == Ok({ id: "sub_2", customer: "cus_2", status: "past_due", items: [{ price: "price_basic", product: "prod_basic", quantity: 0 }], current_period_end: 1700000000, cancel_at_period_end: Bool.False, cancel_at: 0, trial_end: 1690000000, user: "" })
expect StripeRules.subscription("{\"id\":\"in_1\"}").is_err()
expect StripeRules.session("{\"id\":\"cs_test_1\",\"mode\":\"payment\",\"status\":\"complete\",\"payment_status\":\"paid\",\"client_reference_id\":\"u1\",\"customer\":\"cus_1\",\"subscription\":null,\"amount_total\":1500,\"currency\":\"eur\",\"url\":null,\"metadata\":{\"app_user_id\":\"u1\",\"order\":\"7\"},\"payment_intent\":\"pi_1\"}") == Ok({ id: "cs_test_1", mode: "payment", status: "complete", payment_status: "paid", user: "u1", customer: "cus_1", subscription: "", amount_total: 1500, currency: "eur", url: "", metadata: [("app_user_id", "u1"), ("order", "7")], payment_intent: "pi_1" })
expect StripeRules.charge_change("charge.refunded", "{\"id\":\"ch_1\",\"payment_intent\":\"pi_1\",\"refunded\":true,\"amount_refunded\":900}") == Refunded("pi_1")
expect StripeRules.charge_change("charge.refunded", "{\"id\":\"ch_1\",\"payment_intent\":\"pi_1\",\"refunded\":false,\"amount_refunded\":100}") == Unchanged
expect StripeRules.charge_change("charge.dispute.created", "{\"id\":\"dp_1\",\"charge\":\"ch_1\",\"payment_intent\":\"pi_1\",\"status\":\"needs_response\"}") == Disputed("pi_1")
expect StripeRules.charge_change("charge.dispute.closed", "{\"id\":\"dp_1\",\"payment_intent\":\"pi_1\",\"status\":\"won\"}") == Settled("pi_1")
expect StripeRules.charge_change("charge.dispute.closed", "{\"id\":\"dp_1\",\"payment_intent\":\"pi_1\",\"status\":\"lost\"}") == Unchanged
expect StripeRules.charge_change("charge.refunded", "{\"id\":\"ch_1\",\"payment_intent\":null,\"refunded\":true}") == Unchanged
expect StripeRules.session("{\"id\":\"cs_test_2\",\"client_reference_id\":null,\"metadata\":{\"app_user_id\":\"u2\"},\"subscription\":{\"id\":\"sub_3\"}}").map_ok(|s| (s.user, s.subscription)) == Ok(("u2", "sub_3"))
expect StripeRules.invoice("{\"id\":\"in_1\",\"customer\":\"cus_1\",\"subscription\":\"sub_1\",\"status\":\"paid\",\"amount_due\":900,\"amount_paid\":900,\"currency\":\"usd\",\"hosted_invoice_url\":\"https://invoice.stripe.com/i/x\",\"attempt_count\":1,\"billing_reason\":\"subscription_cycle\"}").map_ok(|i| (i.subscription, i.amount_paid, i.attempt_count)) == Ok(("sub_1", 900, 1))
expect StripeRules.invoice("{\"id\":\"in_2\",\"customer\":\"cus_1\",\"parent\":{\"type\":\"subscription_details\",\"subscription_details\":{\"subscription\":\"sub_9\",\"metadata\":{}}},\"status\":\"open\",\"amount_due\":900,\"amount_paid\":0,\"currency\":\"usd\",\"attempt_count\":2}").map_ok(|i| (i.subscription, i.hosted_url, i.attempt_count)) == Ok(("sub_9", "", 2))

# ---- order ----
expect StripeRules.version(100, "customer.subscription.created") < StripeRules.version(100, "customer.subscription.updated")
expect StripeRules.version(100, "customer.subscription.updated") < StripeRules.version(100, "customer.subscription.deleted")
expect StripeRules.version(100, "customer.subscription.deleted") < StripeRules.version(101, "customer.subscription.created")

# ---- the checkout's form, and where it goes back to ----
expect
	StripeRules.checkout_form({ mode: "subscription", customer: "cus_1", user: "u1", prices: [{ price: "price_pro", quantity: 1 }, { price: "price_seat", quantity: 3 }], success_url: "https://a.example/done?session_id={CHECKOUT_SESSION_ID}", cancel_url: "https://a.example/", trial_days: 14, promotion_codes: Bool.True, metadata: [("plan", "pro"), ("app_user_id", "someone else")] })
		== [
			("mode", "subscription"),
			("customer", "cus_1"),
			("client_reference_id", "u1"),
			("success_url", "https://a.example/done?session_id={CHECKOUT_SESSION_ID}"),
			("cancel_url", "https://a.example/"),
			("line_items[0][price]", "price_pro"),
			("line_items[0][quantity]", "1"),
			("line_items[1][price]", "price_seat"),
			("line_items[1][quantity]", "3"),
			("metadata[app_user_id]", "u1"),
			("metadata[plan]", "pro"),
			("subscription_data[metadata][app_user_id]", "u1"),
			("subscription_data[trial_period_days]", "14"),
			("allow_promotion_codes", "true"),
		]
expect StripeRules.checkout_form({ mode: "payment", customer: "cus_1", user: "u1", prices: [], success_url: "s", cancel_url: "c", trial_days: 14, promotion_codes: Bool.False, metadata: [] }).contains(("payment_intent_data[metadata][app_user_id]", "u1"))
expect !StripeRules.checkout_form({ mode: "payment", customer: "cus_1", user: "u1", prices: [], success_url: "s", cancel_url: "c", trial_days: 14, promotion_codes: Bool.False, metadata: [] }).any(|(name, _)| name.contains("trial"))
expect StripeRules.absolute("/billing/done", "https://a.example") == "https://a.example/billing/done"
expect StripeRules.absolute("https://b.example/x", "https://a.example") == "https://b.example/x"
expect StripeRules.absolute("//b.example/x", "https://a.example") == "//b.example/x"
expect StripeRules.with_session_id("https://a.example/done") == "https://a.example/done?session_id={CHECKOUT_SESSION_ID}"
expect StripeRules.with_session_id("https://a.example/done?plan=pro#top") == "https://a.example/done?plan=pro&session_id={CHECKOUT_SESSION_ID}#top"
expect StripeRules.with_session_id("https://a.example/done/{CHECKOUT_SESSION_ID}") == "https://a.example/done/{CHECKOUT_SESSION_ID}"
# sha256("u1\nada@example.com"), its first 40 hex digits.
expect StripeRules.customer_key("u1", "ada@example.com") == "rocx-customer-61d7b562b7822e79635adf55ae8bf867c506f8cf"
expect StripeRules.problem(400, "{\"error\":{\"type\":\"invalid_request_error\",\"message\":\"No such price: 'price_x'\"}}") == "No such price: 'price_x'"
expect StripeRules.problem(502, "<html>") == "Stripe answered 502"
expect StripeRules.no_customer("{\"error\":{\"code\":\"resource_missing\",\"param\":\"customer\",\"message\":\"No such customer\"}}")
expect !StripeRules.no_customer("{\"error\":{\"code\":\"resource_missing\",\"param\":\"line_items[0][price]\"}}")
expect StripeRules.is_session_id("cs_test_a1B2") and !StripeRules.is_session_id("cs_test/../x") and !StripeRules.is_session_id("sub_1")
expect StripeRules.price_in("{\"object\":\"list\",\"data\":[{\"id\":\"price_pro\",\"lookup_key\":\"pro_monthly\"}],\"has_more\":false}") == Ok("price_pro")
expect StripeRules.price_in("{\"object\":\"list\",\"data\":[],\"has_more\":false}") == Err(NoPrice)
expect StripeRules.price_in("nonsense") == Err(NoPrice)

# ---- invoices listed, a card, the portal at the card, ending at the period's end ----
expect StripeRules.invoice("{\"id\":\"in_3\",\"customer\":\"cus_1\",\"status\":\"paid\",\"created\":1700000000,\"number\":\"B7D2A1C4-0001\",\"invoice_pdf\":\"https://pay.stripe.com/invoice/x/pdf\"}").map_ok(|i| (i.created, i.number, i.pdf_url)) == Ok((1700000000, "B7D2A1C4-0001", "https://pay.stripe.com/invoice/x/pdf"))
expect StripeRules.invoice("{\"id\":\"in_4\",\"status\":\"draft\",\"number\":null,\"invoice_pdf\":null}").map_ok(|i| (i.created, i.number, i.pdf_url)) == Ok((0, "", ""))
expect StripeRules.invoices_in("{\"object\":\"list\",\"data\":[{\"id\":\"in_old\",\"created\":100},{\"id\":\"cus_x\"},{\"id\":\"in_new\",\"created\":200}],\"has_more\":false}").map(|i| i.id) == ["in_new", "in_old"]
expect StripeRules.invoices_in("{\"data\":[]}") == [] and StripeRules.invoices_in("{}") == []
expect StripeRules.card_at("{\"id\":\"sub_1\",\"default_payment_method\":{\"id\":\"pm_1\",\"type\":\"card\",\"card\":{\"brand\":\"visa\",\"last4\":\"4242\",\"exp_month\":12,\"exp_year\":2034}}}", ["default_payment_method"]) == Ok({ brand: "visa", last4: "4242", exp_month: 12, exp_year: 2034 })
expect StripeRules.card_at("{\"invoice_settings\":{\"default_payment_method\":{\"type\":\"card\",\"card\":{\"brand\":\"mastercard\",\"last4\":\"4444\",\"exp_month\":1,\"exp_year\":2030}}}}", ["invoice_settings", "default_payment_method"]).map_ok(|card| card.brand) == Ok("mastercard")
expect StripeRules.card_at("{\"default_payment_method\":\"pm_1\"}", ["default_payment_method"]) == Err(NoCard)
expect StripeRules.card_at("{\"default_payment_method\":null}", ["default_payment_method"]) == Err(NoCard)
expect StripeRules.card_at("{\"default_payment_method\":{\"type\":\"us_bank_account\",\"us_bank_account\":{\"last4\":\"6789\"}}}", ["default_payment_method"]) == Err(NoCard)
expect StripeRules.card_portal_form("cus_1", "https://example.com/account").contains(("flow_data[after_completion][redirect][return_url]", "https://example.com/account"))
expect StripeRules.card_portal_form("cus_1", "https://example.com/account").contains(("flow_data[type]", "payment_method_update"))
expect StripeRules.ends_form(Bool.True, Bool.False, 0) == [("cancel_at_period_end", "true")]
expect StripeRules.ends_form(Bool.False, Bool.True, 1702592000000) == [("cancel_at_period_end", "false")]
expect StripeRules.ends_form(Bool.False, Bool.False, 1702592000000) == [("cancel_at", "")]
expect StripeRules.ends_form(Bool.False, Bool.False, 0) == [("cancel_at_period_end", "false")]
