import Base64
import Calendar
import Host
import Log
import Outbox
import Setting
import Smtp
import Time

## Email. With `--smtp-url` (`smtp://user:password@host:587?tls=required`, or `smtps://…:465`
## for TLS from the start) the server sends it, from `--mail-from`, over SMTP (`Smtp`, on `Tcp`);
## without, it keeps it in an outbox (in the server's memory, `Kv`) and logs it: the dev
## mailbox (`Outbox`, `/__rocx/mail` with `--dev`) shows it, so development sends nothing. Send
## from a job (`Job`), so a server that doesn't answer is tried again.
Email := [].{

	## A message: `html` may be empty, for text alone.
	Message : { to : Str, subject : Str, text : Str, html : Str }

	## Sends `message` from `--mail-from`: over SMTP with `--smtp-url`; without, kept in the outbox
	## and logged. `EmailErr` if an address can't be read, the SMTP server refuses it or can't be
	## reached, or the outbox can't keep it.
	send! : Message => Try({}, [EmailErr(Str)])
	send! = |message| {
		from_text = sender!({})
		match (mailbox(from_text), mailbox(message.to)) {
			(Err(why), _) => Err(EmailErr("from ${from_text}: ${why}"))
			(_, Err(why)) => Err(EmailErr("to ${message.to}: ${why}"))
			(Ok(from), Ok(to)) => {
				smtp_url = Setting.text!("smtp-url")
				now = Time.now_millis!({}).to_i64_wrap()
				data = compose(from, to, message, now, Host.random_u64!({}))
				if smtp_url.is_empty() {
					Log.line!("rocx mail (kept, not sent: no --smtp-url): to ${message.to}: ${message.subject}")
					match Outbox.keep!({ at: now, from: from_text, to: message.to, subject: message.subject, text: message.text, html: message.html, raw: data }) {
						Ok({}) => Ok({})
						Err(why) => Err(EmailErr("email to ${message.to}: ${why}"))
					}
				} else {
					sent =
						match Smtp.parse(smtp_url) {
							Ok(url) => Smtp.send!(url, from.address, to.address, data)
							Err(why) => Err(why)
						}
					match sent {
						Ok({}) => Ok({})
						Err(why) => Err(EmailErr("email to ${message.to}: ${why}"))
					}
				}
			}
		}
	}

	## Says on the log whether the SMTP server answers (its greeting, TLS, a goodbye): a wrong
	## `--smtp-url` shows when the server starts, not at the first email.
	check! : {} => {}
	check! = |{}|
		match Smtp.parse(Setting.text!("smtp-url")) {
			Err(why) => Log.line!("rocx mail: ${why}")
			Ok(url) =>
				match Smtp.check!(url) {
					Ok({}) => Log.line!("rocx mail: the SMTP server answers")
					Err(why) => Log.line!("rocx mail: can't reach the SMTP server: ${why}")
				}
		}
}

sender! : {} => Str
sender! = |{}| {
	given = Setting.text!("mail-from")
	if (given.is_empty()) "rocx <rocx@localhost>" else given
}

## An address as written, `Ada Lovelace <ada@example.com>` or `ada@example.com`: its name (perhaps
## none) and the address.
Mailbox : { name : Str, address : Str }

mailbox : Str -> Try(Mailbox, Str)
mailbox = |text| {
	written = text.trim()
	(name, address) =
		match written.split_first("<") {
			Ok({ before, after }) if after.ends_with(">") => (unquoted(before.trim()), after.drop_suffix(">").trim())
			_ => ("", written)
		}
	if (is_address(address)) Ok({ name, address }) else Err("not an email address")
}

is_address : Str -> Bool
is_address = |address|
	match address.split_first("@") {
		Ok({ before, after }) =>
			!before.is_empty()
				and (after.contains(".") or after == "localhost")
				and !after.contains("@")
				and !address.to_utf8().any(|byte| byte <= ' ' or byte == '<' or byte == '>' or byte == ',' or byte == ';' or byte == '"')
		Err(_) => Bool.False
	}

unquoted : Str -> Str
unquoted = |name| if (name.starts_with("\"") and name.ends_with("\"") and name.to_utf8().len() >= 2) name.drop_prefix("\"").drop_suffix("\"") else name

## A mailbox as a header has it: `"Ada Lovelace" <ada@example.com>`, or the bare address.
header_mailbox : Mailbox -> Str
header_mailbox = |box|
	if box.name.is_empty() {
		box.address
	} else {
		"\"${box.name.replace_each("\\", "\\\\").replace_each("\"", "\\\"")}\" <${box.address}>"
	}

## The message as SMTP's DATA carries it: headers, then the text alone (`text/plain`), or the text
## and the HTML (`multipart/alternative`); lines ending in CRLF.
compose : Mailbox, Mailbox, Email.Message, I64, U64 -> Str
compose = |from, to, message, now, random| {
	id = "${hex(random)}.${hex(now.to_u64_wrap())}"
	headers = [
		"Date: ${Calendar.rfc5322(now)}",
		"From: ${header_mailbox(from)}",
		"To: ${header_mailbox(to)}",
		"Subject: ${encoded_header(message.subject)}",
		"Message-ID: <${id}@rocx>",
		"MIME-Version: 1.0",
	]
	lines =
		if message.html.is_empty() {
			headers.concat(part("text/plain", message.text))
		} else {
			boundary = "rocx-${id}"
			headers
				.append("Content-Type: multipart/alternative; boundary=\"${boundary}\"")
				.append("")
				.append("--${boundary}")
				.concat(part("text/plain", message.text))
				.append("--${boundary}")
				.concat(part("text/html", message.html))
				.append("--${boundary}--")
		}
	Str.join_with(lines, "\r\n")
}

## A body's headers, a blank line, and the body: as it is when it is short-lined ASCII (7bit), in
## base64 otherwise.
part : Str, Str -> List(Str)
part = |kind, body| {
	lined = Str.join_with(body.replace_each("\r\n", "\n").split_on("\n"), "\r\n")
	plain = lined.to_utf8().all(|byte| byte < 128) and lined.split_on("\r\n").all(|line| line.to_utf8().len() <= 998)
	if plain {
		["Content-Type: ${kind}; charset=utf-8", "Content-Transfer-Encoding: 7bit", "", lined]
	} else {
		["Content-Type: ${kind}; charset=utf-8", "Content-Transfer-Encoding: base64", "", Base64.lines(body.to_utf8())]
	}
}

## A header's text as it is when it is printable ASCII; RFC 2047's encoded word otherwise.
encoded_header : Str -> Str
encoded_header = |text|
	if (text.to_utf8().all(|byte| byte >= ' ' and byte < 127)) text else "=?utf-8?b?${Base64.encode(text.to_utf8())}?="

hex : U64 -> Str
hex = |number| {
	digits = "0123456789abcdef".to_utf8()
	var $out = []
	var $left = number
	while $left > 0 or $out.is_empty() {
		$out = $out.prepend(digits.get($left % 16) ?? '0')
		$left = $left // 16
	}
	Str.from_utf8_lossy($out)
}

expect mailbox("Rocx Tests <tests@rocx.example>") == Ok({ name: "Rocx Tests", address: "tests@rocx.example" })
expect mailbox("\"Ada L\" <ada@example.com>") == Ok({ name: "Ada L", address: "ada@example.com" })
expect mailbox("grace@example.com") == Ok({ name: "", address: "grace@example.com" })
expect mailbox("rocx <rocx@localhost>") == Ok({ name: "rocx", address: "rocx@localhost" })
expect mailbox("not-an-address").is_err()
expect mailbox("a b@example.com").is_err()
expect header_mailbox({ name: "Rocx Tests", address: "tests@rocx.example" }) == "\"Rocx Tests\" <tests@rocx.example>"
expect encoded_header("Hello") == "Hello"
expect encoded_header("Zażółć") == "=?utf-8?b?WmHFvMOzxYLEhw==?="
expect hex(255) == "ff"
expect hex(0) == "0"
expect {
	data = compose({ name: "", address: "a@x.example" }, { name: "", address: "b@x.example" }, { to: "b@x.example", subject: "Hi", text: "one\ntwo", html: "" }, 1795211647000, 1)
	data.contains("\r\nSubject: Hi\r\n") and data.contains("Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 7bit\r\n\r\none\r\ntwo")
}
