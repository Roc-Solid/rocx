import pf.Server
import crypto.Base32
import crypto.Hmac

## Authenticator apps' codes (TOTP, RFC 6238), plain Roc: HMAC-SHA1 over 30-second steps since
## 1970, six digits, as every app (Google Authenticator, 1Password, Authy, a phone's own) reads an
## `otpauth://` URI that says nothing else. `Auth` keeps the secret sealed and the last step used;
## this module is the arithmetic, with RFC 6238's and RFC 4226's own test vectors as `expect`s.
Totp := [].{

	## The step `now_ms` (milliseconds since 1970) is in: RFC 6238's T, 30-second steps from 0.
	step : I64 -> I64
	step = |now_ms| now_ms // 30_000

	## HOTP (RFC 4226, section 5.3): the code for `secret` at `counter`, `digits` long (6 to 9),
	## zeros in front: HMAC-SHA1 of the counter's 8 bytes, big-endian, dynamically truncated to 31
	## bits, the last `digits` decimal digits of that.
	hotp : List(U8), U64, U64 -> Str
	hotp = |secret, counter, digits| {
		var $message = []
		var $shift = 56.U8
		while $shift > 0 {
			$message = $message.append(counter.shr_zf_wrap($shift).to_u8_wrap())
			$shift = $shift - 8
		}
		mac = Hmac.sha1(secret, $message.append(counter.to_u8_wrap()))
		offset = (mac.get(19) ?? 0).bitwise_and(0x0f).to_u64()
		byte = |at| (mac.get(offset + at) ?? 0).to_u64()
		binary = byte(0).bitwise_and(0x7f).shl_wrap(24).bitwise_or(byte(1).shl_wrap(16)).bitwise_or(byte(2).shl_wrap(8)).bitwise_or(byte(3))
		text = (binary % (10.U64).pow(digits)).to_str()
		Str.concat(Str.repeat("0", digits - U64.min(digits, text.to_utf8().len())), text)
	}

	## The six-digit code an app shows for `secret` at step `at`.
	code : List(U8), I64 -> Str
	code = |secret, at| Totp.hotp(secret, at.to_u64_wrap(), 6)

	## Which step `given` is `secret`'s code for: `at`, or the step either side of it (a phone's
	## clock a little out, a code typed as it changed), and only a step later than `used` (the last
	## step a code was taken at: 0 for none), so a code is good once. Each comparison takes the same
	## time however much of it matched.
	matching : List(U8), Str, I64, I64 -> Try(I64, [NoMatch])
	matching = |secret, given, at, used| {
		typed = given.to_utf8()
		found = [at - 1, at, at + 1].find_first(|each| each > used and Hmac.equal(Totp.code(secret, each).to_utf8(), typed))
		match found {
			Ok(each) => Ok(each)
			Err(_) => Err(NoMatch)
		}
	}

	## Whether `text` has a code's shape: six digits.
	is_code : Str -> Bool
	is_code = |text| {
		bytes = text.to_utf8()
		bytes.len() == 6 and bytes.all(|byte| byte >= '0' and byte <= '9')
	}

	## The URI an authenticator app is given, as a QR code (Google's Key URI format, which every app
	## reads): `otpauth://totp/<issuer>:<account>?secret=<Base32>&issuer=<issuer>`. SHA-1, six
	## digits and 30 seconds go unsaid: they are what every app assumes. A colon in the issuer or the
	## account is left out (it separates them).
	uri : { issuer : Str, account : Str, secret : List(U8) } -> Str
	uri = |given| {
		issuer = Server.encode_segment(given.issuer.replace_each(":", ""))
		account = Server.encode_segment(given.account.replace_each(":", ""))
		"otpauth://totp/${issuer}:${account}?secret=${Base32.encode_unpadded(given.secret)}&issuer=${issuer}"
	}

	## A secret as a person types it into an app that can't scan: its Base32 in groups of four.
	grouped : List(U8) -> Str
	grouped = |secret| {
		letters = Base32.encode_unpadded(secret).to_utf8()
		var $groups = []
		var $at = 0
		while $at < letters.len() {
			$groups = $groups.append(Str.from_utf8_lossy(letters.sublist({ start: $at, len: 4 })))
			$at = $at + 4
		}
		Str.join_with($groups, " ")
	}
}

## RFC 6238's SHA-1 seed: the ASCII of "12345678901234567890".
seed : List(U8)
seed = "12345678901234567890".to_utf8()

# RFC 6238, appendix B: every SHA-1 row (8 digits; X = 30, T0 = 0), its time in seconds.
expect Totp.hotp(seed, Totp.step(59 * 1000).to_u64_wrap(), 8) == "94287082"
expect Totp.hotp(seed, Totp.step(1111111109 * 1000).to_u64_wrap(), 8) == "07081804"
expect Totp.hotp(seed, Totp.step(1111111111 * 1000).to_u64_wrap(), 8) == "14050471"
expect Totp.hotp(seed, Totp.step(1234567890 * 1000).to_u64_wrap(), 8) == "89005924"
expect Totp.hotp(seed, Totp.step(2000000000 * 1000).to_u64_wrap(), 8) == "69279037"
expect Totp.hotp(seed, Totp.step(20000000000 * 1000).to_u64_wrap(), 8) == "65353130"
expect Totp.step(1111111109 * 1000) == 0x23523EC

# The same rows as an app shows them: six digits (the last six of the eight).
expect Totp.code(seed, Totp.step(59 * 1000)) == "287082"
expect Totp.code(seed, Totp.step(1111111109 * 1000)) == "081804"
expect Totp.code(seed, Totp.step(1234567890 * 1000)) == "005924"

# RFC 4226, appendix D: HOTP's counters 0 to 9 on the same secret.
expect
	[0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map(|counter| Totp.hotp(seed, counter, 6))
		== ["755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871", "520489"]

# A code is for its step or one either side, later than the last used, and good once.
expect Totp.matching(seed, Totp.code(seed, 100), 100, 0) == Ok(100)
expect Totp.matching(seed, Totp.code(seed, 99), 100, 0) == Ok(99)
expect Totp.matching(seed, Totp.code(seed, 101), 100, 0) == Ok(101)
expect Totp.matching(seed, Totp.code(seed, 98), 100, 0) == Err(NoMatch)
expect Totp.matching(seed, Totp.code(seed, 102), 100, 0) == Err(NoMatch)
expect Totp.matching(seed, Totp.code(seed, 100), 100, 100) == Err(NoMatch)
expect Totp.matching(seed, Totp.code(seed, 99), 100, 99) == Err(NoMatch)
expect Totp.matching(seed, Totp.code(seed, 101), 100, 100) == Ok(101)
expect Totp.matching(seed, "000000", 100, 0) == Err(NoMatch) or Totp.code(seed, 100) == "000000"
expect Totp.matching(List.repeat(1, 20), Totp.code(seed, 100), 100, 0) == Err(NoMatch)

# Shapes.
expect Totp.is_code("012345")
expect !Totp.is_code("12345")
expect !Totp.is_code("1234567")
expect !Totp.is_code("12345a")
expect !Totp.is_code("")

# The URI and the secret's groups.
expect Totp.uri({ issuer: "Acme Books", account: "ada@example.com", secret: seed }) == "otpauth://totp/Acme%20Books:ada%40example.com?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Acme%20Books"
expect Totp.uri({ issuer: "a:b", account: "c:d", secret: [] }) == "otpauth://totp/ab:cd?secret=&issuer=ab"
expect Totp.grouped(seed) == "GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ"
expect Totp.grouped([1, 2, 3]) == "AEBA G"
