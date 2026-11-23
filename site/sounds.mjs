#!/usr/bin/env node
// The showcase's sound files: short chiptune notes, synthesized here and written as WAV to
// site/static/sounds/, which the demos play with `Audio.play!` (packages/audio). Any file the browser can play
// would do as well; these are made, not recorded, so they are this script, and small.
//
//   node site/sounds.mjs
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const out = join(dirname(fileURLToPath(import.meta.url)), "static", "sounds");
const RATE = 22050;

// Each: its wave, how loud at its peak, and its notes, [hertz, seconds], each starting at 90% of
// the one before. The pop and the bonk are made at a pitch the flock plays them faster or slower
// from (its `rate`): 440 Hz, and 220.
const SOUNDS = {
	start: { wave: "square", peak: 0.04, notes: [[523, 0.07], [784, 0.12]] },
	eat: { wave: "square", peak: 0.04, notes: [[880, 0.05], [1175, 0.08]] },
	level: { wave: "square", peak: 0.04, notes: [[784, 0.06], [988, 0.06], [1319, 0.12]] },
	die: { wave: "square", peak: 0.04, notes: [[392, 0.12], [262, 0.14], [131, 0.32]] },
	pop: { wave: "triangle", peak: 0.04, notes: [[440, 0.05], [660, 0.08]] },
	bonk: { wave: "triangle", peak: 0.05, notes: [[220, 0.05]] },
};

/** A wave at `hz`, `t` seconds in, from its harmonics below the Nyquist frequency (no aliasing). */
function wave(kind, hz, t) {
	let value = 0;
	for (let k = 0; ; k++) {
		const n = 2 * k + 1;
		if (n * hz >= RATE / 2) break;
		const phase = 2 * Math.PI * n * hz * t;
		value += kind === "square" ? (4 / Math.PI) * (Math.sin(phase) / n) : (8 / Math.PI ** 2) * ((k % 2 ? -1 : 1) * Math.sin(phase)) / (n * n);
	}
	return value;
}

/** A note's loudness, `t` seconds into it: up from silence in 10 ms, then down over the rest. */
function envelope(peak, length, t) {
	const quiet = 0.0001;
	if (t < 0 || t > length) return 0;
	if (t < 0.01) return quiet * (peak / quiet) ** (t / 0.01);
	return peak * (quiet / peak) ** ((t - 0.01) / (length - 0.01));
}

function render({ wave: kind, peak, notes }) {
	let at = 0;
	const placed = notes.map(([hz, length]) => {
		const note = { hz, length, at };
		at += length * 0.9;
		return note;
	});
	const seconds = Math.max(...placed.map((note) => note.at + note.length)) + 0.02;
	const samples = new Int16Array(Math.ceil(seconds * RATE));
	for (let i = 0; i < samples.length; i++) {
		const t = i / RATE;
		let value = 0;
		for (const note of placed) value += envelope(peak, note.length, t - note.at) * wave(kind, note.hz, t - note.at);
		samples[i] = Math.max(-32768, Math.min(32767, Math.round(value * 32767)));
	}
	return samples;
}

/** 16-bit mono PCM, as a WAV file. */
function wav(samples) {
	const data = Buffer.from(samples.buffer);
	const header = Buffer.alloc(44);
	header.write("RIFF", 0);
	header.writeUInt32LE(36 + data.length, 4);
	header.write("WAVEfmt ", 8);
	header.writeUInt32LE(16, 16);
	header.writeUInt16LE(1, 20);
	header.writeUInt16LE(1, 22);
	header.writeUInt32LE(RATE, 24);
	header.writeUInt32LE(RATE * 2, 28);
	header.writeUInt16LE(2, 32);
	header.writeUInt16LE(16, 34);
	header.write("data", 36);
	header.writeUInt32LE(data.length, 40);
	return Buffer.concat([header, data]);
}

mkdirSync(out, { recursive: true });
for (const [name, sound] of Object.entries(SOUNDS)) {
	const file = join(out, `${name}.wav`);
	writeFileSync(file, wav(render(sound)));
	console.log(`site/static/sounds/${name}.wav`);
}
