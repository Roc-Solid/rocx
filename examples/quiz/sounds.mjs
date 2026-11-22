#!/usr/bin/env node
// Pinwheel's sounds: a few short notes, synthesized here and written as WAV files into
// static/sounds/, which the pages play with `Audio.play!`. They are made, not recorded, so they are
// this script, and small; run it again after changing one.
//
//   node examples/quiz/sounds.mjs
//
// Two voices. A marimba-like mallet (a sine with a quieter, faster-dying overtone at four times its
// pitch, struck hard and ringing out) for the clock's ticks, a pick, a join and the good news. A
// soft reed (a sine bent by another, frequency modulation, sliding down) for the bad news.
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const out = join(dirname(fileURLToPath(import.meta.url)), "static", "sounds");
const RATE = 22050;

// Each sound: its notes, [voice, hertz, seconds, when, loudness].
const SOUNDS = {
	// The clock's last seconds, on the host's screen: a dry knock, and a higher one for the very last.
	tick: [["mallet", 1046, 0.09, 0, 0.35]],
	tock: [["mallet", 1568, 0.12, 0, 0.4]],
	// A player's choice, sent.
	pick: [["mallet", 659, 0.1, 0, 0.3], ["mallet", 988, 0.14, 0.05, 0.25]],
	// Someone joined the lobby.
	join: [["mallet", 784, 0.12, 0, 0.25], ["mallet", 1175, 0.18, 0.07, 0.22]],
	// The question opens.
	go: [["mallet", 523, 0.12, 0, 0.3], ["mallet", 659, 0.12, 0.08, 0.3], ["mallet", 784, 0.22, 0.16, 0.32]],
	// Right: up a bright arpeggio.
	right: [["mallet", 784, 0.14, 0, 0.32], ["mallet", 988, 0.14, 0.08, 0.32], ["mallet", 1175, 0.16, 0.16, 0.32], ["mallet", 1568, 0.32, 0.24, 0.3]],
	// Wrong: a reed that sags.
	wrong: [["reed", 311, 0.22, 0, 0.3, -0.12], ["reed", 233, 0.4, 0.18, 0.3, -0.2]],
	// The podium.
	podium: [
		["mallet", 523, 0.16, 0, 0.3],
		["mallet", 659, 0.16, 0.12, 0.3],
		["mallet", 784, 0.16, 0.24, 0.3],
		["mallet", 1046, 0.2, 0.36, 0.32],
		["mallet", 784, 0.14, 0.56, 0.26],
		["mallet", 1046, 0.6, 0.68, 0.34],
	],
};

/** A note's sample at `t` seconds in: its voice, its pitch, how long it rings. */
function voice(kind, hz, length, t, slide = 0) {
	if (t < 0 || t > length) return 0;
	if (kind === "mallet") {
		// Struck: up in 2 ms, then dying away, the overtone four times as fast.
		const attack = Math.min(1, t / 0.002);
		const body = Math.exp((-5 * t) / length);
		const bright = Math.exp((-20 * t) / length);
		return attack * (body * Math.sin(2 * Math.PI * hz * t) + 0.35 * bright * Math.sin(2 * Math.PI * hz * 4 * t));
	}
	// A reed: its pitch sliding by `slide` (a share of it) over its length, a sine bending another.
	const attack = Math.min(1, t / 0.02);
	const release = Math.min(1, (length - t) / 0.06);
	const pitch = hz * (1 + slide * (t / length));
	const phase = 2 * Math.PI * pitch * t;
	return attack * release * Math.sin(phase + 1.6 * Math.exp(-3 * t) * Math.sin(phase * 2));
}

function render(notes) {
	const seconds = Math.max(...notes.map(([, , length, when]) => when + length)) + 0.02;
	const samples = new Int16Array(Math.ceil(seconds * RATE));
	for (let i = 0; i < samples.length; i++) {
		const t = i / RATE;
		let value = 0;
		for (const [kind, hz, length, when, loud, slide] of notes) value += loud * voice(kind, hz, length, t - when, slide);
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
	header.writeUInt16LE(1, 20); // PCM
	header.writeUInt16LE(1, 22); // mono
	header.writeUInt32LE(RATE, 24);
	header.writeUInt32LE(RATE * 2, 28);
	header.writeUInt16LE(2, 32);
	header.writeUInt16LE(16, 34);
	header.write("data", 36);
	header.writeUInt32LE(data.length, 40);
	return Buffer.concat([header, data]);
}

mkdirSync(out, { recursive: true });
for (const [name, notes] of Object.entries(SOUNDS)) {
	const file = join(out, `${name}.wav`);
	const bytes = wav(render(notes));
	writeFileSync(file, bytes);
	console.log(`${file}: ${bytes.length} bytes`);
}
