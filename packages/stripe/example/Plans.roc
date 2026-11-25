import pf.Env

## What the example sells: two plans to subscribe to and an e-book bought once, each one of your
## Stripe account's prices (made in the Dashboard's product catalog): `STRIPE_PRICE_BASIC` and
## `STRIPE_PRICE_PRO`, recurring monthly, and `STRIPE_PRICE_EBOOK`, one-time. Without them, the
## ids the tests' stand-in for Stripe has.
Plans := [].{

	## Something to buy: its name, its price at Stripe, whether it is a subscription, what it costs
	## and what it gives, as the pricing page says them.
	Plan : { name : Str, price : Str, subscription : Bool, cost : Str, blurb : Str }

	## Everything the pricing page offers.
	all! : {} => List(Plans.Plan)
	all! = |{}| [
		{ name: "Basic", price: price!("STRIPE_PRICE_BASIC", "price_basic"), subscription: Bool.True, cost: "$5 a month", blurb: "The pro pages, for one." },
		{ name: "Pro", price: price!("STRIPE_PRICE_PRO", "price_pro"), subscription: Bool.True, cost: "$15 a month", blurb: "The pro pages, and our thanks." },
		{ name: "The e-book", price: Plans.ebook!({}), subscription: Bool.False, cost: "$9, once", blurb: "Ours to keep: a book about Roc." },
	]

	## The plan whose price is `price`; `NotFound` for one the page doesn't offer.
	of! : Str => Try(Plans.Plan, [NotFound])
	of! = |price| Plans.all!({}).find_first(|plan| plan.price == price).map_err(|_| NotFound)

	## The e-book's price.
	ebook! : {} => Str
	ebook! = |{}| price!("STRIPE_PRICE_EBOOK", "price_ebook")

	## The names of the plans these prices are (a price the page doesn't offer as itself).
	named! : List(Str) => Str
	named! = |prices| {
		plans = Plans.all!({})
		Str.join_with(prices.map(|price| plans.find_first(|plan| plan.price == price).map_ok(|plan| plan.name) ?? price), ", ")
	}

	## A day as people read it, from milliseconds since 1970 (UTC): `2026-12-25`.
	day : I64 -> Str
	day = |ms| {
		# Howard Hinnant's days-to-civil, for days since 1970-03-01 in eras of 400 years.
		z = ms // 86_400_000 + 719_468
		era = z // 146_097
		doe = z - era * 146_097
		yoe = (doe - doe // 1460 + doe // 36_524 - doe // 146_096) // 365
		doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
		mp = (5 * doy + 2) // 153
		d = doy - (153 * mp + 2) // 5 + 1
		m = if (mp < 10) mp + 3 else mp - 9
		y = yoe + era * 400 + (if (m <= 2) 1 else 0)
		"${y.to_str()}-${two(m)}-${two(d)}"
	}
}

## The price in the environment variable `name`, else `otherwise`.
price! : Str, Str => Str
price! = |name, otherwise| {
	given = (Env.var!(name) ?? "").trim()
	if (given.is_empty()) otherwise else given
}

## A number of one or two digits, as two.
two : I64 -> Str
two = |n| if (n < 10) "0${n.to_str()}" else n.to_str()

expect Plans.day(0) == "1970-01-01"
expect Plans.day(951_782_400_000) == "2000-02-29"
expect Plans.day(4_102_444_799_999) == "2099-12-31"
