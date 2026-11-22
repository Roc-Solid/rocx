import Host

## A TCP connection, plain or over TLS: what a client of another server is built on (an SMTP
## server: packages/email's `Smtp`; Postgres: roc-pg). Shaped as basic-cli's, so packages written
## for it take a connection from here as they are: `connect!`, then `write_bytes!` and
## `read_exactly!`.
##
## Each effect blocks the call's own thread until it is done, as the platform's others do. A
## connection belongs to the call that made it, and is closed when that call ends, if not before.
Tcp :: [Connection(U64)].{

	## A connection to `host` at `port`.
	connect! : Str, U16 => Try(Tcp, [TcpErr(Str)])
	connect! = |host, port| opened(Host.tcp_connect!(host, port, Bool.False))

	## A connection over TLS (`smtps`, port 465), the server's certificate checked against the
	## web's certificate authorities, for `host`.
	connect_tls! : Str, U16 => Try(Tcp, [TcpErr(Str)])
	connect_tls! = |host, port| opened(Host.tcp_connect!(host, port, Bool.True))

	## Goes on over TLS, checking that the server is `host`: SMTP's STARTTLS.
	start_tls! : Tcp, Str => Try({}, [TcpErr(Str)])
	start_tls! = |tcp, host|
		match Host.tcp_start_tls!(id_of(tcp), host) {
			Ok({}) => Ok({})
			Err(why) => Err(TcpErr(why))
		}

	## Sends `bytes`, all of them, waiting until they are written.
	write_bytes! : Tcp, List(U8) => Try({}, [TcpErr(Str)])
	write_bytes! = |tcp, bytes|
		match Host.tcp_write!(id_of(tcp), bytes) {
			Ok({}) => Ok({})
			Err(why) => Err(TcpErr(why))
		}

	## Sends `text`, as UTF-8.
	write_utf8! : Tcp, Str => Try({}, [TcpErr(Str)])
	write_utf8! = |tcp, text| tcp.write_bytes!(text.to_utf8())

	## Exactly `count` bytes, waiting for them all.
	read_exactly! : Tcp, U64 => Try(List(U8), [UnexpectedEndOfInput, TcpErr(Str)])
	read_exactly! = |tcp, count|
		match Host.tcp_read_exactly!(id_of(tcp), count) {
			Ok(bytes) => Ok(bytes)
			Err("eof") => Err(UnexpectedEndOfInput)
			Err(why) => Err(TcpErr(why))
		}

	## What has come, `count` bytes at most, waiting for some: none once the other end has closed.
	read_up_to! : Tcp, U64 => Try(List(U8), [TcpErr(Str)])
	read_up_to! = |tcp, count|
		match Host.tcp_read_up_to!(id_of(tcp), count) {
			Ok(bytes) => Ok(bytes)
			Err(why) => Err(TcpErr(why))
		}

	## Up to and including the next `byte` (`'\n'`: a line).
	read_until! : Tcp, U8 => Try(List(U8), [EndOfInput, TcpErr(Str)])
	read_until! = |tcp, byte|
		match Host.tcp_read_until!(id_of(tcp), byte) {
			Ok(bytes) => Ok(bytes)
			Err("eof") => Err(EndOfInput)
			Err(why) => Err(TcpErr(why))
		}

	## Closes the connection. Using it after is a `TcpErr`.
	close! : Tcp => {}
	close! = |tcp| Host.tcp_close!(id_of(tcp))
}

opened : Try(U64, Str) -> Try(Tcp, [TcpErr(Str)])
opened = |made|
	match made {
		Ok(id) => Ok(Connection(id))
		Err(why) => Err(TcpErr(why))
	}

id_of : Tcp -> U64
id_of = |tcp|
	match tcp {
		Connection(id) => id
	}
