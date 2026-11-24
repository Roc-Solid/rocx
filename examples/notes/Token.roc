import crypto.Base64
import crypto.Sha256

## Personal access tokens, which AI clients and scripts send as `Authorization: Bearer …`. Each is
## 32 random bytes (the server's `Random.bytes!`) in Base64 for URLs, and is never kept. What is
## kept is its SHA-256 (packages/crypto), so a copy of the database signs nobody in: a token is found
## by hashing what was sent and looking the hash up. (A sign-in link's token, and a session's, are
## packages/auth's, kept the same way.) Plain Roc, so the `expect`s below hold the rules.
Token := [].{

	## A token as the settings page lists it: never the token itself, which is shown once, when it is
	## made. `last_used` is `""` for a token never used.
	Listed : { id : Str, name : Str, hint : Str, read_only : Bool, created : Str, last_used : Str }

	## A token just made: the token itself, shown this once, and how it will be listed.
	Made : { token : Str, listed : Token.Listed }

	## What every personal access token starts with: it says what a token is when one turns up in a
	## log or a repository, so a secret scanner can find it.
	prefix : Str
	prefix = "acme_pat_"

	## A personal access token, from 32 random bytes.
	personal : List(U8) -> Str
	personal = |random| "${Token.prefix}${Base64.url_encode(random)}"

	## What is kept of a token: its SHA-256, in hex.
	hash : Str -> Str
	hash = |token| Sha256.hex(token.to_utf8())

	## Whether `token` has a personal access token's shape: the prefix, then 43 characters of Base64
	## for URLs (32 bytes). Anything else is refused before the database is asked.
	is_personal : Str -> Bool
	is_personal = |token|
		token.starts_with(Token.prefix)
			and (Base64.url_decode(token.drop_prefix(Token.prefix)).map_ok(|bytes| bytes.len() == 32) ?? Bool.False)

	## A token's last four characters: shown beside its name, to tell tokens apart, and too few to
	## guess the rest from.
	hint : Str -> Str
	hint = |token| {
		bytes = token.to_utf8()
		Str.from_utf8_lossy(bytes.drop_first(bytes.len() - U64.min(4, bytes.len())))
	}

	## A token's name, which says where it is used ("Laptop: Claude Code"): 1 to 60 characters.
	name_of : Str -> Try(Str, Str)
	name_of = |given| {
		name = given.trim()
		if name.is_empty() {
			Err("Give the token a name, to know it by later.")
		} else if name.count_utf8_bytes() > 60 {
			Err("A token's name is 60 characters at most.")
		} else {
			Ok(name)
		}
	}
}

random = List.repeat(7, 32)

made = Token.personal(random)

expect made.starts_with("acme_pat_") and made.count_utf8_bytes() == 9 + 43
expect Token.is_personal(made)
# Base64 of 32 bytes without the prefix (a sign-in link's token, or a session's) isn't one.
expect !Token.is_personal(Base64.url_encode(random))
expect !Token.is_personal("acme_pat_short")
expect !Token.is_personal("acme_pat_${Base64.url_encode(List.repeat(7, 31))}")
# The hash is SHA-256's, so the same token always finds the same row, and another never does.
expect Token.hash(made) == Token.hash(made) and Token.hash(made) != Token.hash(Token.personal(List.repeat(8, 32)))
expect Token.hash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
expect Token.hash(made).count_utf8_bytes() == 64 and !Token.hash(made).contains(made)
expect Token.hint("acme_pat_abcdWXYZ") == "WXYZ"
expect Token.hint("ab") == "ab"
expect Token.name_of("  Laptop ") == Ok("Laptop")
expect Token.name_of("").is_err()
