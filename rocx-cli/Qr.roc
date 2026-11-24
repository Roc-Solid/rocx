## QR codes, for `rocx dev --android --lan`: the address a phone on Wi-Fi scans to open the dev
## client (D-063's dev mode). Byte mode, error correction level M, versions 1 to 6 (up to 106
## bytes: an address fits in 3 or 4), the mask the standard's penalty rules choose. ISO/IEC 18004;
## the steps follow Project Nayuki's reference encoder.
Qr := [].{

	## The modules of `text`'s code, row by row, dark `Bool.True`, and its size; or why there is
	## none (more than 106 bytes).
	encode : Str -> Try({ size : U64, dark : List(Bool) }, [TooLong])
	encode = |text| {
		bytes = text.to_utf8()
		version =
			match Qr.version_for(bytes.len()) {
				Ok(found) => found
				Err(_) => return Err(TooLong)
			}
		shape = Qr.blocks_of(version)
		codewords = Qr.interleaved(Qr.data_codewords(bytes, shape.blocks * shape.data), shape)
		size = 17 + 4 * version
		base = Qr.function_patterns(version, size)
		placed = Qr.place(base, codewords, size)
		var $best = 0
		var $lowest = 0
		var $mask = 0
		while $mask < 8 {
			trial = Qr.format_bits(Qr.masked(placed, base.function, size, $mask), size, $mask)
			score = Qr.penalty_of(trial, size)
			if $mask == 0 or score < $lowest {
				$best = $mask
				$lowest = score
			}
			$mask = $mask + 1
		}
		Ok({ size, dark: Qr.format_bits(Qr.masked(placed, base.function, size, $best), size, $best) })
	}

	## The smallest version (1 to 6) whose level-M capacity holds `count` bytes.
	version_for : U64 -> Try(U64, [TooLong])
	version_for = |count| {
		var $version = 1
		while $version <= 6 {
			shape = Qr.blocks_of($version)
			if (shape.blocks * shape.data * 8 - 12) // 8 >= count {
				return Ok($version)
			}
			$version = $version + 1
		}
		Err(TooLong)
	}

	## Level M's blocks for a version (each block the same size up to version 6): how many, their
	## data codewords, their error correction codewords.
	blocks_of : U64 -> { blocks : U64, data : U64, ec : U64 }
	blocks_of = |version|
		match version {
			1 => { blocks: 1, data: 16, ec: 10 }
			2 => { blocks: 1, data: 28, ec: 16 }
			3 => { blocks: 1, data: 44, ec: 26 }
			4 => { blocks: 2, data: 32, ec: 18 }
			5 => { blocks: 2, data: 43, ec: 24 }
			_ => { blocks: 4, data: 27, ec: 16 }
		}

	## The data codewords: byte mode (0100), the count in 8 bits, the bytes, a terminator, then
	## padding (0xEC, 0x11, …) to `total` codewords.
	data_codewords : List(U8), U64 -> List(U64)
	data_codewords = |bytes, total| {
		var $bits = Qr.bits_of(4, 4).concat(Qr.bits_of(bytes.len(), 8))
		for byte in bytes {
			$bits = $bits.concat(Qr.bits_of(byte.to_u64(), 8))
		}
		capacity = total * 8
		var $terminator = 0
		while $terminator < 4 and $bits.len() < capacity {
			$bits = $bits.append(0)
			$terminator = $terminator + 1
		}
		while $bits.len() % 8 != 0 {
			$bits = $bits.append(0)
		}
		var $out = []
		var $at = 0
		while $at < $bits.len() {
			var $word = 0
			var $i = 0
			while $i < 8 {
				$word = $word * 2 + ($bits.get($at + $i) ?? 0)
				$i = $i + 1
			}
			$out = $out.append($word)
			$at = $at + 8
		}
		var $pad = 0xEC
		while $out.len() < total {
			$out = $out.append($pad)
			$pad = if ($pad == 0xEC) 0x11 else 0xEC
		}
		$out
	}

	## `value`'s low `count` bits, the highest first.
	bits_of : U64, U64 -> List(U64)
	bits_of = |value, count| {
		var $out = []
		var $i = count
		while $i > 0 {
			$i = $i - 1
			$out = $out.append((value // Qr.power_of_two($i)) % 2)
		}
		$out
	}

	power_of_two : U64 -> U64
	power_of_two = |n| {
		var $out = 1
		var $i = 0
		while $i < n {
			$out = $out * 2
			$i = $i + 1
		}
		$out
	}

	## The data split into its blocks, each block's error correction made, and both interleaved:
	## the data codewords a column at a time across the blocks, then the error correction's.
	interleaved : List(U64), { blocks : U64, data : U64, ec : U64 } -> List(U64)
	interleaved = |codewords, shape| {
		generated = Qr.generator(shape.ec)
		var $data_blocks = []
		var $ec_blocks = []
		var $b = 0
		while $b < shape.blocks {
			block = codewords.sublist({ start: $b * shape.data, len: shape.data })
			$data_blocks = $data_blocks.append(block)
			$ec_blocks = $ec_blocks.append(Qr.remainder(block, generated))
			$b = $b + 1
		}
		var $out = []
		var $i = 0
		while $i < shape.data {
			for block in $data_blocks {
				$out = $out.append(block.get($i) ?? 0)
			}
			$i = $i + 1
		}
		$i = 0
		while $i < shape.ec {
			for block in $ec_blocks {
				$out = $out.append(block.get($i) ?? 0)
			}
			$i = $i + 1
		}
		$out
	}

	## Multiplication in GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1 (0x11D).
	multiply : U64, U64 -> U64
	multiply = |x, y| {
		var $z = 0
		var $i = 8
		while $i > 0 {
			$i = $i - 1
			$z = ($z * 2).bitwise_xor(($z // 128) * 0x11D)
			$z = $z.bitwise_xor(((y // Qr.power_of_two($i)) % 2) * x)
		}
		$z
	}

	## The Reed–Solomon generator of `degree`, its coefficients highest first, the leading 1 left out.
	generator : U64 -> List(U64)
	generator = |degree| {
		var $out = Qr.put(List.repeat(0, degree), degree - 1, 1)
		var $root = 1
		var $i = 0
		while $i < degree {
			var $j = 0
			while $j < degree {
				var $value = Qr.multiply($out.get($j) ?? 0, $root)
				if $j + 1 < degree {
					$value = $value.bitwise_xor($out.get($j + 1) ?? 0)
				}
				$out = Qr.put($out, $j, $value)
				$j = $j + 1
			}
			$root = Qr.multiply($root, 2)
			$i = $i + 1
		}
		$out
	}

	## The error correction codewords of `data` (the remainder of its division by `divisor`).
	remainder : List(U64), List(U64) -> List(U64)
	remainder = |data, by| {
		var $out = List.repeat(0, by.len())
		for byte in data {
			factor = byte.bitwise_xor($out.get(0) ?? 0)
			$out = $out.drop_first(1).append(0)
			var $i = 0
			while $i < by.len() {
				$out = Qr.put($out, $i, ($out.get($i) ?? 0).bitwise_xor(Qr.multiply(by.get($i) ?? 0, factor)))
				$i = $i + 1
			}
		}
		$out
	}

	## The finder, timing and alignment patterns, and the format's places (reserved), which data
	## never goes in (`function`).
	function_patterns : U64, U64 -> { dark : List(Bool), function : List(Bool) }
	function_patterns = |version, size| {
		var $dark = List.repeat(Bool.False, size * size)
		var $function = List.repeat(Bool.False, size * size)
		var $i = 0
		while $i < size {
			$dark = Qr.put(Qr.put($dark, 6 * size + $i, $i % 2 == 0), $i * size + 6, $i % 2 == 0)
			$function = Qr.put(Qr.put($function, 6 * size + $i, Bool.True), $i * size + 6, Bool.True)
			$i = $i + 1
		}
		for centre in [(3, 3), (size - 4, 3), (3, size - 4)] {
			(cx, cy) = centre
			var $dy = 0
			while $dy < 9 {
				var $dx = 0
				while $dx < 9 {
					x = cx + $dx
					y = cy + $dy
					if x >= 4 and y >= 4 and x - 4 < size and y - 4 < size {
						ring = Qr.larger(Qr.distance($dx), Qr.distance($dy))
						at = (y - 4) * size + (x - 4)
						$dark = Qr.put($dark, at, ring != 2 and ring != 4)
						$function = Qr.put($function, at, Bool.True)
					}
					$dx = $dx + 1
				}
				$dy = $dy + 1
			}
		}
		if version >= 2 {
			p = 4 * version + 10
			var $dy = 0
			while $dy < 5 {
				var $dx = 0
				while $dx < 5 {
					at = (p + $dy - 2) * size + (p + $dx - 2)
					$dark = Qr.put($dark, at, Qr.larger(Qr.distance_from($dx, 2), Qr.distance_from($dy, 2)) != 1)
					$function = Qr.put($function, at, Bool.True)
					$dx = $dx + 1
				}
				$dy = $dy + 1
			}
		}
		# The format's places, marked now, written with the mask (`format_bits`).
		for at in Qr.format_places(size) {
			$function = Qr.put($function, at, Bool.True)
		}
		{ dark: $dark, function: $function }
	}

	## How far `offset` (0 to 8) is from 4: a finder's rings.
	distance : U64 -> U64
	distance = |offset| Qr.distance_from(offset, 4)

	## A list with `value` at `at` (as it was, past its end).
	put : List(a), U64, a -> List(a)
	put = |list, at, value| list.set(at, value) ?? list

	larger : U64, U64 -> U64
	larger = |a, b| if (a >= b) a else b

	distance_from : U64, U64 -> U64
	distance_from = |offset, centre| if (offset >= centre) offset - centre else centre - offset

	## The format information's 15 places, twice, and the dark module, as indexes (the bit each is
	## for: `format_bits`).
	format_places : U64 -> List(U64)
	format_places = |size| {
		var $out = []
		for at in Qr.format_first(size).concat(Qr.format_second(size)) {
			$out = $out.append(at)
		}
		$out.append((size - 8) * size + 8)
	}

	## The first copy's places, bit 0 first: down column 8 (rows 0 to 5, 7, 8), then along row 8
	## (columns 7, 5, 4, …, 0).
	format_first : U64 -> List(U64)
	format_first = |size| {
		at = |x, y| y * size + x
		[at(8, 0), at(8, 1), at(8, 2), at(8, 3), at(8, 4), at(8, 5), at(8, 7), at(8, 8), at(7, 8), at(5, 8), at(4, 8), at(3, 8), at(2, 8), at(1, 8), at(0, 8)]
	}

	## The second copy's places, bit 0 first: along row 8 from the right, then up column 8.
	format_second : U64 -> List(U64)
	format_second = |size| {
		var $out = []
		var $i = 0
		while $i < 8 {
			$out = $out.append(8 * size + (size - 1 - $i))
			$i = $i + 1
		}
		while $i < 15 {
			$out = $out.append((size - 15 + $i) * size + 8)
			$i = $i + 1
		}
		$out
	}

	## The data's bits, in the zigzag two columns wide from the bottom right, past the patterns.
	place : { dark : List(Bool), function : List(Bool) }, List(U64), U64 -> List(Bool)
	place = |base, codewords, size| {
		var $dark = base.dark
		var $i = 0
		total = codewords.len() * 8
		var $right = size - 1
		while $right >= 1 {
			if $right == 6 {
				$right = 5
			}
			var $vert = 0
			while $vert < size {
				var $j = 0
				while $j < 2 {
					x = $right - $j
					upward = ($right + 1) // 2 % 2 == 0
					y = if (upward) size - 1 - $vert else $vert
					at = y * size + x
					if !(base.function.get(at) ?? Bool.True) and $i < total {
						word = codewords.get($i // 8) ?? 0
						$dark = Qr.put($dark, at, (word // Qr.power_of_two(7 - $i % 8)) % 2 == 1)
						$i = $i + 1
					}
					$j = $j + 1
				}
				$vert = $vert + 1
			}
			$right = if ($right >= 2) $right - 2 else 0
		}
		$dark
	}

	## The data's modules with mask `mask` applied (the patterns' left as they are).
	masked : List(Bool), List(Bool), U64, U64 -> List(Bool)
	masked = |dark, function, size, mask| {
		var $out = dark
		var $y = 0
		while $y < size {
			var $x = 0
			while $x < size {
				at = $y * size + $x
				if !(function.get(at) ?? Bool.True) and Qr.flips(mask, $x, $y) {
					$out = Qr.put($out, at, !($out.get(at) ?? Bool.False))
				}
				$x = $x + 1
			}
			$y = $y + 1
		}
		$out
	}

	## Whether mask `mask` flips the module at column `x`, row `y`.
	flips : U64, U64, U64 -> Bool
	flips = |mask, x, y|
		match mask {
			0 => (x + y) % 2 == 0
			1 => y % 2 == 0
			2 => x % 3 == 0
			3 => (x + y) % 3 == 0
			4 => (x // 3 + y // 2) % 2 == 0
			5 => (x * y) % 2 + (x * y) % 3 == 0
			6 => ((x * y) % 2 + (x * y) % 3) % 2 == 0
			_ => ((x + y) % 2 + (x * y) % 3) % 2 == 0
		}

	## The format information written: level M (00) and the mask, with its BCH bits, XOR 0x5412,
	## in both copies; and the dark module.
	format_bits : List(Bool), U64, U64 -> List(Bool)
	format_bits = |dark, size, mask| {
		bits = Qr.format_word(mask)
		var $out = dark
		for places in [Qr.format_first(size), Qr.format_second(size)] {
			var $i = 0
			for at in places {
				$out = Qr.put($out, at, (bits // Qr.power_of_two($i)) % 2 == 1)
				$i = $i + 1
			}
		}
		Qr.put($out, (size - 8) * size + 8, Bool.True)
	}

	## Level M's 15 format bits for `mask`.
	format_word : U64 -> U64
	format_word = |mask| {
		data = mask
		var $rem = data
		var $i = 0
		while $i < 10 {
			$rem = ($rem * 2).bitwise_xor(($rem // 512) * 0x537)
			$i = $i + 1
		}
		(data * 1024 + $rem % 1024).bitwise_xor(0x5412)
	}

	## The standard's penalty of a masked code (lower is easier to read): runs of five or more, 2×2
	## blocks of one colour, finder-like stretches, and how far dark is from half.
	penalty_of : List(Bool), U64 -> U64
	penalty_of = |dark, size| {
		cell = |x, y| dark.get(y * size + x) ?? Bool.False
		var $score = 0
		var $line = 0
		while $line < size {
			for across in [Bool.True, Bool.False] {
				var $run = 1
				var $i = 1
				while $i < size {
					if Qr.read(dark, size, across, $line, $i) == Qr.read(dark, size, across, $line, $i - 1) {
						$run = $run + 1
						if $run == 5 {
							$score = $score + 3
						} else if $run > 5 {
							$score = $score + 1
						}
					} else {
						$run = 1
					}
					$i = $i + 1
				}
				var $start = 0
				while $start + 11 <= size {
					var $window = []
					var $k = 0
					while $k < 11 {
						$window = $window.append(if (Qr.read(dark, size, across, $line, $start + $k)) 1 else 0)
						$k = $k + 1
					}
					if $window == [1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0] or $window == [0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1] {
						$score = $score + 40
					}
					$start = $start + 1
				}
			}
			$line = $line + 1
		}
		var $y = 0
		while $y + 1 < size {
			var $x = 0
			while $x + 1 < size {
				c = cell($x, $y)
				if c == cell($x + 1, $y) and c == cell($x, $y + 1) and c == cell($x + 1, $y + 1) {
					$score = $score + 3
				}
				$x = $x + 1
			}
			$y = $y + 1
		}
		count = dark.keep_if(|is_dark| is_dark).len()
		total = size * size
		percent = count * 100 // total
		off = if (percent >= 50) percent - 50 else 50 - percent
		$score + off // 5 * 10
	}

	## The module `i` along line `line`: across a row, or down a column.
	read : List(Bool), U64, Bool, U64, U64 -> Bool
	read = |dark, size, across, line, i| {
		at = if (across) line * size + i else i * size + line
		dark.get(at) ?? Bool.False
	}

	## The code for a terminal: two rows of modules a line (half blocks), each in its own colour
	## (black on bright white, whatever the terminal's), inside a quiet zone of four.
	terminal : { size : U64, dark : List(Bool) } -> Str
	terminal = |code| {
		quiet = 4
		side = code.size + 2 * quiet
		cell = |x, y|
			if x < quiet or y < quiet or x >= code.size + quiet or y >= code.size + quiet {
				Bool.False
			} else {
				code.dark.get((y - quiet) * code.size + (x - quiet)) ?? Bool.False
			}
		var $lines = []
		var $y = 0
		while $y < side {
			var $line = ""
			var $colours = ""
			var $x = 0
			while $x < side {
				top = cell($x, $y)
				bottom = $y + 1 < side and cell($x, $y + 1)
				fg = if (top) "30" else "97"
				bg = if (bottom) "40" else "107"
				# A colour said once for a run of cells that have it.
				colours = "\u(1b)[${fg};${bg}m"
				if colours != $colours {
					$line = $line.concat(colours)
					$colours = colours
				}
				$line = $line.concat("▀")
				$x = $x + 1
			}
			$lines = $lines.append($line.concat("\u(1b)[0m"))
			$y = $y + 2
		}
		Str.join_with($lines, "\n")
	}

	## The code as a PBM image (`P1`), a module a pixel, quiet zone included: for tests, which
	## decode it with a reader (zbar).
	pbm : { size : U64, dark : List(Bool) } -> Str
	pbm = |code| {
		quiet = 4
		side = code.size + 2 * quiet
		var $rows = ["P1", "${side.to_str()} ${side.to_str()}"]
		var $y = 0
		while $y < side {
			var $row = []
			var $x = 0
			while $x < side {
				inside = $x >= quiet and $y >= quiet and $x < code.size + quiet and $y < code.size + quiet
				is_dark = inside and (code.dark.get(($y - quiet) * code.size + ($x - quiet)) ?? Bool.False)
				$row = $row.append(if (is_dark) "1" else "0")
				$x = $x + 1
			}
			$rows = $rows.append(Str.join_with($row, " "))
			$y = $y + 1
		}
		Str.join_with($rows, "\n").concat("\n")
	}
}

# Level M, mask 0: data 0, so the format bits are the XOR mask alone.
expect Qr.format_word(0) == 0x5412
expect Qr.multiply(2, 0x80) == 0x1D
expect Qr.version_for(14) == Ok(1) and Qr.version_for(15) == Ok(2) and Qr.version_for(106) == Ok(6) and Qr.version_for(107) == Err(TooLong)
expect Qr.generator(2) == [3, 2]
