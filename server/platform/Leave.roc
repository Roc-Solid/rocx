import Host

## A navigation about to leave the page, as Solid Router's `useBeforeLeave` gives it
## (`BeforeLeaveEventArgs`, D-040): a `Router.use_before_leave!` listener is given one before each
## navigation in place (a link, `Router.navigate!`, `<Navigate>`, a GET form, a submission's
## redirect, a change of the query alone, back and forward), and may stop it (`prevent!`), then let
## it go later (`retry!`), from another handler: an app's own "Discard your changes?" dialog.
##
##     (leaving!, set_leaving!) = create_signal!(Err(Staying))
##     use_before_leave!(|leave|
##         if dirty!() {
##             leave.prevent!()
##             set_leaving!(Ok(leave))
##         }
##     )
##     <button on:click={|| match leaving!() { Ok(leave) => leave.retry!(Bool.True), Err(_) => {} }}>Discard</button>
##
## - `to`: where it goes, a path and its query as `Router.location!` writes them (`/lists/3?tab=done`,
##   the site's base left out); "" for a load (leaving the site, reloading, closing the tab), which
##   the browser doesn't say where.
## - `from`: where the page is, as `Router.location!` says it.
## - `options`: a link's or `navigate_with!`'s `replace` and `scroll`; back and forward, neither
##   replaces, and both scroll to where the entry was.
## - `delta`: back and forward, how far in history (`-1`: back one entry), Solid Router's numeric
##   `to`; 0 for the others.
## - `default_prevented`: a listener asked before this one stopped it.
## - `id`: the runtime's, for `prevent!` and `retry!`.
Leave := { id : U64, to : Str, from : { path : Str, query : Str }, options : { replace : Bool, scroll : Bool }, delta : I64, default_prevented : Bool }.{

	## Stops the navigation (Solid Router's `preventDefault`): the page stays, and its address (back
	## and forward's, already changed, is put back). Only while its listeners are being asked: the
	## navigation is decided once they have all run, so a listener decides from what the page has
	## (a signal, a memo already in), not from the server.
	prevent! : Leave => {}
	prevent! = |leave| Host.leave_prevent!(leave.id)

	## Navigates where it was going after all (Solid Router's `retry`), from a handler, once it is
	## done: a dialog's "Discard" button, long after the listener stopped it. With `force`, the
	## listeners aren't asked again; without, they are, so one whose reason has gone (the form saved
	## since) lets it go. Back and forward go there again in history, while the page is still on the
	## entry it was left from (else to its URL). Anywhere but a handler it fails; on the server, no
	## handler runs.
	retry! : Leave, Bool => {}
	retry! = |leave, force| Host.leave_retry!(leave.id, force)

	## A leave as the runtime tells it (`Host.event_value!`), a line each: its id, `to`, the path and
	## the query it leaves, `replace` and `scroll` (`1` or `0`), `delta`, and whether a listener
	## before stopped it.
	of : Str -> Leave
	of = |said| {
		lines = said.split_on("\n")
		at = |index| lines.get(index) ?? ""
		{
			id: U64.from_str(at(0)) ?? 0,
			to: at(1),
			from: { path: if (at(2).is_empty()) "/" else at(2), query: at(3) },
			options: { replace: at(4) == "1", scroll: at(5) == "1" },
			delta: I64.from_str(at(6)) ?? 0,
			default_prevented: at(7) == "1",
		}
	}
}

expect {
	leave = Leave.of("12\n/a?x=1\n/editor\ndraft=2\n0\n1\n-1\n1")
	leave.id == 12 and leave.to == "/a?x=1" and leave.from == { path: "/editor", query: "draft=2" } and leave.options == { replace: Bool.False, scroll: Bool.True } and leave.delta == -1 and leave.default_prevented
}

expect {
	leave = Leave.of("0\n\n/\n\n0\n1\n0\n0")
	leave.id == 0 and leave.to == "" and leave.from == { path: "/", query: "" } and leave.delta == 0 and !leave.default_prevented
}

expect Leave.of("").from.path == "/"
