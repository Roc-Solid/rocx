## The grid: a million boxes, each checked or not, kept as a thousand chunks of a thousand boxes.
## A chunk is the unit of change: the server keeps each with how many times it has changed (its
## version), and tells every page the whole chunk when one of its boxes does, so a page takes the
## newer of two and never a box out of order. Plain Roc, on no platform: the server and the page
## share it.
Grid := [].{

	## A chunk as it is kept and sent: its number, how many times it has changed, and its boxes as
	## hex, two digits a byte, the chunk's first box the lowest bit of its first byte. "" is a chunk
	## with no box checked.
	Chunk : { chunk : U64, version : U64, bits : Str }

	## What a page says on the channel: a box checked, or unchecked.
	Said : [Set({ index : U64, on : Bool })]

	## What the channel tells every page: a chunk that changed, and how many pages are open.
	News : [Changed(Grid.Chunk), Online(U64)]

	## `GET /boxes`: every chunk with a box checked (the others have none), and how many pages are
	## open.
	Snapshot : { chunks : List(Grid.Chunk), online : U64 }

	## The boxes as a page holds them: each chunk's bytes, and its version.
	Boxes : { bytes : List(List(U8)), versions : List(U64) }

	## How many boxes there are.
	size : U64
	size = 1_000_000

	## How many boxes a chunk has, and how many chunks there are.
	chunk_size : U64
	chunk_size = 1000

	chunk_count : U64
	chunk_count = 1000

	## A chunk's bytes: a bit a box.
	chunk_bytes : U64
	chunk_bytes = 125

	## A chunk with no box checked.
	blank : List(U8)
	blank = List.repeat(0, Grid.chunk_bytes)

	## Every box unchecked, every chunk at version 0.
	empty : Grid.Boxes
	empty = { bytes: List.repeat(Grid.blank, Grid.chunk_count), versions: List.repeat(0, Grid.chunk_count) }

	## The chunk a box is in, and its place there.
	chunk_of : U64 -> U64
	chunk_of = |index| index // Grid.chunk_size

	## Whether box `at` (of the chunk's) is checked in `bytes`.
	bit : List(U8), U64 -> Bool
	bit = |bytes, at| (bytes.get(at // 8) ?? 0).bitwise_and(mask(at)) != 0

	## `bytes` with box `at` (of the chunk's) checked, or not.
	with_bit : List(U8), U64, Bool -> List(U8)
	with_bit = |bytes, at, on|
		match bytes.get(at // 8) {
			Ok(byte) => bytes.set(at // 8, if (on) byte.bitwise_or(mask(at)) else byte.bitwise_and((255.U8).bitwise_xor(mask(at)))) ?? bytes
			Err(_) => bytes
		}

	## A chunk's bytes as hex; "" when no box is checked.
	encode : List(U8) -> Str
	encode = |bytes|
		if bytes.all(|byte| byte == 0) {
			""
		} else {
			var $out = []
			for byte in bytes {
				$out = $out.append(digit(byte.shr_zf_wrap(4))).append(digit(byte.bitwise_and(15)))
			}
			Str.from_utf8_lossy($out)
		}

	## A chunk's bytes from its hex: "" (or anything else that isn't a chunk's) is none checked.
	decode : Str -> List(U8)
	decode = |bits| {
		hex = bits.to_utf8()
		if hex.len() != 2 * Grid.chunk_bytes {
			Grid.blank
		} else {
			var $out = []
			var $at = 0
			while $at < hex.len() {
				high = value_of(hex.get($at) ?? '0')
				low = value_of(hex.get($at + 1) ?? '0')
				$out = $out.append(high.shl_wrap(4).bitwise_or(low))
				$at = $at + 2
			}
			$out
		}
	}

	## The boxes a snapshot says: its chunks, the others none checked.
	boxes_of : Grid.Snapshot -> Grid.Boxes
	boxes_of = |snapshot| snapshot.chunks.fold(Grid.empty, |boxes, chunk| Grid.heard(boxes, chunk))

	## The boxes with `chunk` in them, if it is newer than the one they have.
	heard : Grid.Boxes, Grid.Chunk -> Grid.Boxes
	heard = |boxes, chunk| {
		had = boxes.versions.get(chunk.chunk) ?? 0
		if chunk.chunk >= Grid.chunk_count or chunk.version <= had {
			boxes
		} else {
			{ bytes: boxes.bytes.set(chunk.chunk, Grid.decode(chunk.bits)) ?? boxes.bytes, versions: boxes.versions.set(chunk.chunk, chunk.version) ?? boxes.versions }
		}
	}

	## The newer of each chunk: what was heard on the channel, and a snapshot read again.
	merged : Grid.Boxes, Grid.Boxes -> Grid.Boxes
	merged = |a, b| {
		var $bytes = []
		var $versions = []
		var $at = 0
		while $at < Grid.chunk_count {
			va = a.versions.get($at) ?? 0
			vb = b.versions.get($at) ?? 0
			from = if (vb > va) b else a
			$bytes = $bytes.append(from.bytes.get($at) ?? Grid.blank)
			$versions = $versions.append(U64.max(va, vb))
			$at = $at + 1
		}
		{ bytes: $bytes, versions: $versions }
	}

	## Whether box `index` is checked.
	checked : Grid.Boxes, U64 -> Bool
	checked = |boxes, index|
		match boxes.bytes.get(Grid.chunk_of(index)) {
			Ok(bytes) => Grid.bit(bytes, index % Grid.chunk_size)
			Err(_) => Bool.False
		}

	## Box `index` checked or not here, at once, before the server says (its chunk's version kept, so
	## the server's next version of it replaces this).
	toggled : Grid.Boxes, U64, Bool -> Grid.Boxes
	toggled = |boxes, index, on| {
		chunk = Grid.chunk_of(index)
		match boxes.bytes.get(chunk) {
			Ok(bytes) => { ..boxes, bytes: boxes.bytes.set(chunk, Grid.with_bit(bytes, index % Grid.chunk_size, on)) ?? boxes.bytes }
			Err(_) => boxes
		}
	}

	## How many boxes are checked: in the chunks that have changed (a chunk at version 0 has none).
	count : Grid.Boxes -> U64
	count = |boxes| {
		var $sum = 0
		var $at = 0
		while $at < Grid.chunk_count {
			if (boxes.versions.get($at) ?? 0) > 0 {
				for byte in boxes.bytes.get($at) ?? [] {
					$sum = $sum + (ones_in.get(byte.to_u64()) ?? 0)
				}
			}
			$at = $at + 1
		}
		$sum
	}

	## How many boxes a row has, for a grid `width` pixels wide: as many as fit beside the row's
	## number, at least 8 and at most 64.
	columns : U64 -> U64
	columns = |width| U64.min(U64.max(width.minus_saturated(Grid.gutter) // Grid.cell, 8), 64)

	## How many rows a million boxes take, `per_row` a row.
	rows : U64 -> U64
	rows = |per_row| (Grid.size + per_row - 1) // U64.max(per_row, 1)

	## How many boxes row `row` has: `per_row`, but the last, which may have fewer.
	in_row : U64, U64 -> U64
	in_row = |row, per_row| U64.min(per_row, Grid.size.minus_saturated(row * per_row))

	## A box's width and a row's height, in pixels, and the width of a row's number before it.
	cell : U64
	cell = 28

	gutter : U64
	gutter = 76

	## Columns before the grid is measured (on the server, and the first paint).
	first_columns : U64
	first_columns = 40

	## A number with its thousands apart: 1,000,000.
	thousands : U64 -> Str
	thousands = |n| {
		digits = n.to_str().to_utf8()
		var $out = []
		var $at = 0
		for d in digits {
			left = digits.len() - $at
			$out = if ($at > 0 and left % 3 == 0) $out.append(',').append(d) else $out.append(d)
			$at = $at + 1
		}
		Str.from_utf8_lossy($out)
	}

	## What a box is called, for screen readers and for its title: its number, from 1.
	label : U64 -> Str
	label = |index| "Box ${Grid.thousands(index + 1)}"
}

mask : U64 -> U8
mask = |at| (1.U8).shl_wrap((at % 8).to_u8_wrap())

digit : U8 -> U8
digit = |nibble| if (nibble < 10) '0' + nibble else 'a' + nibble - 10

value_of : U8 -> U8
value_of = |c|
	if c >= '0' and c <= '9' {
		c - '0'
	} else if c >= 'a' and c <= 'f' {
		c - 'a' + 10
	} else if c >= 'A' and c <= 'F' {
		c - 'A' + 10
	} else {
		0
	}

## How many bits each byte has set, by the byte.
ones_in : List(U64)
ones_in = {
	var $table = []
	var $byte = 0.U64
	while $byte < 256 {
		$table = $table.append(ones($byte.to_u8_wrap()))
		$byte = $byte + 1
	}
	$table
}

ones : U8 -> U64
ones = |byte| {
	var $n = 0
	var $rest = byte
	while $rest != 0 {
		$n = $n + $rest.bitwise_and(1).to_u64()
		$rest = $rest.shr_zf_wrap(1)
	}
	$n
}

expect Grid.encode(Grid.blank) == ""
expect Grid.decode("") == Grid.blank
expect Grid.decode(Grid.encode(Grid.with_bit(Grid.blank, 9, Bool.True))) == Grid.with_bit(Grid.blank, 9, Bool.True)
expect Grid.encode(Grid.with_bit(Grid.blank, 9, Bool.True)).starts_with("0002")
expect Grid.bit(Grid.with_bit(Grid.blank, 999, Bool.True), 999)
expect !Grid.bit(Grid.with_bit(Grid.with_bit(Grid.blank, 5, Bool.True), 5, Bool.False), 5)

# A chunk heard is taken when it is newer, and not when it isn't.
expect {
	one = Grid.heard(Grid.empty, { chunk: 3, version: 2, bits: Grid.encode(Grid.with_bit(Grid.blank, 7, Bool.True)) })
	older = Grid.heard(one, { chunk: 3, version: 1, bits: "" })
	Grid.checked(one, 3007) and Grid.checked(older, 3007) and !Grid.checked(one, 3006) and Grid.count(one) == 1
}

# Checked at once, then the server's version replaces it.
expect {
	mine = Grid.toggled(Grid.empty, 42, Bool.True)
	server = Grid.heard(mine, { chunk: 0, version: 1, bits: "" })
	Grid.checked(mine, 42) and !Grid.checked(server, 42)
}

# A snapshot read again, and what was heard meanwhile: the newer of each.
expect {
	heard = Grid.heard(Grid.empty, { chunk: 1, version: 5, bits: Grid.encode(Grid.with_bit(Grid.blank, 0, Bool.True)) })
	read = Grid.boxes_of({ chunks: [{ chunk: 1, version: 4, bits: "" }, { chunk: 2, version: 1, bits: Grid.encode(Grid.with_bit(Grid.blank, 1, Bool.True)) }], online: 1 })
	both = Grid.merged(heard, read)
	Grid.checked(both, 1000) and Grid.checked(both, 2001) and Grid.count(both) == 2
}

expect Grid.columns(1200) == 40
expect Grid.columns(300) == 8
expect Grid.columns(5000) == 64
expect Grid.rows(40) == 25_000
expect Grid.rows(64) == 15_625
expect Grid.in_row(33_333, 30) == 10
expect Grid.in_row(0, 30) == 30
expect Grid.thousands(1_000_000) == "1,000,000"
expect Grid.thousands(999) == "999"
expect Grid.label(0) == "Box 1"
