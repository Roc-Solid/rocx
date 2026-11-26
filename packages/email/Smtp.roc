import pf.Tcp
import crypto.Base64

## Just enough SMTP to hand a message to a server: plain, STARTTLS (`?tls=required`, or
## `opportunistic`), or TLS from the start (`smtps://`), and AUTH PLAIN when the URL has a user.
## A password never goes in clear unless the URL says `?tls=never`: a URL with a user and no `tls`
## requires STARTTLS, and with `opportunistic` a server that doesn't offer it is refused.
Smtp := [].{

	## Where to send: `smtp://user:password@host:587?tls=required`, `smtps://user:password@host:465`.
	## `tls`: `Implicit` (`smtps://`); `Required` (`?tls=required`, and a URL with a user that says
	## nothing); `Opportunistic` (`?tls=opportunistic`); `Never` (`?tls=never`, and a URL without a
	## user that says nothing: a relay on this machine, a test's server).
	Url : { tls : [Implicit, Required, Opportunistic, Never], host : Str, port : U16, user : Str, password : Str }

	parse : Str -> Try(Url, Str)
	parse = |text|
		match text.split_first("://") {
			Err(_) => Err("SMTP_URL: smtp://… or smtps://…")
			Ok({ before: scheme, after: rest }) => {
				(authority, query) =
					match rest.split_first("?") {
						Ok({ before, after }) => (before, after)
						Err(_) => (rest, "")
					}
				parts = authority.split_on("@")
				host_port = parts.last() ?? ""
				user_info = Str.join_with(parts.drop_last(1), "@")
				(user, password) =
					match user_info.split_first(":") {
						Ok({ before, after }) => (decoded(before), decoded(after))
						Err(_) => (decoded(user_info), "")
					}
				asked =
					if query.contains("tls=required") {
						Asked(Required)
					} else if query.contains("tls=opportunistic") {
						Asked(Opportunistic)
					} else if query.contains("tls=never") {
						Asked(Never)
					} else {
						Unsaid
					}
				tls =
					match (scheme, asked) {
						("smtps", _) => Ok(Implicit)
						("smtp", Asked(how)) => Ok(how)
						("smtp", Unsaid) => Ok(if (user.is_empty()) Never else Required)
						_ => Err("SMTP_URL: smtp://… or smtps://…, not ${scheme}://")
					}
				(host, port_text) =
					match host_port.split_first(":") {
						Ok({ before, after }) => (before, after)
						Err(_) => (host_port, "")
					}
				default_port = if (scheme == "smtps") 465 else if (asked == Asked(Required)) 587 else 25
				port =
					if port_text.is_empty() {
						Ok(default_port)
					} else {
						match U16.from_str(port_text) {
							Ok(number) => Ok(number)
							Err(_) => Err("SMTP_URL: the port ${port_text} isn't a number")
						}
					}
				match (tls, port) {
					(Ok(how), Ok(number)) =>
						if (host.is_empty()) Err("SMTP_URL: no host") else Ok({ tls: how, host, port: number, user, password })
					(Err(why), _) => Err(why)
					(_, Err(why)) => Err(why)
				}
			}
		}

	## Hands `data` (the message, its lines ending in CRLF) to the server, from `from` to each of
	## `to` (bare addresses, a `RCPT TO` each). A recipient the server refuses fails it all, before
	## the message goes: nobody gets it.
	send! : Url, Str, List(Str), Str => Try({}, Str)
	send! = |url, from, to, data| {
		tcp = open!(url)?
		sent = deliver!(tcp, from, to, data)
		tcp.close!()
		sent
	}

	## Whether the server answers: its greeting, TLS if asked for, and a polite goodbye.
	check! : Url => Try({}, Str)
	check! = |url| {
		tcp = open!(url)?
		said = quit!(tcp)
		tcp.close!()
		said
	}
}

## A connection that has been greeted, said hello to, and gone on over TLS if the URL says so; and
## logged in, if it has a user.
open! : Smtp.Url => Try(Tcp, Str)
open! = |url| {
	made = if (url.tls == Implicit) Tcp.connect_tls!(url.host, url.port) else Tcp.connect!(url.host, url.port)
	connected =
		match made {
			Ok(connection) => Ok(connection)
			Err(TcpErr(why)) => Err(why)
		}
	tcp = connected?
	_ = expect_reply!(tcp, 220)?
	features = hello!(tcp)?
	offered = features.any(|line| line.with_ascii_uppercased().starts_with("STARTTLS"))
	secured =
		if url.tls == Required and !offered {
			Err("the server doesn't offer STARTTLS, and the URL requires it (a URL with a user does, unless it says ?tls=never)")
		} else if url.tls == Opportunistic and !offered and !url.user.is_empty() {
			Err("the server doesn't offer STARTTLS, so the password would go in clear: say ?tls=never in SMTP_URL to send it so anyway (a relay on this machine)")
		} else if (url.tls == Required or url.tls == Opportunistic) and offered {
			_ = command!(tcp, "STARTTLS", 220)?
			match tcp.start_tls!(url.host) {
				Ok({}) => hello!(tcp)
				Err(TcpErr(why)) => Err(why)
			}
		} else {
			Ok(features)
		}
	_ = secured?
	if url.user.is_empty() {
		Ok(tcp)
	} else {
		plain = Base64.encode([0].concat(url.user.to_utf8()).append(0).concat(url.password.to_utf8()))
		_ = command!(tcp, "AUTH PLAIN ${plain}", 235)?
		Ok(tcp)
	}
}

deliver! : Tcp, Str, List(Str), Str => Try({}, Str)
deliver! = |tcp, from, to, data| {
	_ = command!(tcp, "MAIL FROM:<${from}>", 250)?
	for each in to {
		_ = command!(tcp, "RCPT TO:<${each}>", 250).map_err(|why| "to ${each}: ${why}")?
	}
	_ = command!(tcp, "DATA", 354)?
	_ = written(tcp.write_utf8!("${stuffed(data)}\r\n.\r\n"))?
	_ = expect_reply!(tcp, 250)?
	quit!(tcp)
}

quit! : Tcp => Try({}, Str)
quit! = |tcp| {
	_ = written(tcp.write_utf8!("QUIT\r\n"))?
	# A server may close at once: its goodbye isn't needed.
	_ = read_reply!(tcp)
	Ok({})
}

## EHLO, and the extensions the server lists.
hello! : Tcp => Try(List(Str), Str)
hello! = |tcp| {
	lines = command!(tcp, "EHLO localhost", 250)?
	Ok(lines.drop_first(1))
}

## Sends a command and reads the reply, which must have `code`: its lines.
command! : Tcp, Str, U64 => Try(List(Str), Str)
command! = |tcp, line, code| {
	_ = written(tcp.write_utf8!("${line}\r\n"))?
	expect_reply!(tcp, code)
}

expect_reply! : Tcp, U64 => Try(List(Str), Str)
expect_reply! = |tcp, code| {
	reply = read_reply!(tcp)?
	if (reply.code == code) Ok(reply.lines) else Err("the server said ${reply.code.to_str()} ${Str.join_with(reply.lines, " ")}")
}

## A reply: its code, and its lines without it (a reply runs on while a line has `-` after the code).
read_reply! : Tcp => Try({ code : U64, lines : List(Str) }, Str)
read_reply! = |tcp| {
	var $lines = []
	var $code = 0
	var $more = Bool.True
	var $failed = Ok({})
	while $more {
		match tcp.read_until!('\n') {
			Ok(bytes) => {
				line = Str.from_utf8_lossy(bytes).trim()
				$code = U64.from_str(Str.from_utf8_lossy(prefix(line.to_utf8(), 3))) ?? 0
				$lines = $lines.append(Str.from_utf8_lossy(line.to_utf8().drop_first(4)))
				$more = line.to_utf8().get(3) == Ok('-')
			}
			Err(EndOfInput) => {
				$failed = Err("the server closed the connection")
				$more = Bool.False
			}
			Err(TcpErr(why)) => {
				$failed = Err(why)
				$more = Bool.False
			}
		}
	}
	match $failed {
		Ok({}) => Ok({ code: $code, lines: $lines })
		Err(why) => Err(why)
	}
}

written : Try({}, [TcpErr(Str)]) -> Try({}, Str)
written = |done|
	match done {
		Ok({}) => Ok({})
		Err(TcpErr(why)) => Err(why)
	}

prefix : List(U8), U64 -> List(U8)
prefix = |bytes, count| {
	var $out = []
	for each in bytes {
		if $out.len() < count {
			$out = $out.append(each)
		} else {
			{}
		}
	}
	$out
}

## A line that begins with a dot gets another, so it can't end the message.
stuffed : Str -> Str
stuffed = |data| Str.join_with(data.split_on("\r\n").map(|line| if (line.starts_with(".")) ".${line}" else line), "\r\n")

## `%XX` as the byte it stands for: a user or a password in a URL.
decoded : Str -> Str
decoded = |text| {
	bytes = text.to_utf8()
	var $out = []
	var $at = 0
	while $at < bytes.len() {
		here = bytes.get($at) ?? 0
		escaped =
			if here == '%' {
				match (hex(bytes.get($at + 1) ?? 0), hex(bytes.get($at + 2) ?? 0)) {
					(Ok(high), Ok(low)) => Ok(high * 16 + low)
					_ => Err(NotEscaped)
				}
			} else {
				Err(NotEscaped)
			}
		match escaped {
			Ok(value) => {
				$out = $out.append(value)
				$at = $at + 3
			}
			Err(_) => {
				$out = $out.append(here)
				$at = $at + 1
			}
		}
	}
	Str.from_utf8_lossy($out)
}

hex : U8 -> Try(U8, [NotHex])
hex = |digit|
	if digit >= '0' and digit <= '9' {
		Ok(digit - '0')
	} else if digit >= 'a' and digit <= 'f' {
		Ok(digit - 'a' + 10)
	} else if digit >= 'A' and digit <= 'F' {
		Ok(digit - 'A' + 10)
	} else {
		Err(NotHex)
	}

expect Smtp.parse("smtp://127.0.0.1:2525") == Ok({ tls: Never, host: "127.0.0.1", port: 2525, user: "", password: "" })
expect Smtp.parse("smtp://u:p@mail.example.com:587") == Ok({ tls: Required, host: "mail.example.com", port: 587, user: "u", password: "p" })
expect Smtp.parse("smtp://u:p@mail.example.com").map_ok(|url| (url.tls, url.port)) == Ok((Required, 25))
expect Smtp.parse("smtp://u:p@127.0.0.1:2525?tls=never").map_ok(|url| url.tls) == Ok(Never)
expect Smtp.parse("smtp://u:p@mail.example.com?tls=opportunistic").map_ok(|url| url.tls) == Ok(Opportunistic)
expect Smtp.parse("smtp://ada%40x:p%3Ass@mail.example.com?tls=required") == Ok({ tls: Required, host: "mail.example.com", port: 587, user: "ada@x", password: "p:ss" })
expect Smtp.parse("smtps://u:p@mail.example.com") == Ok({ tls: Implicit, host: "mail.example.com", port: 465, user: "u", password: "p" })
expect Smtp.parse("http://nope").is_err()
expect stuffed("a\r\n.b\r\n..c") == "a\r\n..b\r\n...c"
