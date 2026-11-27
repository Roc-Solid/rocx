import pf.Env
import pf.Log
import pf.Plugin
import pf.Random
import pf.Time
import crypto.Base64
import jobs.Calendar
import Mailbox
import Smtp

## Email, for Roc Solid's server. With an SMTP server (`SMTP_URL`:
## `smtp://user:password@host:587?tls=required`, or `smtps://…:465` for TLS from the start) it
## sends it, from `MAIL_FROM`, over SMTP (`Smtp`, on the platform's `Tcp`). Without one, under
## `--dev` (or `--debug`, the tests') it keeps it in the server's memory (`Kv`) and logs it: the dev
## mailbox (`Mailbox`, `/__rocx/mail` under `--dev`) shows it, so development sends nothing. Anywhere
## else that is a mistake that would lose mail: the plugin's server doesn't start, and `send!` fails
## (D-079). Send from a job (packages/jobs), so a server that doesn't answer is tried again.
##
## ```roc
## plugins: [Email.plugin({})]                                   # SMTP_URL and MAIL_FROM, from the environment
## plugins: [Email.plugin({ from: "Acme <hello@example.com>" })] # unless MAIL_FROM says otherwise
##
## Email.send!({ to: "ada@example.com", subject: "Welcome", text: "…" })
## Email.send!({ to: "Ada <ada@example.com>, grace@example.com", cc: ["lin@example.com"], subject: "Minutes", text: "…", html: "<p>…</p>", reply_to: "team@example.com" })
## ```
Email := [].{

	## A message: whom it is for, its subject, its text, and the rest when it has them.
	##
	## - `to`: one address or several, separated by commas (RFC 5322's address list:
	##   `Ada Lovelace <ada@example.com>, grace@example.com`; a comma inside a quoted name,
	##   `"Lovelace, Ada" <ada@example.com>`, is the name's). At least one.
	## - `html`: the same as HTML, or "" for text alone.
	## - `cc`: more who see it, in a `Cc` header; each item is one address or several, as `to`.
	## - `bcc`: more who get it, written as `cc`, and named in no header: only the SMTP server is
	##   told of them (`RCPT TO`), so nobody who gets it sees them.
	## - `reply_to`: where a reply goes, in a `Reply-To` header, one address or several; "" for none
	##   (a reply goes to who it is from).
	## - `headers`: headers of the app's own, `("List-Unsubscribe", "<https://example.com/unsubscribe?t=…>")`
	##   say, written as given (a value that isn't printable ASCII as an encoded word). A CR or LF in
	##   a name or a value (which would start a header of its own), a name that isn't printable
	##   ASCII with no space or colon, a header the package writes itself (`From`, `To`, `Cc`,
	##   `Bcc`, `Reply-To`, `Subject`, `Date`, `Message-ID`, `MIME-Version`, `Content-*`), and one
	##   longer than SMTP's 998-byte line are refused.
	##
	## Only `to`, `subject` and `text` must be given, so `{ to, subject, text, html }` is a message.
	Message := { to : Str, subject : Str, text : Str, html : Str ?? "", cc : List(Str) ?? [], bcc : List(Str) ?? [], reply_to : Str ?? "", headers : List((Str, Str)) ?? [] }

	## Who email is from (`MAIL_FROM` when it is set, so a deploy says it; else `from`; else
	## `rocx <rocx@localhost>`), and where it
	## goes: the SMTP server's URL, which `smtp_url!` finds when the server starts (`SMTP_URL`, from
	## the environment, unless the app gives a function of its own: a secret it keeps elsewhere); ""
	## for none, which only `--dev` and `--debug` allow: mail is kept for the dev mailbox.
	Options := { from : Str ?? "", smtp_url! : ({} => Str) ?? smtp_url_from_env! }

	## The email plugin: the dev mailbox's pages, before the app and only under `--dev` (its JSON
	## under `--debug` too: `/__rocx/mail`, `/__rocx/mail.json`, `/__rocx/mail/<id>`), a look at the
	## SMTP server once the server has started (`email.smtp`: whether it answers, on the log), and
	## its options kept for `send!`. Its start refuses a server with no SMTP server outside `--dev`
	## and `--debug`, saying `SMTP_URL` is missing, rather than one that would lose every email.
	plugin : Options -> Plugin.Value(context, ctx)
	plugin = |options| {
		from = options.from
		smtp_url! = options.smtp_url!
		{
			name: "email",
			early: Mailbox.early,
			# Under --dev, where the mail kept for the dev mailbox is read (D-111).
			links: [{ label: "Mailbox", path: "/__rocx/mail" }],
			starts: [|_context| keep!(from, smtp_url!)],
			checks: [{ name: "email.smtp", run!: |_context| check!({}) }],
		}
	}

	## Sends `message`: over SMTP when there is an SMTP server, to everyone in `to`, `cc` and `bcc`
	## (each address once); without, under `--dev` or `--debug`, kept for the dev mailbox and logged.
	## `EmailErr` if there is no SMTP server anywhere else (it says `SMTP_URL` is missing), if an
	## address can't be read or `to` has none, if a header is refused (`Message` says which), or if
	## the SMTP server refuses it (a recipient, say: then nobody gets it) or can't be reached.
	## Without the plugin in the app's list, it reads `SMTP_URL` and `MAIL_FROM` itself.
	send! : Message => Try({}, [EmailErr(Str)])
	send! = |message| {
		settings = settings!({})
		from_text = settings.from
		match read(from_text, message) {
			Err(why) => Err(EmailErr(why))
			Ok(envelope) => {
				now = Time.now_millis!({}).to_i64_wrap()
				data = compose(envelope, message, now, Random.seed_u64!() ?? 0)
				if settings.smtp_url.is_empty() {
					match unsent(Env.dev!({}) or Env.debug!({})) {
						Ok({}) => {
							Log.info!("email: kept, not sent (no SMTP_URL)", { to: message.to, subject: message.subject })
							Mailbox.keep!({
								at: now,
								from: from_text,
								to: message.to,
								cc: message.cc,
								bcc: message.bcc,
								reply_to: message.reply_to,
								headers: message.headers.map(|(name, value)| { name: name, value: value }),
								subject: message.subject,
								text: message.text,
								html: message.html,
								raw: data,
							})
							Ok({})
						}
						Err(why) => Err(EmailErr("email to ${message.to}: ${why}"))
					}
				} else {
					sent =
						match Smtp.parse(settings.smtp_url) {
							Ok(url) => Smtp.send!(url, envelope.from.address, recipients(envelope), data)
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
}

## `SMTP_URL`, from the environment; "" when it isn't set.
smtp_url_from_env! : {} => Str
smtp_url_from_env! = |{}| Env.var!("SMTP_URL") ?? ""

## Who email is from, and where it goes, as the plugin kept them when the server started; read from
## the environment when there is no plugin.
Settings : { from : Str, smtp_url : Str }

settings! : {} => Settings
settings! = |{}|
	match Plugin.kept!("email:settings") {
		Ok(kept) =>
			match Json.parse(kept) {
				Ok(found) => found
				Err(InvalidJson(_)) => { from: sender!(""), smtp_url: smtp_url_from_env!({}) }
			}
		Err(NotFound) => { from: sender!(""), smtp_url: smtp_url_from_env!({}) }
	}

## The plugin's start: its options, kept for `send!`; an `Err` (`no_smtp`), which stops the server,
## when there is no SMTP server outside `--dev` and `--debug`.
keep! : Str, ({} => Str) => Try({}, Str)
keep! = |from, smtp_url!| {
	found : Settings
	found = { from: sender!(from), smtp_url: smtp_url!({}) }
	if found.smtp_url.is_empty() and !(Env.dev!({}) or Env.debug!({})) {
		return Err(no_smtp)
	}
	Plugin.keep!("email:settings", Json.to_str(found))
	Ok({})
}

## What becomes of email with no SMTP server (D-079): kept for the dev mailbox where there is one to
## read it (`--dev`, or `--debug` for the tests); anywhere else an error saying what is missing, since
## the mail would be lost.
unsent : Bool -> Try({}, Str)
unsent = |kept_here| if (kept_here) Ok({}) else Err(no_smtp)

## Why email can't go out.
no_smtp : Str
no_smtp = "SMTP_URL isn't set, so email can't be sent: set it where the server runs (smtps://user:password@smtp.example.com), or give Email.plugin an smtp_url!. Only --dev keeps email unsent, for the dev mailbox"

## Whether the SMTP server answers (its greeting, TLS, a goodbye), said on the log once the server
## has started: a wrong `SMTP_URL` shows then, not at the first email. Nothing without one.
check! : {} => Try(Str, Str)
check! = |{}| {
	smtp_url = settings!({}).smtp_url
	if smtp_url.is_empty() {
		Ok("")
	} else {
		match Smtp.parse(smtp_url) {
			Err(why) => Err(why)
			Ok(url) =>
				match Smtp.check!(url) {
					Ok({}) => Ok("the SMTP server answers")
					Err(why) => Err("can't reach the SMTP server: ${why}")
				}
		}
	}
}

## Who email is from: `MAIL_FROM` when it is set (a deploy's say), or else `given`, or else
## `rocx <rocx@localhost>`.
sender! : Str => Str
sender! = |given|
	match Env.var!("MAIL_FROM") {
		Ok(from) if !from.trim().is_empty() => from.trim()
		_ => if (given.is_empty()) "rocx <rocx@localhost>" else given
	}

## An address as written, `Ada Lovelace <ada@example.com>` or `ada@example.com`: its name (perhaps
## none) and the address.
Addressee : { name : Str, address : Str }

mailbox : Str -> Try(Addressee, Str)
mailbox = |text| {
	written = text.trim()
	(name, address) =
		match written.split_last("<") {
			Ok({ before, after }) if after.ends_with(">") => (unquoted(before.trim()), after.drop_suffix(">").trim())
			_ => ("", written)
		}
	if (is_address(address)) Ok({ name, address }) else Err("not an email address")
}

## The addresses in `text`: one, or several separated by commas (RFC 5322's address list). A comma
## inside a quoted name (`"Lovelace, Ada" <ada@example.com>`) is the name's; an empty place between
## two commas is nothing. None for "". `Err` names the first that can't be read, and why.
addresses : Str -> Try(List(Addressee), Str)
addresses = |text| {
	var $found = []
	var $failed = ""
	for each in listed(text) {
		item = each.trim()
		if item.is_empty() or !$failed.is_empty() {
			{}
		} else {
			match mailbox(item) {
				Ok(box) => {
					$found = $found.append(box)
				}
				Err(why) => {
					$failed = "${item}: ${why}"
				}
			}
		}
	}
	if ($failed.is_empty()) Ok($found) else Err($failed)
}

## `text` cut at each comma that isn't inside a quoted string (`"…"`, in which `\` takes the byte
## after it as it is).
listed : Str -> List(Str)
listed = |text| {
	var $parts = []
	var $current = []
	var $quoted = Bool.False
	var $escaped = Bool.False
	for byte in text.to_utf8() {
		if $escaped {
			$escaped = Bool.False
			$current = $current.append(byte)
		} else if $quoted and byte == '\\' {
			$escaped = Bool.True
			$current = $current.append(byte)
		} else if byte == '"' {
			$quoted = !$quoted
			$current = $current.append(byte)
		} else if byte == ',' and !$quoted {
			$parts = $parts.append(Str.from_utf8_lossy($current))
			$current = []
		} else {
			$current = $current.append(byte)
		}
	}
	$parts.append(Str.from_utf8_lossy($current))
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

## A name as written, without the quotes around it, if it has them, and with what `\` escapes in
## them as it is (`"Ada \"The\" L"` is `Ada "The" L`).
unquoted : Str -> Str
unquoted = |name| {
	bytes = name.to_utf8()
	if name.starts_with("\"") and name.ends_with("\"") and bytes.len() >= 2 {
		var $out = []
		var $escaped = Bool.False
		for byte in bytes.drop_first(1).drop_last(1) {
			if $escaped {
				$escaped = Bool.False
				$out = $out.append(byte)
			} else if byte == '\\' {
				$escaped = Bool.True
			} else {
				$out = $out.append(byte)
			}
		}
		Str.from_utf8_lossy($out)
	} else {
		name
	}
}

## A mailbox as a header has it: `"Ada Lovelace" <ada@example.com>`, or the bare address. A name
## that isn't printable ASCII (`Zażółć`, or one with a CR or LF in it, which would start a header
## of its own) is an encoded word (RFC 2047), as the subject is, so nothing in it ends the line.
header_mailbox : Addressee -> Str
header_mailbox = |box|
	if box.name.is_empty() {
		box.address
	} else if box.name.to_utf8().all(|byte| byte >= ' ' and byte < 127) {
		"\"${box.name.replace_each("\\", "\\\\").replace_each("\"", "\\\"")}\" <${box.address}>"
	} else {
		"${encoded_header(box.name)} <${box.address}>"
	}

## A header of addresses, `To: ada@example.com, "Grace H" <grace@example.com>`, folded (a line
## break, and the next line starting with a space) before an address that would take its line past
## 78 bytes, so a long list never passes SMTP's 998.
address_header : Str, List(Addressee) -> Str
address_header = |name, boxes| {
	last = boxes.len()
	var $lines = []
	var $line = "${name}:"
	var $at = 0
	for box in boxes {
		$at = $at + 1
		piece = if ($at < last) "${header_mailbox(box)}," else header_mailbox(box)
		if $at > 1 and $line.to_utf8().len() + 1 + piece.to_utf8().len() > 78 {
			$lines = $lines.append($line)
			$line = " ${piece}"
		} else {
			$line = "${$line} ${piece}"
		}
	}
	Str.join_with($lines.append($line), "\r\n")
}

## A message's addresses, read, and the app's headers, checked: what `compose` writes, and whom
## SMTP is told to deliver to.
Envelope : { from : Addressee, to : List(Addressee), cc : List(Addressee), bcc : List(Addressee), reply_to : List(Addressee), headers : List((Str, Str)) }

## Reads `from` (who mail is from) and `message`'s addresses, and checks its headers: an `Err` says
## which field (and which address or header) is wrong, and why.
read : Str, Email.Message -> Try(Envelope, Str)
read = |from_text, message| {
	from = mailbox(from_text).map_err(|why| "from ${from_text}: ${why}")?
	to = addresses(message.to).map_err(|why| "to ${why}")?
	cc = all_addresses(message.cc).map_err(|why| "cc ${why}")?
	bcc = all_addresses(message.bcc).map_err(|why| "bcc ${why}")?
	reply_to = addresses(message.reply_to).map_err(|why| "reply_to ${why}")?
	headers = checked(message.headers)?
	if to.is_empty() {
		Err("to: no address in it (a message needs someone to go to)")
	} else {
		Ok({ from, to, cc, bcc, reply_to, headers })
	}
}

## The addresses of every item of `list`, each one or several (`addresses`).
all_addresses : List(Str) -> Try(List(Addressee), Str)
all_addresses = |list| {
	var $found = []
	var $failed = ""
	for each in list {
		if $failed.is_empty() {
			match addresses(each) {
				Ok(boxes) => {
					$found = $found.concat(boxes)
				}
				Err(why) => {
					$failed = why
				}
			}
		} else {
			{}
		}
	}
	if ($failed.is_empty()) Ok($found) else Err($failed)
}

## Whom the SMTP server is told to deliver to: everyone in `to`, `cc` and `bcc`, each address once.
recipients : Envelope -> List(Str)
recipients = |envelope| {
	var $out = []
	for box in envelope.to.concat(envelope.cc).concat(envelope.bcc) {
		if $out.contains(box.address) {
			{}
		} else {
			$out = $out.append(box.address)
		}
	}
	$out
}

## The app's headers, each as `header_problem` lets it through.
checked : List((Str, Str)) -> Try(List((Str, Str)), Str)
checked = |headers| {
	var $failed = ""
	for (name, value) in headers {
		if $failed.is_empty() {
			match header_problem(name, value) {
				Ok({}) => {}
				Err(why) => {
					$failed = why
				}
			}
		} else {
			{}
		}
	}
	if ($failed.is_empty()) Ok(headers) else Err($failed)
}

## Whether a header of the app's can be written: its name printable ASCII with no space or colon,
## not one the package writes itself, no CR or LF in it or in its value, which would end the line
## and start a header of the value's own (a `Bcc`, say), and the line no longer than SMTP's 998
## bytes.
header_problem : Str, Str -> Try({}, Str)
header_problem = |name, value| {
	shown = encoded_header(name)
	if name.is_empty() or !name.to_utf8().all(|byte| byte > ' ' and byte < 127 and byte != ':') {
		Err("header ${shown}: a header's name is printable ASCII, with no space or colon")
	} else if value.to_utf8().any(|byte| byte == '\r' or byte == '\n') {
		Err("header ${name}: a CR or LF in its value would start a header of its own")
	} else if written_itself(name) {
		Err("header ${name}: the package writes it itself (From, To, Cc, Bcc, Reply-To, Subject, Date, Message-ID, MIME-Version, Content-*): give the message's field instead")
	} else if "${name}: ${encoded_header(value)}".to_utf8().len() > 998 {
		Err("header ${name}: longer than SMTP lets a line be (998 bytes)")
	} else {
		Ok({})
	}
}

## Whether the package writes the header `name` itself (or, for Bcc, never writes it), in any case.
written_itself : Str -> Bool
written_itself = |name| {
	lower = name.with_ascii_lowercased()
	["from", "to", "cc", "bcc", "reply-to", "subject", "date", "message-id", "mime-version"].contains(lower) or lower.starts_with("content-")
}

## The message as SMTP's DATA carries it: headers, then the text alone (`text/plain`), or the text
## and the HTML (`multipart/alternative`); lines ending in CRLF. No header names the Bcc addresses.
compose : Envelope, Email.Message, I64, U64 -> Str
compose = |envelope, message, now, random| {
	id = "${hex(random)}.${hex(now.to_u64_wrap())}"
	cc = if (envelope.cc.is_empty()) [] else [address_header("Cc", envelope.cc)]
	reply_to = if (envelope.reply_to.is_empty()) [] else [address_header("Reply-To", envelope.reply_to)]
	headers =
		["Date: ${rfc5322(now)}", address_header("From", [envelope.from]), address_header("To", envelope.to)]
			.concat(cc)
			.concat(reply_to)
			.concat(["Subject: ${encoded_header(message.subject)}", "Message-ID: <${id}@rocx>", "MIME-Version: 1.0"])
			.concat(envelope.headers.map(|(name, value)| "${name}: ${encoded_header(value)}"))
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

## A moment (milliseconds since the epoch) as email has it: `Fri, 20 Nov 2026 21:54:07 +0000`.
rfc5322 : I64 -> Str
rfc5322 = |ms| {
	seconds = ms // 1000
	days = seconds // 86400
	of_day = seconds % 86400
	date = Calendar.civil(days)
	weekday_name = named(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], Calendar.weekday(days))
	month_name = named(["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], date.month - 1)
	"${weekday_name}, ${date.day.to_str()} ${month_name} ${date.year.to_str()} ${two(of_day // 3600)}:${two(of_day % 3600 // 60)}:${two(of_day % 60)} +0000"
}

named : List(Str), I64 -> Str
named = |all, index|
	match all.get(index.to_u64_wrap()) {
		Ok(name) => name
		Err(_) => "?"
	}

two : I64 -> Str
two = |n| if (n < 10) "0${n.to_str()}" else n.to_str()

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

expect unsent(Bool.True) == Ok({}) and unsent(Bool.False) == Err(no_smtp)
expect no_smtp.starts_with("SMTP_URL isn't set")
expect mailbox("Rocx Tests <tests@rocx.example>") == Ok({ name: "Rocx Tests", address: "tests@rocx.example" })
expect mailbox("\"Ada L\" <ada@example.com>") == Ok({ name: "Ada L", address: "ada@example.com" })
expect mailbox("grace@example.com") == Ok({ name: "", address: "grace@example.com" })
expect mailbox("rocx <rocx@localhost>") == Ok({ name: "rocx", address: "rocx@localhost" })
expect mailbox("not-an-address").is_err()
expect mailbox("a b@example.com").is_err()
expect header_mailbox({ name: "Rocx Tests", address: "tests@rocx.example" }) == "\"Rocx Tests\" <tests@rocx.example>"
expect header_mailbox({ name: "Zażółć", address: "z@example.com" }) == "=?utf-8?b?WmHFvMOzxYLEhw==?= <z@example.com>"
expect !header_mailbox({ name: "Ada\r\nBcc: everyone@example.com", address: "ada@example.com" }).contains("\n")
expect {
	# A name or a subject someone typed can't add a header.
	sent = read("a@x.example", { to: "Ada\r\nBcc: everyone@example.com <ada@example.com>", subject: "Hi\r\nBcc: them@example.com", text: "one" }).map_ok(|envelope| compose(envelope, { to: "", subject: "Hi\r\nBcc: them@example.com", text: "one" }, 1795211647000, 1))
	match sent {
		Ok(data) => !data.contains("\r\nBcc:")
		Err(_) => Bool.False
	}
}
expect encoded_header("Hello") == "Hello"
expect encoded_header("Zażółć") == "=?utf-8?b?WmHFvMOzxYLEhw==?="
expect hex(255) == "ff"
expect hex(0) == "0"
expect {
	sent = read("a@x.example", { to: "b@x.example", subject: "Hi", text: "one\ntwo" }).map_ok(|envelope| compose(envelope, { to: "b@x.example", subject: "Hi", text: "one\ntwo" }, 1795211647000, 1))
	match sent {
		Ok(data) =>
			data.contains("\r\nTo: b@x.example\r\nSubject: Hi\r\n")
				and data.contains("Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 7bit\r\n\r\none\r\ntwo")
				and !data.contains("Cc:")
				and !data.contains("Reply-To:")
		Err(_) => Bool.False
	}
}

# Several recipients, in `to` and in `cc` (an item may hold several), Bcc, Reply-To and a header.
everyone : Email.Message
everyone = {
	to: "Ada <ada@example.com>, \"Lovelace, Grace\" <grace@example.com>",
	cc: ["lin@example.com", "Max M <max@example.com>, ada@example.com"],
	bcc: ["secret@example.com"],
	reply_to: "Help <help@example.com>",
	headers: [("List-Unsubscribe", "<https://example.com/unsubscribe?t=1>"), ("X-Note", "Zażółć")],
	subject: "Minutes",
	text: "one",
}

expect {
	match read("a@x.example", everyone) {
		Ok(envelope) => {
			data = compose(envelope, everyone, 1795211647000, 1)
			recipients(envelope) == ["ada@example.com", "grace@example.com", "lin@example.com", "max@example.com", "secret@example.com"]
				and data.contains("\r\nTo: \"Ada\" <ada@example.com>, \"Lovelace, Grace\" <grace@example.com>\r\n")
				and data.contains("\r\nCc: lin@example.com, \"Max M\" <max@example.com>, ada@example.com\r\n")
				and data.contains("\r\nReply-To: \"Help\" <help@example.com>\r\n")
				and data.contains("\r\nList-Unsubscribe: <https://example.com/unsubscribe?t=1>\r\n")
				and data.contains("\r\nX-Note: =?utf-8?b?WmHFvMOzxYLEhw==?=\r\n")
				and !data.contains("Bcc")
				and !data.contains("secret@")
		}
		Err(_) => Bool.False
	}
}

expect addresses("Ada <ada@example.com>, \"Lovelace, Grace\" <grace@example.com>,lin@example.com") == Ok([{ name: "Ada", address: "ada@example.com" }, { name: "Lovelace, Grace", address: "grace@example.com" }, { name: "", address: "lin@example.com" }])
expect addresses("") == Ok([])
expect addresses(" a@example.com, , b@example.com, ") == Ok([{ name: "", address: "a@example.com" }, { name: "", address: "b@example.com" }])
expect addresses("a@example.com, Lovelace, Ada <ada@example.com>") == Err("Lovelace: not an email address")
expect mailbox("\"Lovelace, Ada\" <ada@example.com>") == Ok({ name: "Lovelace, Ada", address: "ada@example.com" })
expect mailbox("\"Ada \\\"The\\\" L\" <ada@example.com>") == Ok({ name: "Ada \"The\" L", address: "ada@example.com" })
expect mailbox("\"a <b\" <x@example.com>") == Ok({ name: "a <b", address: "x@example.com" })
expect header_mailbox({ name: "Ada \"The\" L", address: "ada@example.com" }) == "\"Ada \\\"The\\\" L\" <ada@example.com>"
expect read("a@x.example", { to: "", subject: "Hi", text: "" }) == Err("to: no address in it (a message needs someone to go to)")
expect read("a@x.example", { to: " , ", bcc: ["b@x.example"], subject: "Hi", text: "" }).is_err()
expect read("a@x.example", { to: "b@x.example", cc: ["nope"], subject: "Hi", text: "" }) == Err("cc nope: not an email address")
expect read("a@x.example", { to: "b@x.example", reply_to: "nope", subject: "Hi", text: "" }) == Err("reply_to nope: not an email address")
expect read("a@x.example", { to: "b@x.example", headers: [("Subject", "x")], subject: "Hi", text: "" }).is_err()
expect header_problem("List-Unsubscribe", "<https://example.com/u>") == Ok({})
expect header_problem("X-Note", "a\r\nBcc: them@example.com").is_err()
expect header_problem("X-Note", "a\nb").is_err()
expect header_problem("X-Bad\r\nBcc", "x").is_err()
expect header_problem("Bad Name", "x").is_err()
expect header_problem("Bad:Name", "x").is_err()
expect header_problem("", "x").is_err()
expect header_problem("content-type", "text/html").is_err()
expect header_problem("BCC", "x").is_err()
expect header_problem("Reply-To", "x").is_err()
expect header_problem("Message-ID", "<x@y>").is_err()
expect header_problem("X-Long", Str.repeat("a", 991)) == Err("header X-Long: longer than SMTP lets a line be (998 bytes)")
expect header_problem("X-Long", Str.repeat("a", 990)) == Ok({})
expect {
	# A long list is folded: no line past 78 bytes, each after the first starting with a space.
	boxes = List.repeat({ name: "Someone Long Named", address: "someone.long.named@example.com" }, 5)
	lines = address_header("To", boxes).split_on("\r\n")
	lines.len() == 5 and lines.all(|line| line.to_utf8().len() <= 78) and lines.drop_first(1).all(|line| line.starts_with(" \"Someone"))
}
expect address_header("To", [{ name: "", address: "a@x.example" }, { name: "", address: "b@x.example" }]) == "To: a@x.example, b@x.example"
expect rfc5322(1795211647000) == "Fri, 20 Nov 2026 21:54:07 +0000"
