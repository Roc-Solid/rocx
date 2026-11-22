import pf.Kv
import pf.Endpoint
import pf.Env
import Board

## Who is editing a card: a lease, kept in the server's memory (`Kv`, D-028) under the card's id for
## `ttl_ms!`. An open card takes it, renews it every `Board.renew_every`, and lets it go when it is closed;
## while someone holds it, everyone else sees "Ada is editing" and can't change the card. A tab that
## vanishes renews it no more, and it runs out on its own.
##
## A lease is memory only: a restart forgets them all, which is right for something that lasts half
## a minute.
Lease := [].{

	## Who holds a lease.
	Held : { person : Str, name : Str }

	## How long a lease lasts without being renewed: 30 s, three of an open card's renewals
	## (`Board.renew_every`), or what `BOARD_LEASE_TTL_MS` says (the tests' is short, so a lease
	## runs out while they wait).
	ttl_ms! : {} => U64
	ttl_ms! = |{}| U64.from_str(Env.var!("BOARD_LEASE_TTL_MS") ?? "") ?? 30_000

	## Where a card's lease is kept.
	key : Str -> Str
	key = |card| "board:lease:${card}"

	## The lease on `card` for `me`: theirs (taken now, or renewed), or `HeldBy` whoever has it.
	take! : Str, Board.Person => Try({}, [HeldBy(Lease.Held)])
	take! = |card, me| {
		mine = { person: me.id, name: me.name }
		ttl_ms = Lease.ttl_ms!({})
		# `add!` writes only where nothing is: of two people taking a free lease at once, one gets it.
		match Kv.add!(Lease.key(card), mine, { ttl_ms: ttl_ms }) {
			Ok({}) => Ok({})
			Err(Exists) =>
				match Lease.holder!(card) {
					Ok(held) if held.person == me.id => {
						Kv.set!(Lease.key(card), mine, { ttl_ms: ttl_ms })
						Ok({})
					}
					Ok(held) => Err(HeldBy(held))
					# It ran out between the two: try once more.
					Err(NotFound) =>
						match Kv.add!(Lease.key(card), mine, { ttl_ms: ttl_ms }) {
							Ok({}) => Ok({})
							Err(Exists) => Err(HeldBy(Lease.holder!(card) ?? { person: "", name: "Someone" }))
						}
				}
		}
	}

	## Who holds the lease on `card`, if anyone.
	holder! : Str => Try(Lease.Held, [NotFound])
	holder! = |card| {
		kept : Try(Lease.Held, [NotFound, BadValue(Str)])
		kept = Kv.get!(Lease.key(card))
		match kept {
			Ok(held) => Ok(held)
			Err(_) => Err(NotFound)
		}
	}

	## Lets `card`'s lease go, if `me` holds it.
	release! : Str, Board.Person => Bool
	release! = |card, me|
		match Lease.holder!(card) {
			Ok(held) if held.person == me.id => {
				Kv.delete!(Lease.key(card))
				Bool.True
			}
			_ => Bool.False
		}

	## Whether `me` may change `card`: no one else is editing it. Holding the lease, or nobody
	## holding it (a browser without JavaScript never takes one), both may.
	check! : Str, Board.Person => Try({}, [HeldBy(Lease.Held)])
	check! = |card, me|
		match Lease.holder!(card) {
			Ok(held) if held.person != me.id => Err(HeldBy(held))
			_ => Ok({})
		}

	## `check!`, as a route answers it: a 409 that says who is editing.
	editable! : Str, Board.Person => Try({}, Endpoint.Refusal)
	editable! = |card, me|
		match Lease.check!(card, me) {
			Ok({}) => Ok({})
			Err(HeldBy(held)) => Err(Conflict("${held.name} is editing this card."))
		}

	## Who is editing which of `cards`.
	of! : List(Str) => List(Board.Lease)
	of! = |cards| {
		var $leases = []
		for card in cards {
			match Lease.holder!(card) {
				Ok(held) => {
					$leases = $leases.append({ card, person: held.person, name: held.name })
				}
				Err(NotFound) => {}
			}
		}
		$leases
	}
}
