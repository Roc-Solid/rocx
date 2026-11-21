import Base64Url
import Kdf

## The "aes128gcm" content coding (RFC 8188), which Web Push's messages are written in: a header,
## then records. The header is a salt (16 bytes), the record size (4 bytes, big-endian), a key id's
## length (1 byte) and the key id. Each record is AES-128-GCM-sealed: its data, a delimiter (2 for
## the last record, 1 for the others), then zeros, as many as the sender wants to hide the data's
## length with; sealed, a record is at most `record_size` bytes, the tag's 16 among them.
##
## The content key and the nonce come from the input keying material and the salt with HKDF
## (`keys`); record `n` is sealed with the nonce XOR `n` (`nonce`). Sealing is AES, which the host
## does; this is everything around it.
Ece := [].{

	## What the header says.
	Header : { salt : List(U8), record_size : U32, key_id : List(U8) }

	## The header's bytes.
	header : Header -> List(U8)
	header = |{ salt, record_size, key_id }|
		salt
			.concat([
				record_size.shr_zf_wrap(24).to_u8_wrap(),
				record_size.shr_zf_wrap(16).to_u8_wrap(),
				record_size.shr_zf_wrap(8).to_u8_wrap(),
				record_size.to_u8_wrap(),
				key_id.len().to_u8_wrap(),
			])
			.concat(key_id)

	## The header at the start of `body`, and the records after it. `TooShort` when it is cut off;
	## `BadRecordSize` for a record size too small to hold a delimiter and a tag (18 at least).
	parse_header : List(U8) -> Try({ header : Header, records : List(U8) }, [TooShort, BadRecordSize])
	parse_header = |body| {
		if body.len() < 21 {
			return Err(TooShort)
		}
		id_length = (body.get(20) ?? 0).to_u64()
		if body.len() < 21 + id_length {
			return Err(TooShort)
		}
		record_size = body.sublist({ start: 16, len: 4 }).fold(0.U32, |size, each| size.shl_wrap(8).bitwise_or(each.to_u32()))
		if record_size < 18 {
			return Err(BadRecordSize)
		}
		Ok({
			header: { salt: body.take_first(16), record_size, key_id: body.sublist({ start: 21, len: id_length }) },
			records: body.drop_first(21 + id_length),
		})
	}

	## A record's plaintext, ready to seal: `data`, the delimiter (`last` or not), then `padding`
	## zeros.
	pad : List(U8), U64, Bool -> List(U8)
	pad = |data, padding, last| data.append(if (last) 2 else 1).concat(List.repeat(0, padding))

	## What `pad` padded: the data, and whether it was the last record. `NoDelimiter` when the
	## record is all zeros, or ends in something that isn't a delimiter.
	unpad : List(U8) -> Try({ data : List(U8), last : Bool }, [NoDelimiter])
	unpad = |record|
		match record.find_last_index(|each| each != 0) {
			Ok(at) =>
				match record.get(at) {
					Ok(2) => Ok({ data: record.take_first(at), last: Bool.True })
					Ok(1) => Ok({ data: record.take_first(at), last: Bool.False })
					_ => Err(NoDelimiter)
				}
			Err(_) => Err(NoDelimiter)
		}

	## "Content-Encoding: aes128gcm" and a zero byte: the content key's HKDF info.
	key_info : List(U8)
	key_info = "Content-Encoding: aes128gcm".to_utf8().append(0)

	## "Content-Encoding: nonce" and a zero byte: the nonce's HKDF info.
	nonce_info : List(U8)
	nonce_info = "Content-Encoding: nonce".to_utf8().append(0)

	## The content key (16 bytes, AES-128's) and the base nonce (12 bytes), from the input keying
	## material and the header's salt.
	keys : List(U8), List(U8) -> { key : List(U8), nonce : List(U8) }
	keys = |input, salt| {
		pseudorandom_key = Kdf.extract(salt, input)
		{
			key: Kdf.expand(pseudorandom_key, Ece.key_info, 16) ?? [],
			nonce: Kdf.expand(pseudorandom_key, Ece.nonce_info, 12) ?? [],
		}
	}

	## The nonce record `sequence` (0 for the first) is sealed with: the base nonce XOR the
	## sequence number, as a 96-bit big-endian number.
	nonce : List(U8), U64 -> List(U8)
	nonce = |base, sequence|
		base.map_with_index(
			|each, at|
				if at < 4 {
					each
				} else {
					each.bitwise_xor(sequence.shr_zf_wrap(((11 - at) * 8).to_u8_wrap()).to_u8_wrap())
				},
		)

	## The bytes a tag takes: what sealing adds to a record.
	tag_size : U64
	tag_size = 16
}

## The bytes of base64url text, for the RFC's examples.
b64 : Str -> List(U8)
b64 = |text| Base64Url.decode(text) ?? []

# RFC 8188, section 3.1: one record of 4096, no key id.
expect Ece.keys(b64("yqdlZ-tYemfogSmv7Ws5PQ"), b64("I1BsxtFttlv3u_Oo94xnmw")) == { key: b64("_wniytB-ofscZDh4tbSjHw"), nonce: b64("Bcs8gkIRKLI8GeI8") }
expect Ece.pad("I am the walrus".to_utf8(), 0, Bool.True) == b64("SSBhbSB0aGUgd2FscnVzAg")
expect Ece.header({ salt: b64("I1BsxtFttlv3u_Oo94xnmw"), record_size: 4096, key_id: [] }) == b64("I1BsxtFttlv3u_Oo94xnmwAAEAAA")

# Section 3.2: records of 25 (9 bytes of plaintext each), the key id "a1", the first record padded
# with one zero.
expect Ece.keys(b64("BO3ZVPxUlnLORbVGMpbT1Q"), b64("uNCkWiNYzKTnBN9ji3-qWA")) == { key: b64("u_eEOTjjVWUVrH82pQNwpw"), nonce: b64("VqylG1rdt-mJrNgP") }
expect Ece.header({ salt: b64("uNCkWiNYzKTnBN9ji3-qWA"), record_size: 25, key_id: "a1".to_utf8() }) == b64("uNCkWiNYzKTnBN9ji3-qWAAAABkCYTE")
expect Ece.pad("I am th".to_utf8(), 1, Bool.False) == b64("SSBhbSB0aAEA")
expect Ece.pad("e walrus".to_utf8(), 0, Bool.True) == b64("ZSB3YWxydXMC")
expect Ece.nonce(b64("VqylG1rdt-mJrNgP"), 0) == b64("VqylG1rdt-mJrNgP")
expect Ece.nonce(b64("VqylG1rdt-mJrNgP"), 1) == b64("VqylG1rdt-mJrNgO")

# The sequence number reaches into the nonce's last eight bytes only.
expect Ece.nonce(List.repeat(0, 12), 0x0102030405060708) == [0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8]
expect Ece.nonce(List.repeat(0xff, 12), 1) == [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe]

# Reading a header back.
expect
	Ece.parse_header(b64("uNCkWiNYzKTnBN9ji3-qWAAAABkCYTE").concat([9, 9]))
		== Ok({ header: { salt: b64("uNCkWiNYzKTnBN9ji3-qWA"), record_size: 25, key_id: "a1".to_utf8() }, records: [9, 9] })
expect Ece.parse_header(List.repeat(0, 20)) == Err(TooShort)
expect Ece.parse_header(List.repeat(0, 16).concat([0, 0, 16, 0, 3, 1])) == Err(TooShort)
expect Ece.parse_header(List.repeat(0, 16).concat([0, 0, 0, 17, 0])) == Err(BadRecordSize)

# Padding off again.
expect Ece.unpad(Ece.pad([1, 2, 3], 5, Bool.True)) == Ok({ data: [1, 2, 3], last: Bool.True })
expect Ece.unpad(Ece.pad([0, 0], 0, Bool.False)) == Ok({ data: [0, 0], last: Bool.False })
expect Ece.unpad(Ece.pad([], 3, Bool.True)) == Ok({ data: [], last: Bool.True })
expect Ece.unpad([0, 0, 0]) == Err(NoDelimiter)
expect Ece.unpad([7, 3, 0]) == Err(NoDelimiter)
