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
## sends it, from `MAIL_FROM`, over SMTP (`Smtp`, on the platform's `Tcp`); without, it keeps it in
## the server's memory (`Kv`) and logs it: the dev mailbox (`Mailbox`, `/__rocx/mail` under `--dev`)
## shows it, so development sends nothing. Send from a job (packages/jobs), so a server that doesn't
## answer is tried again.
##
## ```roc
## plugins: [Email.plugin({})]                                   # SMTP_URL and MAIL_FROM, from the environment
## plugins: [Email.plugin({ from: "Acme <hello@example.com>" })] # MAIL_FROM said here
##
## Email.send!({ to: "ada@example.com", subject: "Welcome", text: "…", html: "" })
## ```
Email := [].{

	## A message: `html` may be empty, for text alone.
	Message : { to : Str, subject : Str, text : Str, html : Str }

	## Who email is from (`from`; "" for `MAIL_FROM`, or else `rocx <rocx@localhost>`), and where it
	## goes: the SMTP server's URL, which `smtp_url!` finds when the server starts (`SMTP_URL`, from
	## the environment, unless the app gives a function of its own: a secret it keeps elsewhere); ""
	## for none, and mail is kept for the dev mailbox.
	Options := { from : Str ?? "", smtp_url! : ({} => Str) ?? smtp_url_from_env! }

	## The email plugin: the dev mailbox's pages, before the app and only under `--dev` (its JSON
	## under `--debug` too: `/__rocx/mail`, `/__rocx/mail.json`, `/__rocx/mail/<id>`), a look at the
	## SMTP server once the server has started (`email.smtp`: whether it answers, on the log), and
	## its options kept for `send!`.
	plugin : Options -> Plugin.Value(ctx)
	plugin = |options| {
		from = options.from
		smtp_url! = options.smtp_url!
		{
			name: "email",
			early: Mailbox.early,
			starts: [|{}| keep!(from, smtp_url!)],
			checks: [{ name: "email.smtp", run!: |{}| check!({}) }],
		}
	}

	## Sends `message`: over SMTP when there is an SMTP server; without, kept for the dev mailbox
	## and logged. `EmailErr` if an address can't be read, the SMTP server refuses it or can't be
	## reached. Without the plugin in the app's list, it reads `SMTP_URL` and `MAIL_FROM` itself.
	send! : Message => Try({}, [EmailErr(Str)])
	send! = |message| {
		settings = settings!({})
		from_text = settings.from
		match (mailbox(from_text), mailbox(message.to)) {
			(Err(why), _) => Err(EmailErr("from ${from_text}: ${why}"))
			(_, Err(why)) => Err(EmailErr("to ${message.to}: ${why}"))
			(Ok(from), Ok(to)) => {
				now = Time.now_millis!({}).to_i64_wrap()
				data = compose(from, to, message, now, Random.seed_u64!() ?? 0)
				if settings.smtp_url.is_empty() {
					Log.info!("email: kept, not sent (no SMTP_URL)", { to: message.to, subject: message.subject })
					Mailbox.keep!({ at: now, from: from_text, to: message.to, subject: message.subject, text: message.text, html: message.html, raw: data })
					Ok({})
				} else {
					sent =
						match Smtp.parse(settings.smtp_url) {
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

## The plugin's start: its options, kept for `send!`.
keep! : Str, ({} => Str) => Try({}, Str)
keep! = |from, smtp_url!| {
	found : Settings
	found = { from: sender!(from), smtp_url: smtp_url!({}) }
	Plugin.keep!("email:settings", Json.to_str(found))
	Ok({})
}

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

## Who email is from: `given`, or else `MAIL_FROM`, or else `rocx <rocx@localhost>`.
sender! : Str => Str
sender! = |given|
	if !given.is_empty() {
		given
	} else {
		match Env.var!("MAIL_FROM") {
			Ok(from) if !from.is_empty() => from
			_ => "rocx <rocx@localhost>"
		}
	}

## An address as written, `Ada Lovelace <ada@example.com>` or `ada@example.com`: its name (perhaps
## none) and the address.
Addressee : { name : Str, address : Str }

mailbox : Str -> Try(Addressee, Str)
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
header_mailbox : Addressee -> Str
header_mailbox = |box|
	if box.name.is_empty() {
		box.address
	} else {
		"\"${box.name.replace_each("\\", "\\\\").replace_each("\"", "\\\"")}\" <${box.address}>"
	}

## The message as SMTP's DATA carries it: headers, then the text alone (`text/plain`), or the text
## and the HTML (`multipart/alternative`); lines ending in CRLF.
compose : Addressee, Addressee, Email.Message, I64, U64 -> Str
compose = |from, to, message, now, random| {
	id = "${hex(random)}.${hex(now.to_u64_wrap())}"
	headers = [
		"Date: ${rfc5322(now)}",
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
expect rfc5322(1795211647000) == "Fri, 20 Nov 2026 21:54:07 +0000"
