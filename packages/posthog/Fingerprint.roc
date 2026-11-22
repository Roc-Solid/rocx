## What makes two errors one issue in PostHog (`$exception_fingerprint`). Without a stack trace,
## PostHog's own grouping has little to go on, so the package sets one itself: the error's source,
## its type, where it happened when that is a pattern (a route's, a job's kind) and its message, with
## what changes from one occurrence to the next taken out (`normalized`): `user 1234 not found` and
## `user 77 not found` are one issue.
Fingerprint := [].{

	## The parts, each normalized, joined by ` | `.
	of : List(Str) -> Str
	of = |parts| Str.join_with(parts.map(Fingerprint.normalized), " | ")

	## `text` with what varies taken out: a word with a digit in it becomes `<n>` (only digits) or
	## `<id>` (a UUID, a hash, a date), and what is between double quotes or backticks `<s>`; at most
	## 300 bytes.
	normalized : Str -> Str
	normalized = |text| {
		var $out = []
		var $word = []
		var $quote = 0
		for byte in text.to_utf8() {
			if $quote != 0 {
				if byte == $quote {
					$out = $out.append($quote).concat("<s>".to_utf8()).append($quote)
					$quote = 0
				} else {
					{}
				}
			} else if byte == '"' or byte == '`' {
				$out = $out.concat(word_out($word))
				$word = []
				$quote = byte
			} else if is_word(byte) {
				$word = $word.append(byte)
			} else {
				$out = $out.concat(word_out($word)).append(byte)
				$word = []
			}
		}
		ended = if ($quote != 0) $out.append($quote).concat("<s>".to_utf8()) else $out.concat(word_out($word))
		Str.from_utf8_lossy(ended.take_first(300))
	}
}

## A letter, a digit, `_` or `-`: what a word is made of.
is_word : U8 -> Bool
is_word = |byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or is_digit(byte) or byte == '_' or byte == '-'

is_digit : U8 -> Bool
is_digit = |byte| byte >= '0' and byte <= '9'

## A word as it is fingerprinted: as it is, without a digit; `<n>`, all digits; `<id>`, else.
word_out : List(U8) -> List(U8)
word_out = |word|
	if !word.any(is_digit) {
		word
	} else if word.all(is_digit) {
		"<n>".to_utf8()
	} else {
		"<id>".to_utf8()
	}

expect Fingerprint.normalized("user 1234 not found") == "user <n> not found"
expect Fingerprint.normalized("user 1234 not found") == Fingerprint.normalized("user 77 not found")
expect Fingerprint.normalized("/posts/42/comments/7") == "/posts/<n>/comments/<n>"
expect Fingerprint.normalized("no row 3f2a9c1e-8b7d-4e2a-9c1e-0b7d4e2a9c1e") == "no row <id>"
expect Fingerprint.normalized("due 2026-11-22, retry") == "due <id>, retry"
expect Fingerprint.normalized("no member called \"ada\"") == "no member called \"<s>\""
expect Fingerprint.normalized("no member called `ada") == "no member called `<s>"
expect Fingerprint.normalized("can't reach the SMTP server") == "can't reach the SMTP server"
expect Fingerprint.normalized("").is_empty()
expect Fingerprint.normalized(Str.repeat("a", 400)).count_utf8_bytes() == 300
expect Fingerprint.of(["server", "ServerError", "/posts/[id]", "answered 500: row 42 is locked"]) == "server | ServerError | /posts/[id] | answered <n>: row <n> is locked"
