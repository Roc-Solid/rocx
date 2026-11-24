#!/usr/bin/env node
// Pomodoro's sound: the chime a session's end plays, synthesized here and written as a WAV file
// into static/sounds/, which the page plays with `Audio.play!` (and a phone's host plays the same
// file, from the server). It is made, not recorded, so it is this script, and small; run it again
// after changing it.
//
//   node examples/pomodoro/sounds.mjs
//
// A bell: three notes going up (G5, B5, D6, a major chord), each a sine with two quieter overtones
// that die faster (an inharmonic one, as a struck bar has), struck and ringing out.
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const out = join(dirname(fileURLToPath(import.meta.url)), "static", "sounds");
const RATE = 22050;
const SECONDS = 1.6;

// [hertz, when (s), loudness]
const NOTES = [
	[783.99, 0.0, 0.45],
	[987.77, 0.16, 0.42],
	[1174.66, 0.32, 0.5],
];

function bell(t, hertz) {
	if (t < 0) return 0;
	const strike = Math.min(1, t / 0.004);
	return strike * (Math.sin(2 * Math.PI * hertz * t) * Math.exp(-t * 3.2) + 0.35 * Math.sin(2 * Math.PI * hertz * 2.76 * t) * Math.exp(-t * 9) + 0.15 * Math.sin(2 * Math.PI * hertz * 5.4 * t) * Math.exp(-t * 18));
}

const count = Math.round(SECONDS * RATE);
const samples = new Int16Array(count);
for (let at = 0; at < count; at++) {
	const t = at / RATE;
	let value = 0;
	for (const [hertz, when, loudness] of NOTES) value += loudness * bell(t - when, hertz);
	// The last 50 ms fade to silence, so the file ends without a click.
	const fade = Math.min(1, (SECONDS - t) / 0.05);
	samples[at] = Math.max(-1, Math.min(1, value * 0.8 * fade)) * 32767;
}

const header = Buffer.alloc(44);
header.write("RIFF", 0);
header.writeUInt32LE(36 + samples.byteLength, 4);
header.write("WAVEfmt ", 8);
header.writeUInt32LE(16, 16);
header.writeUInt16LE(1, 20); // PCM
header.writeUInt16LE(1, 22); // mono
header.writeUInt32LE(RATE, 24);
header.writeUInt32LE(RATE * 2, 28);
header.writeUInt16LE(2, 32);
header.writeUInt16LE(16, 34);
header.write("data", 36);
header.writeUInt32LE(samples.byteLength, 40);
mkdirSync(out, { recursive: true });
writeFileSync(join(out, "done.wav"), Buffer.concat([header, Buffer.from(samples.buffer)]));
console.log(`wrote ${join(out, "done.wav")} (${44 + samples.byteLength} bytes)`);
