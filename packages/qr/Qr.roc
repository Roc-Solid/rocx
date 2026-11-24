## QR codes in plain Roc: text in, a code's modules out (`encode`), and the code drawn as SVG
## (`svg`, or `path` for markup of your own), for a terminal (`terminal`) or as a PBM image (`pbm`).
## Byte mode (UTF-8), versions 1 to 40, the four error correction levels, and the mask the
## standard's penalty rules choose. ISO/IEC 18004; the steps follow Project Nayuki's reference
## encoder.
Qr := [].{

	## How much of a code may be damaged and still read: about 7% (`Low`), 15% (`Medium`), 25%
	## (`Quartile`) or 30% (`High`). The more it may, the bigger the code for the same text.
	Level : [Low, Medium, Quartile, High]

	## A code: its side, in modules, and its modules row by row, dark `Bool.True`. The quiet zone
	## around it (four modules) isn't in it; the renderers add it.
	Code : { size : U64, dark : List(Bool) }

	## `text` (its UTF-8 bytes) as a code at `level`, the smallest version that holds it; or why there
	## is none: more than the biggest holds (2,953 bytes at `Low`, 2,331 at `Medium`, 1,663 at
	## `Quartile`, 1,273 at `High`: `capacity`).
	encode : Str, Level -> Try(Code, [TooLong])
	encode = |text, level| {
		bytes = text.to_utf8()
		version =
			match Qr.version_for(bytes.len(), level) {
				Ok(found) => found
				Err(_) => return Err(TooLong)
			}
		codewords = Qr.interleaved(Qr.data_codewords(bytes, version, level), version, level)
		size = 17 + 4 * version
		base = Qr.function_patterns(version, size)
		placed = Qr.place(base, codewords, size)
		var $best = 0
		var $lowest = 0
		var $mask = 0
		while $mask < 8 {
			trial = Qr.format_bits(Qr.masked(placed, base.function, size, $mask), size, level, $mask)
			score = Qr.penalty_of(trial, size)
			if $mask == 0 or score < $lowest {
				$best = $mask
				$lowest = score
			}
			$mask = $mask + 1
		}
		Ok({ size, dark: Qr.format_bits(Qr.masked(placed, base.function, size, $best), size, level, $best) })
	}

	## The most bytes a code at `level` holds (version 40).
	capacity : Level -> U64
	capacity = |level| Qr.bytes_held(40, level)

	## Whether the module at column `x`, row `y` is dark (outside the code: light, the quiet zone).
	is_dark : Code, U64, U64 -> Bool
	is_dark = |code, x, y| if (x < code.size and y < code.size) code.dark.get(y * code.size + x) ?? Bool.False else Bool.False

	# ---- Drawing ----

	## The code as an SVG image, black on white, a module a unit, with its quiet zone: size it with
	## CSS or `width`/`height` (it stays square), and keep it black on white for readers.
	svg : Code -> Str
	svg = |code| {
		side = (code.size + 8).to_str()
		"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 ${side} ${side}\" shape-rendering=\"crispEdges\"><rect width=\"${side}\" height=\"${side}\" fill=\"#fff\"/><path d=\"${Qr.path(code)}\" fill=\"#000\"/></svg>"
	}

	## The `viewBox` of `path`'s drawing: the code and its quiet zone, `0 0 <side> <side>`.
	view_box : Code -> Str
	view_box = |code| {
		side = (code.size + 8).to_str()
		"0 0 ${side} ${side}"
	}

	## The dark modules as one SVG path's `d`, a module a unit, offset by the quiet zone (four):
	## for an `<svg viewBox={Qr.view_box(code)}>` of your own. Each row's runs of dark modules are a
	## rectangle each.
	path : Code -> Str
	path = |code| {
		var $out = []
		var $y = 0
		while $y < code.size {
			var $x = 0
			while $x < code.size {
				if Qr.is_dark(code, $x, $y) {
					var $run = 1
					while Qr.is_dark(code, $x + $run, $y) {
						$run = $run + 1
					}
					$out = $out.append("M${($x + 4).to_str()} ${($y + 4).to_str()}h${$run.to_str()}v1h-${$run.to_str()}z")
					$x = $x + $run
				} else {
					$x = $x + 1
				}
			}
			$y = $y + 1
		}
		Str.join_with($out, "")
	}

	## The code for a terminal: two rows of modules a line (half blocks), each in its colour by ANSI
	## escapes (black on bright white, whatever the terminal's own), with its quiet zone.
	terminal : Code -> Str
	terminal = |code| {
		side = code.size + 8
		cell = |x, y| x >= 4 and y >= 4 and Qr.is_dark(code, x - 4, y - 4)
		var $lines = []
		var $y = 0
		while $y < side {
			var $line = ""
			var $colours = ""
			var $x = 0
			while $x < side {
				fg = if (cell($x, $y)) "30" else "97"
				bg = if ($y + 1 < side and cell($x, $y + 1)) "40" else "107"
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

	## The code as a PBM image (`P1`), a module a pixel, with its quiet zone: for a reader to check
	## it (packages/qr/test/decode.sh, with zbar).
	pbm : Code -> Str
	pbm = |code| {
		side = code.size + 8
		var $rows = ["P1", "${side.to_str()} ${side.to_str()}"]
		var $y = 0
		while $y < side {
			var $row = []
			var $x = 0
			while $x < side {
				$row = $row.append(if ($x >= 4 and $y >= 4 and Qr.is_dark(code, $x - 4, $y - 4)) "1" else "0")
				$x = $x + 1
			}
			$rows = $rows.append(Str.join_with($row, " "))
			$y = $y + 1
		}
		Str.join_with($rows, "\n").concat("\n")
	}

	# ---- Sizes ----

	## The smallest version (1 to 40) that holds `count` bytes at `level`.
	version_for : U64, Level -> Try(U64, [TooLong])
	version_for = |count, level| {
		var $version = 1
		while $version <= 40 {
			if Qr.bytes_held($version, level) >= count {
				return Ok($version)
			}
			$version = $version + 1
		}
		Err(TooLong)
	}

	## The bytes a version holds at a level: its data codewords' bits, less the mode (4) and the count
	## (8 bits up to version 9, 16 after).
	bytes_held : U64, Level -> U64
	bytes_held = |version, level| (Qr.data_codewords_of(version, level) * 8 - 4 - Qr.count_bits(version)) // 8

	count_bits : U64 -> U64
	count_bits = |version| if (version <= 9) 8 else 16

	## The modules a version has for data and error correction: all but its patterns and format and
	## version information.
	raw_modules : U64 -> U64
	raw_modules = |version| {
		all = (16 * version + 128) * version + 64
		if version < 2 {
			all
		} else {
			aligned = version // 7 + 2
			less = (25 * aligned - 10) * aligned - 55
			if (version >= 7) all - less - 36 else all - less
		}
	}

	## The data codewords of a version at a level: its codewords, less its blocks' error correction.
	data_codewords_of : U64, Level -> U64
	data_codewords_of = |version, level| Qr.raw_modules(version) // 8 - Qr.ec_per_block(version, level) * Qr.block_count(version, level)

	## Each block's error correction codewords (ISO/IEC 18004, table 9), by version.
	ec_per_block : U64, Level -> U64
	ec_per_block = |version, level| {
		table =
			match level {
				Low => [0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30]
				Medium => [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28]
				Quartile => [0, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30]
				High => [0, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30]
			}
		table.get(version) ?? 0
	}

	## How many blocks the codewords are split into (ISO/IEC 18004, table 9), by version.
	block_count : U64, Level -> U64
	block_count = |version, level| {
		table =
			match level {
				Low => [0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25]
				Medium => [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49]
				Quartile => [0, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68]
				High => [0, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81]
			}
		table.get(version) ?? 1
	}

	# ---- Codewords ----

	## The data codewords: byte mode (0100), the count, the bytes, a terminator, then padding (0xEC,
	## 0x11, …) to the version's data codewords.
	data_codewords : List(U8), U64, Level -> List(U64)
	data_codewords = |bytes, version, level| {
		total = Qr.data_codewords_of(version, level)
		var $bits = Qr.bits_of(4, 4).concat(Qr.bits_of(bytes.len(), Qr.count_bits(version)))
		for byte in bytes {
			$bits = $bits.concat(Qr.bits_of(byte.to_u64(), 8))
		}
		var $terminator = 0
		while $terminator < 4 and $bits.len() < total * 8 {
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

	## The data split into blocks (the first ones a codeword shorter when they don't divide evenly),
	## each block's error correction made, and all of it interleaved: the data a codeword of each
	## block at a time, then the error correction the same way.
	interleaved : List(U64), U64, Level -> List(U64)
	interleaved = |data, version, level| {
		blocks = Qr.block_count(version, level)
		ec = Qr.ec_per_block(version, level)
		raw = Qr.raw_modules(version) // 8
		short_blocks = blocks - raw % blocks
		short_length = raw // blocks
		generated = Qr.generator(ec)
		var $data_blocks = []
		var $ec_blocks = []
		var $taken = 0
		var $b = 0
		while $b < blocks {
			length = short_length - ec + (if ($b < short_blocks) 0 else 1)
			block = data.sublist({ start: $taken, len: length })
			$taken = $taken + length
			$data_blocks = $data_blocks.append(block)
			$ec_blocks = $ec_blocks.append(Qr.remainder(block, generated))
			$b = $b + 1
		}
		var $out = []
		var $i = 0
		while $i <= short_length - ec {
			for block in $data_blocks {
				match block.get($i) {
					Ok(word) => {
						$out = $out.append(word)
					}
					Err(_) => {}
				}
			}
			$i = $i + 1
		}
		$i = 0
		while $i < ec {
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

	## The error correction codewords of `data`: the remainder of its division by the generator.
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

	# ---- Modules ----

	## The finder, timing and alignment patterns, the version information (version 7 up), and the
	## format's places (reserved, written with the mask): the modules data never goes in (`function`).
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
						ring = Qr.larger(Qr.distance_from($dx, 4), Qr.distance_from($dy, 4))
						at = (y - 4) * size + (x - 4)
						$dark = Qr.put($dark, at, ring != 2 and ring != 4)
						$function = Qr.put($function, at, Bool.True)
					}
					$dx = $dx + 1
				}
				$dy = $dy + 1
			}
		}
		positions = Qr.alignment_positions(version, size)
		last = positions.len()
		var $p = 0
		while $p < last {
			var $q = 0
			while $q < last {
				# Not where a finder is.
				corner = ($p == 0 and $q == 0) or ($p == 0 and $q + 1 == last) or ($p + 1 == last and $q == 0)
				if !corner {
					cx = positions.get($p) ?? 0
					cy = positions.get($q) ?? 0
					var $dy = 0
					while $dy < 5 {
						var $dx = 0
						while $dx < 5 {
							at = (cy + $dy - 2) * size + (cx + $dx - 2)
							$dark = Qr.put($dark, at, Qr.larger(Qr.distance_from($dx, 2), Qr.distance_from($dy, 2)) != 1)
							$function = Qr.put($function, at, Bool.True)
							$dx = $dx + 1
						}
						$dy = $dy + 1
					}
				}
				$q = $q + 1
			}
			$p = $p + 1
		}
		if version >= 7 {
			bits = Qr.version_word(version)
			var $k = 0
			while $k < 18 {
				is_on = (bits // Qr.power_of_two($k)) % 2 == 1
				a = size - 11 + $k % 3
				b = $k // 3
				$dark = Qr.put(Qr.put($dark, b * size + a, is_on), a * size + b, is_on)
				$function = Qr.put(Qr.put($function, b * size + a, Bool.True), a * size + b, Bool.True)
				$k = $k + 1
			}
		}
		for at in Qr.format_first(size).concat(Qr.format_second(size)).append((size - 8) * size + 8) {
			$function = Qr.put($function, at, Bool.True)
		}
		{ dark: $dark, function: $function }
	}

	## The alignment patterns' centres along each axis: none for version 1, else 6 and evenly
	## spaced positions out to `size - 7`.
	alignment_positions : U64, U64 -> List(U64)
	alignment_positions = |version, size| {
		if version == 1 {
			return []
		}
		count = version // 7 + 2
		step = (version * 8 + count * 3 + 5) // (count * 4 - 4) * 2
		var $out = []
		var $i = count - 1
		while $i > 0 {
			$i = $i - 1
			$out = $out.append(size - 7 - $i * step)
		}
		[6].concat($out)
	}

	## The 18 bits of version information: the version, and its BCH(18, 6) remainder.
	version_word : U64 -> U64
	version_word = |version| {
		var $rem = version
		var $i = 0
		while $i < 12 {
			$rem = ($rem * 2).bitwise_xor(($rem // 2048) * 0x1F25)
			$i = $i + 1
		}
		version * 4096 + $rem % 4096
	}

	## A list with `value` at `at` (as it was, past its end).
	put : List(a), U64, a -> List(a)
	put = |list, at, value| list.set(at, value) ?? list

	larger : U64, U64 -> U64
	larger = |a, b| if (a >= b) a else b

	distance_from : U64, U64 -> U64
	distance_from = |offset, centre| if (offset >= centre) offset - centre else centre - offset

	## The first copy of the format information's places, bit 0 first: down column 8 (rows 0 to 5,
	## 7, 8), then along row 8 (columns 7, 5, 4, …, 0).
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

	## The format information written (the level, the mask, their BCH bits, XOR 0x5412) in both
	## copies, and the dark module.
	format_bits : List(Bool), U64, Level, U64 -> List(Bool)
	format_bits = |dark, size, level, mask| {
		bits = Qr.format_word(level, mask)
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

	## The 15 format bits for a level and a mask.
	format_word : Level, U64 -> U64
	format_word = |level, mask| {
		level_bits =
			match level {
				Low => 1
				Medium => 0
				Quartile => 3
				High => 2
			}
		data = level_bits * 8 + mask
		var $rem = data
		var $i = 0
		while $i < 10 {
			$rem = ($rem * 2).bitwise_xor(($rem // 512) * 0x537)
			$i = $i + 1
		}
		(data * 1024 + $rem % 1024).bitwise_xor(0x5412)
	}

	## The standard's penalty of a masked code (lower reads more easily): runs of five or more of a
	## colour, 2×2 blocks of one, stretches that look like a finder, and how far dark is from half.
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
					if Qr.finder_like(dark, size, across, $line, $start) {
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
		count = dark.keep_if(|is_on| is_on).len()
		percent = count * 100 // (size * size)
		off = if (percent >= 50) percent - 50 else 50 - percent
		$score + off // 5 * 10
	}

	## Whether the 11 modules from `start` along a line are 1:1:3:1:1 dark and light, then 4 light
	## (or the other way round): what a finder looks like to a reader.
	finder_like : List(Bool), U64, Bool, U64, U64 -> Bool
	finder_like = |dark, size, across, line, start| {
		forward = [Bool.True, Bool.False, Bool.True, Bool.True, Bool.True, Bool.False, Bool.True, Bool.False, Bool.False, Bool.False, Bool.False]
		var $ahead = Bool.True
		var $behind = Bool.True
		var $k = 0
		while $k < 11 {
			here = Qr.read(dark, size, across, line, start + $k)
			if here != (forward.get($k) ?? Bool.False) {
				$ahead = Bool.False
			}
			if here != (forward.get(10 - $k) ?? Bool.False) {
				$behind = Bool.False
			}
			$k = $k + 1
		}
		$ahead or $behind
	}

	## The module `i` along line `line`: across a row, or down a column.
	read : List(Bool), U64, Bool, U64, U64 -> Bool
	read = |dark, size, across, line, i| {
		at = if (across) line * size + i else i * size + line
		dark.get(at) ?? Bool.False
	}
}

# The tables and formulas, against the standard's numbers.
expect Qr.format_word(Medium, 0) == 0x5412
expect Qr.format_word(Low, 0) == 0x77C4
expect Qr.version_word(7) == 0x07C94
expect Qr.multiply(2, 0x80) == 0x1D
expect Qr.generator(2) == [3, 2]
expect Qr.raw_modules(1) == 208 and Qr.raw_modules(7) == 1568 and Qr.raw_modules(40) == 29648
expect Qr.alignment_positions(7, 45) == [6, 22, 38]
expect Qr.alignment_positions(40, 177) == [6, 30, 58, 86, 114, 142, 170]
expect Qr.bytes_held(1, Low) == 17 and Qr.bytes_held(1, Medium) == 14 and Qr.bytes_held(1, Quartile) == 11 and Qr.bytes_held(1, High) == 7
expect Qr.capacity(Low) == 2953 and Qr.capacity(Medium) == 2331 and Qr.capacity(Quartile) == 1663 and Qr.capacity(High) == 1273
expect Qr.version_for(14, Medium) == Ok(1) and Qr.version_for(15, Medium) == Ok(2) and Qr.version_for(2332, Medium) == Err(TooLong)
expect
	match Qr.encode("hi", Medium) {
		Ok(code) => code.size == 21 and Qr.view_box(code) == "0 0 29 29" and Qr.svg(code).starts_with("<svg ")
		Err(_) => Bool.False
	}
expect Qr.encode(Str.join_with(List.repeat("x", 2954), ""), Low) == Err(TooLong)
