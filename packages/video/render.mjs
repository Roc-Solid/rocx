#!/usr/bin/env node
// A `<Player>` filmed into a video file: the page at a URL opened in Chromium's headless shell (the
// repository's driver, as packages/testing opens pages), its clock taken over (clock.js), then each
// frame in turn: the clock moved on by a frame, the player sought to it (its own scrubber), the page
// settled and its animations put where the clock says, and the player's stage photographed. The
// photographs go to ffmpeg, which writes each file asked for: .mp4 (H.264), .webm (VP9), or a
// folder of PNGs (`frames/`). A frame looks the same however long it took to film, so two renders
// of one composition are the same, frame for frame.
//
//   node packages/video/render.mjs http://localhost:8091/ -o launch.mp4 -o launch.webm
//   node packages/video/render.mjs http://localhost:8091/__rocx/stories/launch/a-bar-to-scrub -o frames/
//
// Options: `-o <file>` (again for more; launch.mp4 when none), `--player <n|label>` (the page's
// first player unless it says: its index from 0, or its aria-label), `--scale <n>` (device pixels a
// CSS pixel, 2 unless it says: a 1280 by 720 player is filmed at 2560 by 1440), `--from <frame>` and
// `--to <frame>` (a stretch of it, the last one in it), `--crf <n>` (H.264's quality, 18 unless it
// says). ffmpeg is `$FFMPEG`, else the `ffmpeg` on PATH, else Nix's (`nix build
// nixpkgs#ffmpeg-headless`); Chromium is `$CHROME`, else Playwright's, as the tests find it.
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, extname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const testing = () => import(pathToFileURL(join(here, "..", "testing", "index.mjs")).href);

/** What every document of the renderer's tab runs first: the clock it moves. */
export const clockScript = () => readFileSync(join(here, "clock.js"), "utf8");

/**
 * The player at `url` filmed: `outputs` written (paths ending in .mp4 or .webm, or a folder for
 * PNGs, ending in `/`), and what was filmed returned: `{ fps, frames, width, height, hashes }`, each
 * frame's SHA-256 among `hashes`. `browser` is one launchBrowser() started (launched and closed here
 * when none is given); `onFrame(index, png)` hears each frame as it is taken.
 */
export async function render({ url, outputs = ["launch.mp4"], player = 0, scale = 2, from, to, crf = 18, browser, onFrame, log = () => {} }) {
	const { launchBrowser } = await testing();
	const own = !browser;
	browser ??= await launchBrowser();
	if (!browser) throw new Error("rendering needs Chromium's headless shell: set $CHROME, or install Playwright's (`npx playwright install chromium-headless-shell`)");
	if (browser.engine !== "chromium") throw new Error("rendering takes Chromium: its DevTools protocol photographs the page");
	let encoder = null;
	try {
		const tab = await browser.open(url, { strict: false, script: clockScript() });
		const found = await tab.page.eval(`(() => {
			const players = [...document.querySelectorAll("[data-rocx-video]")];
			const wanted = ${JSON.stringify(player)};
			const index = typeof wanted === "number" ? wanted : players.findIndex((each) => each.getAttribute("aria-label") === wanted);
			const chosen = players[index];
			if (!chosen) return { count: players.length };
			players.forEach((each, i) => (each.dataset.rocxFilmed = i === index ? "yes" : "no"));
			return { count: players.length, fps: Number(chosen.dataset.fps), frames: Number(chosen.dataset.frames), width: Number(chosen.dataset.width), height: Number(chosen.dataset.height), scaled: chosen.classList.contains("video-scale") };
		})()`);
		if (found.fps === undefined) throw new Error(`${url} has ${found.count} player${found.count === 1 ? "" : "s"} (<Player>, [data-rocx-video]); none is ${JSON.stringify(player)}`);
		const { fps, frames, width, height } = found;
		const first = Math.max(0, Math.min(from ?? 0, frames - 1));
		const last = Math.max(first, Math.min(to ?? frames - 1, frames - 1));
		// The player at its own width, alone in its stage: its controls hidden, a scaled one at 1.
		await tab.page.eval(`(() => {
			const style = document.createElement("style");
			style.textContent = '[data-rocx-filmed="yes"] { width: ${width}px !important; max-width: none !important; margin: 0 !important; } [data-rocx-filmed="yes"] .video-controls { display: none !important; } [data-rocx-filmed="yes"].video-scale { --video-scale: 1 !important; }';
			document.head.append(style);
		})()`);
		// What the page puts over the player isn't filmed: a fixed or sticky element (a top bar, a
		// page's table of contents), or one placed over it, outside the player and not around it.
		const uncover = () =>
			tab.page.eval(`(() => {
				const filmed = document.querySelector('[data-rocx-filmed="yes"]');
				const stage = filmed.querySelector(".video-stage").getBoundingClientRect();
				for (const element of document.body.querySelectorAll("*")) {
					if (filmed.contains(element) || element.contains(filmed)) continue;
					const position = getComputedStyle(element).position;
					if (position === "static" || position === "relative") continue;
					const box = element.getBoundingClientRect();
					const over = box.right > stage.left && box.left < stage.right && box.bottom > stage.top && box.top < stage.bottom;
					if (position === "fixed" || position === "sticky" || over) element.style.setProperty("visibility", "hidden", "important");
				}
			})()`);
		const view = { width: width + 64, height: Math.max(height, 200) + 64 };
		await tab.page.send("Emulation.setDeviceMetricsOverride", { width: view.width, height: view.height, deviceScaleFactor: scale, mobile: false });
		await tab.page.eval(`(async () => {
			window.__rocxClock.freeze();
			await window.__rocxClock.settle();
		})()`);
		// The stage's place, with the page laid out at this width; a taller one gets a taller view.
		const place = async () => tab.page.eval(`(() => {
			const stage = document.querySelector('[data-rocx-filmed="yes"] .video-stage');
			stage.scrollIntoView({ block: "start", inline: "start" });
			const box = stage.getBoundingClientRect();
			return { x: box.left + scrollX, y: box.top + scrollY, width: box.width, height: box.height };
		})()`);
		let box = await place();
		if (box.height + 64 > view.height) {
			await tab.page.send("Emulation.setDeviceMetricsOverride", { width: view.width, height: Math.ceil(box.height) + 64, deviceScaleFactor: scale, mobile: false });
			box = await place();
		}
		await uncover();
		const clip = { x: Math.round(box.x), y: Math.round(box.y), width: Math.round(box.width), height: Math.round(box.height), scale: 1 };
		log(`filming ${last - first + 1} frames at ${fps} a second, ${clip.width} by ${clip.height} (${clip.width * scale} by ${clip.height * scale} pixels)`);
		encoder = outputs.some((out) => !out.endsWith("/")) ? encode({ outputs: outputs.filter((out) => !out.endsWith("/")), fps, crf }) : null;
		const folders = outputs.filter((out) => out.endsWith("/"));
		for (const folder of folders) mkdirSync(folder, { recursive: true });
		const hashes = [];
		for (let index = first; index <= last; index++) {
			await tab.page.eval(`(async () => {
				const clock = window.__rocxClock;
				clock.advance(${index === first ? 0 : 1000 / fps});
				const seek = document.querySelector('[data-rocx-filmed="yes"] .video-seek');
				seek.value = "${index}";
				seek.dispatchEvent(new Event("input", { bubbles: true }));
				await clock.settle();
				clock.sync();
			})()`);
			const { data } = await tab.page.send("Page.captureScreenshot", { format: "png", clip, captureBeyondViewport: true });
			const png = Buffer.from(data, "base64");
			hashes.push(createHash("sha256").update(png).digest("hex"));
			onFrame?.(index, png);
			for (const folder of folders) writeFileSync(join(folder, `frame-${String(index).padStart(5, "0")}.png`), png);
			if (encoder) await encoder.write(png);
		}
		if (encoder) await encoder.done();
		const errors = tab.errors;
		await tab.close();
		return { fps, frames: last - first + 1, width: clip.width * scale, height: clip.height * scale, hashes, errors };
	} catch (error) {
		encoder?.kill();
		throw error;
	} finally {
		if (own) await browser.close();
	}
}

/** ffmpeg: `$FFMPEG`, the one on PATH, or Nix's ffmpeg-headless (built once, then from the store). */
export function findFfmpeg() {
	if (process.env.FFMPEG) return process.env.FFMPEG;
	if (spawnSync("ffmpeg", ["-version"], { stdio: "ignore" }).status === 0) return "ffmpeg";
	if (spawnSync("nix", ["--version"], { stdio: "ignore" }).status === 0) {
		const built = spawnSync("nix", ["build", "nixpkgs#ffmpeg-headless", "--no-link", "--print-out-paths"], { encoding: "utf8" });
		const bin = built.stdout?.split("\n").find((path) => path.endsWith("-bin"));
		if (built.status === 0 && bin && existsSync(join(bin, "bin", "ffmpeg"))) return join(bin, "bin", "ffmpeg");
	}
	throw new Error("rendering to a video file needs ffmpeg: set $FFMPEG, put it on PATH, or install Nix (it is fetched as nixpkgs#ffmpeg-headless)");
}

/** The arguments that write `out` from the frames: H.264 for .mp4, VP9 for .webm, each in 4:2:0
 * (what every player plays), its size made even. */
function outputArgs(out, crf) {
	const even = ["-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2"];
	switch (extname(out).toLowerCase()) {
		case ".mp4":
			return [...even, "-c:v", "libx264", "-preset", "slow", "-crf", String(crf), "-pix_fmt", "yuv420p", "-movflags", "+faststart", out];
		case ".webm":
			return [...even, "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-pix_fmt", "yuv420p", out];
		default:
			throw new Error(`${out}: a video is written as .mp4 or .webm (or frames into a folder, ending in /)`);
	}
}

/** One ffmpeg writing every file, fed PNGs on its stdin. */
function encode({ outputs, fps, crf }) {
	for (const out of outputs) mkdirSync(dirname(resolve(out)), { recursive: true });
	const args = ["-hide_banner", "-loglevel", "error", "-y", "-f", "image2pipe", "-framerate", String(fps), "-c:v", "png", "-i", "-", ...outputs.flatMap((out) => outputArgs(out, crf))];
	const ffmpeg = spawn(findFfmpeg(), args, { stdio: ["pipe", "inherit", "pipe"] });
	let said = "";
	ffmpeg.stderr.on("data", (chunk) => (said += chunk));
	const exited = new Promise((resolve) => ffmpeg.on("close", (code) => resolve(code)));
	return {
		write: (png) => new Promise((resolve, reject) => ffmpeg.stdin.write(png, (error) => (error ? reject(new Error(`ffmpeg stopped: ${said || error.message}`)) : resolve()))),
		async done() {
			ffmpeg.stdin.end();
			const code = await exited;
			if (code !== 0) throw new Error(`ffmpeg failed (${code}): ${said}`);
		},
		kill: () => ffmpeg.kill(),
	};
}

/** The command line's options, as `render` takes them. */
export function parseArgs(argv) {
	const options = { outputs: [] };
	for (let i = 0; i < argv.length; i++) {
		const arg = argv[i];
		const value = () => {
			if (i + 1 >= argv.length) throw new Error(`${arg} needs a value`);
			return argv[++i];
		};
		if (arg === "-o" || arg === "--out") options.outputs.push(value());
		else if (arg === "--player") {
			const wanted = value();
			options.player = /^\d+$/.test(wanted) ? Number(wanted) : wanted;
		} else if (arg === "--scale") options.scale = Number(value());
		else if (arg === "--from") options.from = Number(value());
		else if (arg === "--to") options.to = Number(value());
		else if (arg === "--crf") options.crf = Number(value());
		else if (arg.startsWith("-")) throw new Error(`no option ${arg}`);
		else if (options.url) throw new Error(`one URL: ${options.url}, then ${arg}`);
		else options.url = arg;
	}
	if (!options.url) throw new Error("usage: render.mjs <url> [-o out.mp4] [-o out.webm] [-o frames/] [--player <n|label>] [--scale 2] [--from n] [--to n] [--crf 18]");
	if (options.outputs.length === 0) options.outputs.push("video.mp4");
	return options;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	try {
		const options = parseArgs(process.argv.slice(2));
		const started = Date.now();
		const made = await render({ ...options, log: (line) => console.log(line) });
		for (const error of made.errors) console.error(`the page threw: ${error}`);
		console.log(`wrote ${options.outputs.join(", ")}: ${made.frames} frames, ${made.width} by ${made.height}, in ${((Date.now() - started) / 1000).toFixed(1)} s`);
	} catch (error) {
		console.error(error.message);
		process.exit(1);
	}
}
