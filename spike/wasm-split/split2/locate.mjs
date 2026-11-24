// Where each of the object's data segments is in the final module, found by content. The final link
// (2026-11-24, fork 4674b5973d) drops unreferenced data and reorders the static data (payloads
// `roc__dN_1` apart from their cells `roc__dN`), so "object offset + one base" holds only for the
// first 47 KB. Each segment is looked for in the final image: its longest run of bytes no
// relocation covers, then the whole segment checked there; a segment found at exactly one place is
// placed. Rounds repeat with relocated words written in where their target is placed (a 4-byte cell
// is found by the address it holds). What stays unplaced has nothing to tell it by, or more than one
// place (then it's dropped or merged as far as references go).
import { relocationsOf } from "./wasm.mjs";

export function locate(object, wasm, symbols) {
	const low = Math.min(...wasm.segments.map((s) => s.offset));
	const high = Math.max(...wasm.segments.map((s) => s.offset + s.size));
	const image = Buffer.alloc(high - low + 64);
	for (const s of wasm.segments) Buffer.from(s.bytes).copy(image, s.offset - low);
	const n = object.segments.length;
	const relocs = object.segments.map(() => []);
	const segStarts = object.segments.map((s) => s.start);
	for (const reloc of relocationsOf(object)) {
		if (reloc.target !== object.dataIndex) continue;
		let lo = 0;
		let hi = n - 1;
		while (lo < hi) {
			const mid = (lo + hi + 1) >> 1;
			if (segStarts[mid] <= reloc.offset) lo = mid;
			else hi = mid - 1;
		}
		relocs[lo].push({ at: reloc.offset - segStarts[lo], type: reloc.type, symbol: reloc.index, addend: reloc.addend, width: [14, 15, 16, 17, 21, 22].includes(reloc.type) ? 8 : 4 });
	}
	const final = new Array(n).fill(null);
	const ambiguous = new Set();
	const occurrences = (needle, cap = 64) => {
		const out = [];
		for (let from = 0; out.length < cap; ) {
			const found = image.indexOf(needle, from);
			if (found < 0) break;
			out.push(found);
			from = found + 1;
		}
		return out;
	};
	let tieBreak = false;
	for (let round = 0; round < 40; round++) {
		let progress = 0;
		for (let i = 0; i < n; i++) {
			if (final[i] !== null) continue;
			const segment = object.segments[i];
			if (!segment.size) continue;
			const expected = Buffer.from(segment.bytes);
			const masked = new Uint8Array(segment.size);
			for (const r of relocs[i]) {
				const symbol = symbols[r.symbol];
				const target = symbol && symbol.kind === "d" && !symbol.undefined ? final[symbol.segment] : null;
				if (r.type === 5 && target !== null && r.at + 4 <= segment.size) expected.writeUInt32LE((target + symbol.offset + r.addend) >>> 0, r.at);
				else masked.fill(1, r.at, Math.min(segment.size, r.at + r.width));
			}
			// The longest run of unmasked bytes with something other than zeros in it.
			let best = null;
			for (let k = 0; k < segment.size; ) {
				if (masked[k]) {
					k++;
					continue;
				}
				let end = k;
				while (end < segment.size && !masked[end]) end++;
				const run = expected.subarray(k, end);
				if (run.some((b) => b) && (!best || run.length > best.length)) best = { at: k, length: run.length };
				k = end;
			}
			if (!best || best.length < 4) continue;
			const places = occurrences(expected.subarray(best.at, best.at + best.length))
				.map((found) => found - best.at)
				.filter((start) => {
					if (start < 0) return false;
					for (let k = 0; k < segment.size; k++) if (!masked[k] && image[start + k] !== expected[k]) return false;
					return true;
				});
			if (places.length === 1) {
				final[i] = places[0] + low;
				ambiguous.delete(i);
				progress++;
			} else if (places.length > 1) {
				// More than one place: in a tie-breaking round, the one nearest to where the closest placed
				// segment before it in the object puts it (the final link keeps runs of the object's order).
				ambiguous.add(i);
				if (tieBreak) {
					let p = i - 1;
					while (p >= 0 && final[p] === null) p--;
					if (p >= 0) {
						const guess = final[p] + (object.segments[i].offset - object.segments[p].offset) - low;
						const nearest = places.reduce((a, b) => (Math.abs(b - guess) < Math.abs(a - guess) ? b : a));
						if (Math.abs(nearest - guess) <= 64) {
							final[i] = nearest + low;
							ambiguous.delete(i);
							progress++;
						}
					}
				}
			}
		}
		if (!progress) {
			if (tieBreak) break;
			tieBreak = true;
		}
	}
	// Coverage of the final image's non-zero bytes by placed segments.
	const covered = new Uint8Array(image.length);
	for (let i = 0; i < n; i++) if (final[i] !== null) covered.fill(1, final[i] - low, final[i] - low + object.segments[i].size);
	let nonzero = 0;
	let hit = 0;
	for (let k = 0; k < high - low; k++) if (image[k]) {
		nonzero++;
		if (covered[k]) hit++;
	}
	const placed = final.filter((f) => f !== null).length;
	return { final, stats: { placed, ambiguous: ambiguous.size, unplaced: n - placed, placedBytes: object.segments.reduce((a, s, i) => a + (final[i] !== null ? s.size : 0), 0), coverage: +(hit / nonzero).toFixed(4) } };
}
