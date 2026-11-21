## An IP address, v4 or v6, and ranges of them (CIDR: `10.0.0.0/8`, `2001:db8::/32`): what an
## allow or deny list holds, what a trusted proxy is, and what a client's address is checked
## against.
##
##     Ip.parse("2001:DB8:0:0:0:0:0:1").map_ok(Ip.to_str)    # Ok("2001:db8::1")
##     Ip.within_any(ip, Ip.cidrs(["10.0.0.0/8", "192.168.0.0/16"]))
Ip := [V4(U32), V6(U128)].{

	## A range of addresses: those whose first `bits` bits are `ip`'s.
	Cidr : { ip : Ip, bits : U8 }

	## The address `text` names: `203.0.113.7`, `2001:db8::1`, `::ffff:192.0.2.1` (an IPv4
	## address as IPv6 writes it, read as that IPv4 address). A zone (`fe80::1%eth0`) is dropped.
	## Nothing else is read: no port, no brackets, no leading zeros in IPv4 (`010.0.0.1` could
	## mean octal).
	parse : Str -> Try(Ip, [BadIp])
	parse = |text| {
		bare =
			match text.split_first("%") {
				Ok({ before, .. }) => before
				Err(_) => text
			}
		if bare.contains(":") {
			match v6_groups(bare) {
				Ok(number) =>
					if U128.shr_zf_wrap(number, 32) == 0xffff {
						Ok(V4(U128.bitwise_and(number, 0xffffffff).to_u32_wrap()))
					} else {
						Ok(V6(number))
					}
				Err(BadIp) => Err(BadIp)
			}
		} else {
			match v4_number(bare) {
				Ok(number) => Ok(V4(number))
				Err(BadIp) => Err(BadIp)
			}
		}
	}

	## As text: IPv4 dotted; IPv6 as RFC 5952 writes it, in lower case, without leading zeros, its
	## longest run of zero groups (two or more; the first, of two as long) as `::`.
	to_str : Ip -> Str
	to_str = |ip|
		match ip {
			V4(number) => v4_text(number)
			V6(number) => v6_text(number)
		}

	## Whether two addresses are the same one.
	is_eq : Ip, Ip -> Bool
	is_eq = |a, b|
		match (a, b) {
			(V4(x), V4(y)) => x == y
			(V6(x), V6(y)) => x == y
			_ => Bool.False
		}

	## Whether it is IPv4.
	is_v4 : Ip -> Bool
	is_v4 = |ip|
		match ip {
			V4(_) => Bool.True
			V6(_) => Bool.False
		}

	## A range of addresses from text: a CIDR (`10.0.0.0/8`, `2001:db8::/32`), or one address (`192.0.2.7`: all
	## its bits). Bits past the prefix (`10.1.2.3/8`) are allowed, and don't count.
	cidr : Str -> Try(Cidr, [BadCidr])
	cidr = |text|
		match text.trim().split_first("/") {
			Ok({ before, after }) =>
				match (Ip.parse(before), U8.from_str(after)) {
					(Ok(ip), Ok(bits)) =>
						if bits <= width(ip) and !after.starts_with("+") {
							Ok({ ip, bits })
						} else {
							Err(BadCidr)
						}
					_ => Err(BadCidr)
				}
			Err(_) =>
				match Ip.parse(text.trim()) {
					Ok(ip) => Ok({ ip, bits: width(ip) })
					Err(BadIp) => Err(BadCidr)
				}
		}

	## Ranges from text, as `cidr` reads each. One that isn't a range is a mistake in the app's
	## code (a list of proxies, an allow list), and crashes, naming it, rather than be skipped: a
	## deny list missing an entry would let in whom it names.
	cidrs : List(Str) -> List(Cidr)
	cidrs = |texts|
		texts.map(
			|text|
				match Ip.cidr(text) {
					Ok(found) => found
					Err(BadCidr) => crash "guard: \"${text}\" isn't an IP address or range (10.0.0.0/8, 2001:db8::/32)"
				},
		)

	## Whether `ip` is in `block`. An IPv4 address is in no IPv6 range, and the other way round.
	within : Ip, Cidr -> Bool
	within = |ip, block|
		match (ip, block.ip) {
			(V4(a), V4(b)) => if (block.bits == 0) Bool.True else U32.shr_zf_wrap(a, 32 - block.bits) == U32.shr_zf_wrap(b, 32 - block.bits)
			(V6(a), V6(b)) => if (block.bits == 0) Bool.True else U128.shr_zf_wrap(a, 128 - block.bits) == U128.shr_zf_wrap(b, 128 - block.bits)
			_ => Bool.False
		}

	## Whether `ip` is in any of `blocks`.
	within_any : Ip, List(Cidr) -> Bool
	within_any = |ip, blocks| blocks.any(|each| Ip.within(ip, each))

	## What a rate limit counts `ip` as: an IPv4 address, whole; an IPv6 address by its first 64
	## bits (`2001:db8:1:2::/64`), the block one household or one machine is given, and could
	## spend a fresh address of for each request.
	key : Ip -> Str
	key = |ip|
		match ip {
			V4(number) => v4_text(number)
			V6(number) => "${v6_text(U128.shl_wrap(U128.shr_zf_wrap(number, 64), 64))}/64"
		}

	## The loopback and private ranges (RFC 1918, unique local, link-local): where a proxy in the
	## same network as the server usually is. `Proxies(Ip.private)` trusts them (`ClientIp`).
	private : List(Cidr)
	private = Ip.cidrs(["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "::1/128", "fc00::/7", "fe80::/10"])
}

## How many bits an address of `ip`'s kind has.
width : Ip -> U8
width = |ip| if (Ip.is_v4(ip)) 32 else 128

## Whether every byte is a decimal digit (and there is one).
digits : Str -> Bool
digits = |text| {
	bytes = text.to_utf8()
	!bytes.is_empty() and bytes.all(|byte| byte >= '0' and byte <= '9')
}

## `a.b.c.d` as a number: four decimal parts, each 0 to 255, none with a leading zero.
v4_number : Str -> Try(U32, [BadIp])
v4_number = |text| {
	parts = text.split_on(".")
	if parts.len() != 4 {
		Err(BadIp)
	} else {
		parts.fold(
			Ok(0),
			|sofar, part|
				match sofar {
					Err(BadIp) => Err(BadIp)
					Ok(number) =>
						if !digits(part) or part.count_utf8_bytes() > 3 or (part.count_utf8_bytes() > 1 and part.starts_with("0")) {
							Err(BadIp)
						} else {
							match U32.from_str(part) {
								Ok(value) => if (value > 255) Err(BadIp) else Ok(number * 256 + value)
								Err(_) => Err(BadIp)
							}
						}
				},
		)
	}
}

v4_text : U32 -> Str
v4_text = |number| {
	octet = |shift| U32.bitwise_and(U32.shr_zf_wrap(number, shift), 255).to_str()
	"${octet(24)}.${octet(16)}.${octet(8)}.${octet(0)}"
}

## One group of IPv6: one to four hex digits.
hex_group : Str -> Try(U128, [BadIp])
hex_group = |text| {
	bytes = text.to_utf8()
	if bytes.is_empty() or bytes.len() > 4 {
		Err(BadIp)
	} else {
		bytes.fold(
			Ok(0),
			|sofar, byte|
				match sofar {
					Err(BadIp) => Err(BadIp)
					Ok(value) =>
						if byte >= '0' and byte <= '9' {
							Ok(value * 16 + (byte - '0').to_u128())
						} else if byte >= 'a' and byte <= 'f' {
							Ok(value * 16 + (byte - 'a' + 10).to_u128())
						} else if byte >= 'A' and byte <= 'F' {
							Ok(value * 16 + (byte - 'A' + 10).to_u128())
						} else {
							Err(BadIp)
						}
				},
		)
	}
}

## A side of an IPv6 address (`2001:db8` of `2001:db8::1`) as its 16-bit groups; its last may be
## an IPv4 address (`::ffff:192.0.2.1`), two groups.
v6_side : Str, Bool -> Try(List(U128), [BadIp])
v6_side = |text, last|
	if text.is_empty() {
		Ok([])
	} else {
		parts = text.split_on(":")
		var $groups = Ok([])
		var $left = parts.len()
		for part in parts {
			$left = $left - 1
			$groups =
				match $groups {
					Err(BadIp) => Err(BadIp)
					Ok(groups) =>
						if last and $left == 0 and part.contains(".") {
							match v4_number(part) {
								Ok(number) => Ok(groups.concat([U32.shr_zf_wrap(number, 16).to_u128(), U32.bitwise_and(number, 0xffff).to_u128()]))
								Err(BadIp) => Err(BadIp)
							}
						} else {
							match hex_group(part) {
								Ok(group) => Ok(groups.append(group))
								Err(BadIp) => Err(BadIp)
							}
						}
				}
		}
		$groups
	}

## The eight groups of an IPv6 address as one number; `::` stands for one or more zero groups.
v6_groups : Str -> Try(U128, [BadIp])
v6_groups = |text| {
	grouped =
		match text.split_first("::") {
			Ok({ before, after }) =>
				if after.contains("::") {
					Err(BadIp)
				} else {
					match (v6_side(before, Bool.False), v6_side(after, Bool.True)) {
						(Ok(head), Ok(tail)) =>
							if head.len() + tail.len() > 7 {
								Err(BadIp)
							} else {
								Ok(head.concat(List.repeat(0, 8 - head.len() - tail.len())).concat(tail))
							}
						_ => Err(BadIp)
					}
				}
			Err(_) =>
				match v6_side(text, Bool.True) {
					Ok(groups) => if (groups.len() == 8) Ok(groups) else Err(BadIp)
					Err(BadIp) => Err(BadIp)
				}
		}
	match grouped {
		Ok(groups) => Ok(groups.fold(0, |number, group| U128.bitwise_or(U128.shl_wrap(number, 16), group)))
		Err(BadIp) => Err(BadIp)
	}
}

## Hex digits for a group, without leading zeros: `0`, `db8`, `ffff`.
hex_text : U128 -> Str
hex_text = |group| {
	alphabet = "0123456789abcdef".to_utf8()
	digit = |shift| alphabet.get(U128.bitwise_and(U128.shr_zf_wrap(group, shift), 15).to_u64_wrap()) ?? '0'
	whole = [digit(12), digit(8), digit(4), digit(0)]
	var $at = 0
	while $at < 3 and whole.get($at) == Ok('0') {
		$at = $at + 1
	}
	Str.from_utf8_lossy(whole.drop_first($at))
}

v6_text : U128 -> Str
v6_text = |number| {
	groups = [112, 96, 80, 64, 48, 32, 16, 0].map(|shift| U128.bitwise_and(U128.shr_zf_wrap(number, shift), 0xffff))
	# The longest run of zero groups, two or more long (the first, of two as long): `::`.
	var $best_at = 0
	var $best_len = 0
	var $run_at = 0
	var $run_len = 0
	var $at = 0
	for group in groups {
		at = $at
		$at = $at + 1
		if group == 0 {
			if $run_len == 0 {
				$run_at = at
			}
			$run_len = $run_len + 1
			if $run_len > $best_len {
				$best_at = $run_at
				$best_len = $run_len
			}
		} else {
			$run_len = 0
		}
	}
	text = |part| Str.join_with(part.map(hex_text), ":")
	if $best_len >= 2 {
		"${text(groups.take_first($best_at))}::${text(groups.drop_first($best_at + $best_len))}"
	} else {
		text(groups)
	}
}

shown : Str -> Str
shown = |text|
	match Ip.parse(text) {
		Ok(ip) => Ip.to_str(ip)
		Err(BadIp) => "bad"
	}

inside : Str, Str -> Bool
inside = |text, cidr|
	match (Ip.parse(text), Ip.cidr(cidr)) {
		(Ok(ip), Ok(found)) => Ip.within(ip, found)
		_ => Bool.False
	}

# IPv4: as written; not with a leading zero, a fifth part, a part past 255, a sign or a space.
expect shown("203.0.113.7") == "203.0.113.7"
expect shown("0.0.0.0") == "0.0.0.0"
expect shown("255.255.255.255") == "255.255.255.255"
expect shown("010.0.0.1") == "bad"
expect shown("1.2.3.4.5") == "bad"
expect shown("1.2.3") == "bad"
expect shown("256.0.0.1") == "bad"
expect shown("1.2.3.+4") == "bad"
expect shown("1.2.3. 4") == "bad"
expect shown("") == "bad"
expect shown("1.2.3.4:80") == "bad"

# IPv6, as RFC 5952 writes it: lower case, no leading zeros, the longest run of zeros as `::`
# (the first of two as long), a lone zero group as `0`.
expect shown("2001:DB8:0:0:0:0:0:1") == "2001:db8::1"
expect shown("2001:0db8:0000:0000:0000:ff00:0042:8329") == "2001:db8::ff00:42:8329"
expect shown("::1") == "::1"
expect shown("::") == "::"
expect shown("2001:db8:0:1:1:1:1:1") == "2001:db8:0:1:1:1:1:1"
expect shown("2001:0:0:1:0:0:0:1") == "2001:0:0:1::1"
expect shown("2001:db8:0:0:1:0:0:1") == "2001:db8::1:0:0:1"
expect shown("fe80::1%eth0") == "fe80::1"
expect shown("1::") == "1::"
expect shown("1:2:3:4:5:6:7:8") == "1:2:3:4:5:6:7:8"
expect shown("1:2:3:4:5:6:7") == "bad"
expect shown("1:2:3:4:5:6:7:8:9") == "bad"
expect shown("1::2::3") == "bad"
expect shown("12345::") == "bad"
expect shown("g::1") == "bad"
expect shown("1:2:3:4:5:6:7::8") == "bad"
expect shown("[::1]") == "bad"

# An IPv4 address as IPv6 writes it is that IPv4 address; one in another IPv6 form isn't.
expect shown("::ffff:192.0.2.1") == "192.0.2.1"
expect shown("::FFFF:c000:0201") == "192.0.2.1"
expect shown("64:ff9b::192.0.2.1") == "64:ff9b::c000:201"
expect shown("::ffff:192.0.2") == "bad"

# Ranges: a prefix, or one address; bits past the prefix don't count; IPv4 never matches IPv6.
expect inside("10.1.2.3", "10.0.0.0/8")
expect !inside("11.0.0.1", "10.0.0.0/8")
expect inside("172.31.255.255", "172.16.0.0/12")
expect !inside("172.32.0.0", "172.16.0.0/12")
expect inside("192.0.2.7", "192.0.2.7")
expect !inside("192.0.2.8", "192.0.2.7")
expect inside("8.8.8.8", "0.0.0.0/0")
expect inside("10.200.0.1", "10.1.2.3/8")
expect inside("2001:db8:1::5", "2001:db8::/32")
expect !inside("2001:db9::5", "2001:db8::/32")
expect inside("::1", "::1/128")
expect inside("fd12:3456::1", "fc00::/7")
expect !inside("10.0.0.1", "::/0")
expect !inside("::1", "0.0.0.0/0")
expect Ip.cidr("10.0.0.0/33") == Err(BadCidr)
expect Ip.cidr("10.0.0.0/") == Err(BadCidr)
expect Ip.cidr("10.0.0.0/+8") == Err(BadCidr)
expect Ip.cidr("2001:db8::/129") == Err(BadCidr)
expect Ip.cidr("nope") == Err(BadCidr)
expect Ip.cidr(" 10.0.0.0/8 ").is_ok()

# Keys: an IPv4 address whole, an IPv6 one by its /64.
expect Ip.parse("203.0.113.7").map_ok(Ip.key) == Ok("203.0.113.7")
expect Ip.parse("2001:db8:1:2:aaaa:bbbb:cccc:dddd").map_ok(Ip.key) == Ok("2001:db8:1:2::/64")
expect Ip.parse("2001:db8:1:2::9").map_ok(Ip.key) == Ip.parse("2001:db8:1:2:ffff::1").map_ok(Ip.key)

# The private ranges: loopback, RFC 1918, unique local and link-local; not a public address.
expect ["127.0.0.1", "10.0.0.5", "172.20.1.1", "192.168.1.1", "::1", "fd00::1", "fe80::1"].all(|text| Ip.parse(text).map_ok(|ip| Ip.within_any(ip, Ip.private)) == Ok(Bool.True))
expect Ip.parse("203.0.113.7").map_ok(|ip| Ip.within_any(ip, Ip.private)) == Ok(Bool.False)
