import Host

## A WebSocket to a server on this machine (plain `ws://`, text messages): what packages/headless
## drives a browser over (Chromium's DevTools protocol). The host keeps each message that comes
## until it is taken, so asking needs no loop, counter or queue of the program's own: `request!`
## sends a JSON object with an `id` the socket numbers and takes the message answering it (one whose
## top-level `id` is that number, as the DevTools protocol, WebDriver BiDi and JSON-RPC answer),
## wherever it is among those waiting; `receive!` takes the oldest still waiting (a protocol's
## events), in their order.
WebSocket := { id : U64 }.{

	## Opens a socket to `url` (`ws://127.0.0.1:9222/devtools/browser/…`); `CantConnect` says why it
	## couldn't (nothing listens there, or it didn't switch to a WebSocket).
	connect! : Str => Try(WebSocket, [CantConnect(Str)])
	connect! = |url|
		match Host.ws_connect!(url) {
			Ok(id) => {
				socket : WebSocket
				socket = { id: id }
				Ok(socket)
			}
			Err(why) => Err(CantConnect(why))
		}

	## Sends a text message; `Closed` when the socket has closed.
	send! : WebSocket, Str => Try({}, [Closed(Str)])
	send! = |socket, text|
		match Host.ws_send!(socket.id, text) {
			Ok({}) => Ok({})
			Err(why) => Err(Closed(why))
		}

	## Sends `object` (a JSON object, `{"method":"Page.navigate","params":{…}}`, without an `id`) with
	## the socket's next `id` (1, 2, 3…) put first in it, and the message answering it, as soon as it
	## comes, up to `ms` milliseconds (0: as long as it takes). Messages that came before it stay, in
	## their order, for `receive!`. `NotAnObject`: `object` doesn't start with `{`, and nothing was sent.
	request! : WebSocket, Str, U64 => Try(Str, [Timeout, Closed(Str), NotAnObject])
	request! = |socket, object, ms|
		match Host.ws_request!(socket.id, object, ms) {
			{ kind: 3, .. } => Err(NotAnObject)
			got =>
				match taken(got) {
					Ok(text) => Ok(text)
					Err(Timeout) => Err(Timeout)
					Err(Closed(why)) => Err(Closed(why))
				}
		}

	## The oldest message still waiting, as soon as there is one, up to `ms` milliseconds (0: only a
	## message already there).
	receive! : WebSocket, U64 => Try(Str, [Timeout, Closed(Str)])
	receive! = |socket, ms| taken(Host.ws_receive!(socket.id, ms))

	## Closes the socket; the messages still waiting on it go with it.
	close! : WebSocket => {}
	close! = |socket| Host.ws_close!(socket.id)
}

taken : { kind : U8, text : Str } -> Try(Str, [Timeout, Closed(Str)])
taken = |got|
	match got.kind {
		0 => Ok(got.text)
		1 => Err(Timeout)
		_ => Err(Closed(got.text))
	}
