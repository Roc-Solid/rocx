## What POST /echo/json is sent and answers: an order, as a shop's API might take one. It nests (a
## customer with an address, items with tags of their own, shipping), so reading it is JSON parsing
## into a typed record and answering it is encoding one: what most endpoints do with a body, which
## POST /echo's string barely asks for. order.json is the one the benchmark sends.
Shop := [].{

	Order : {
		id : Str,
		placed_at : Str,
		paid : Bool,
		customer : {
			id : U64,
			name : Str,
			email : Str,
			address : { street : Str, city : Str, postcode : Str, country : Str },
		},
		items : List({ sku : Str, name : Str, quantity : U64, price_cents : U64, tags : List(Str) }),
		shipping : { method : Str, price_cents : U64 },
		notes : Str,
	}
}
