import pf.Kv
import pf.Endpoint
import pf.Env
import Board

## Who is editing a card: a lease, kept in the server's memory (`Kv`, D-028) under the card's id for
## `ttl_ms!`. An open card takes it, renews it every `Board.renew_every`, and lets it go when it is closed;
## while someone holds it, everyone else sees "Ada is editing" and can't change the card. A tab that
## vanishes renews it no more, and it runs out on its own.
##
## Each opening of a card has a token of its own, which it takes the lease with and lets it go with.
## Letting it go leaves the lease marked as let go by that token, for as long as a lease lasts, so a
## take the card sent before it was closed, still on its way (a renewal, or the board read again
## after a save), finds it let go and takes nothing. Every write is an `add!` where nothing is or a
## `swap!` of what was read, so of a take and a release at once, whichever comes second sees the
## other's.
##
## A lease is memory only: a restart forgets them all, which is right for something that lasts half
## a minute.
Lease := [].{

	## Who holds a lease.
	Held : { person : Str, name : Str }

	## A lease as it is kept: held by `person`, taken with `token`; or, when `held` is false, let go
	## by `person` with `token`.
	Kept : { person : Str, name : Str, token : Str, held : Bool }

	## How long a lease lasts without being renewed: 30 s, three of an open card's renewals
	## (`Board.renew_every`), or what `BOARD_LEASE_TTL_MS` says (the tests' is short, so a lease
	## runs out while they wait).
	ttl_ms! : {} => U64
	ttl_ms! = |{}| U64.from_str(Env.var!("BOARD_LEASE_TTL_MS") ?? "") ?? 30_000

	## Where a card's lease is kept.
	key : Str -> Str
	key = |card| "board:lease:${card}"

	## The lease on `card`, as it is kept now.
	kept! : Str => Try(Lease.Kept, [NotFound, BadValue(Str)])
	kept! = |card| Kv.get!(Lease.key(card))

	## The lease on `card` for `me`, opening it with `token`: `Taken` (it was free, or let go),
	## `Renewed` (it was theirs already), `HeldBy` whoever else has it, or `LetGo` when this opening
	## has let it go (the card is closed, and this take was on its way).
	take! : Str, Board.Person, Str => Try([Taken, Renewed], [HeldBy(Lease.Held), LetGo])
	take! = |card, me, token| {
		mine = { person: me.id, name: me.name, token, held: Bool.True }
		ttl = { ttl_ms: Lease.ttl_ms!({}) }
		match Lease.kept!(card) {
			Ok(was) if !was.held and was.person == me.id and was.token == token => Err(LetGo)
			Ok(was) if was.held and was.person != me.id => Err(HeldBy({ person: was.person, name: was.name }))
			Ok(was) =>
				match Kv.swap!(Lease.key(card), was, mine, ttl) {
					Ok({}) => Ok(if (was.held) Renewed else Taken)
					# Someone wrote it after it was read: read it again.
					Err(Changed) => Lease.take!(card, me, token)
				}
			Err(NotFound) =>
				match Kv.add!(Lease.key(card), mine, ttl) {
					Ok({}) => Ok(Taken)
					Err(Exists) => Lease.take!(card, me, token)
				}
			# Not a lease (a value of another shape): replaced.
			Err(BadValue(_)) => {
				Kv.set!(Lease.key(card), mine, ttl)
				Ok(Taken)
			}
		}
	}

	## Who holds the lease on `card`, if anyone.
	holder! : Str => Try(Lease.Held, [NotFound])
	holder! = |card|
		match Lease.kept!(card) {
			Ok(kept) if kept.held => Ok({ person: kept.person, name: kept.name })
			_ => Err(NotFound)
		}

	## Lets `card`'s lease go for `me`'s opening `token`: whether it was theirs. It is marked as let
	## go by that token even when it wasn't held, so a first take still on its way (a card closed as
	## soon as it opened) takes nothing either; a lease someone else holds is left as it is.
	release! : Str, Board.Person, Str => Bool
	release! = |card, me, token| {
		let_go = { person: me.id, name: me.name, token, held: Bool.False }
		ttl = { ttl_ms: Lease.ttl_ms!({}) }
		match Lease.kept!(card) {
			Ok(was) if was.held and was.person != me.id => Bool.False
			Ok(was) =>
				match Kv.swap!(Lease.key(card), was, let_go, ttl) {
					Ok({}) => was.held
					Err(Changed) => Lease.release!(card, me, token)
				}
			Err(NotFound) =>
				match Kv.add!(Lease.key(card), let_go, ttl) {
					Ok({}) => Bool.False
					Err(Exists) => Lease.release!(card, me, token)
				}
			Err(BadValue(_)) => {
				Kv.set!(Lease.key(card), let_go, ttl)
				Bool.False
			}
		}
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
