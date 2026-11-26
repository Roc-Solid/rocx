// `rocx build <dir> --image <file.tar>` (D-099): an app's release as a container image that rocx
// writes itself, with no Dockerfile and no Docker. On a small app beside this clone (its `.rocx`
// links here), for this machine's Linux (arm64musl or x64musl): the file is an OCI image layout in a
// tar with Docker's manifest.json beside it; every blob is named by its SHA-256 and has the size its
// descriptor says; the configuration runs the server as 65532 in /app on PORT 8080, its layer's
// diff_id the SHA-256 of the layer unzipped; the layer holds the server (0755), the files it
// serves, /app/data owned by 65532, /etc/passwd naming that user, and /tmp (1777). The app names no
// database, so it is a Postgres one (App.program's default), and its server's host has Postgres and
// SQLite, but none of Turso's code (D-104), and no debug info. Where Docker answers, `docker load`
// takes the file and the image serves the app's page.
//
// Needs the toolchain (`just setup`) and Rust's musl target for this machine (`just setup` adds it).
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { gunzipSync } from "node:zlib";
import { roc, root, rocxBinary } from "../server/build.mjs";

let compiler = null;
try {
	compiler = roc();
} catch {}
const skip = (!compiler && "no roc (run `just setup`, or set ROC)") || (!["darwin", "linux"].includes(process.platform) && "a Linux image is built on macOS or Linux");
const docker = !skip && spawnSync("docker", ["info", "--format", "{{.ServerVersion}}"], { encoding: "utf8" }).status === 0;
const arch = process.arch === "x64" ? "amd64" : "arm64";

let work;
let app;
let image;

/** The entries of a tar: each one's name (prefix joined), mode, owner, type and bytes. */
function untar(bytes) {
	const entries = new Map();
	let at = 0;
	const text = (start, length) => {
		const raw = bytes.subarray(at + start, at + start + length);
		const end = raw.indexOf(0);
		return raw.subarray(0, end === -1 ? length : end).toString("utf8");
	};
	while (at + 512 <= bytes.length && bytes.subarray(at, at + 512).some((byte) => byte !== 0)) {
		const prefix = text(345, 155);
		const name = prefix ? `${prefix}/${text(0, 100)}` : text(0, 100);
		const size = parseInt(text(124, 12), 8);
		const header = Buffer.from(bytes.subarray(at, at + 512));
		header.fill(0x20, 148, 156);
		const sum = header.reduce((total, byte) => total + byte, 0);
		assert.equal(parseInt(text(148, 8), 8), sum, `${name}: its header's checksum`);
		entries.set(name, { mode: parseInt(text(100, 8), 8), uid: parseInt(text(108, 8), 8), gid: parseInt(text(116, 8), 8), type: String.fromCharCode(bytes[at + 156]), owner: text(265, 32), bytes: bytes.subarray(at + 512, at + 512 + size) });
		at += 512 + Math.ceil(size / 512) * 512;
	}
	return entries;
}

const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

/** The names of a 64-bit little-endian ELF file's sections. */
function sections(elf) {
	const at = Number(elf.readBigUInt64LE(0x28));
	const size = elf.readUInt16LE(0x3a);
	const count = elf.readUInt16LE(0x3c);
	const header = (i) => elf.subarray(at + i * size, at + (i + 1) * size);
	const names = header(elf.readUInt16LE(0x3e));
	const table = elf.subarray(Number(names.readBigUInt64LE(0x18)), Number(names.readBigUInt64LE(0x18) + names.readBigUInt64LE(0x20)));
	return Array.from({ length: count }, (_, i) => {
		const start = header(i).readUInt32LE(0);
		return table.subarray(start, table.indexOf(0, start)).toString();
	});
}

before(() => {
	if (skip) return;
	work = mkdtempSync(join(tmpdir(), "rocx-image-"));
	app = join(work, "Shop App");
	const files = {
		"main.roc": `app [program] { pf: platform "./.rocx/server/platform/main.roc" }

import Generated/App

program = App.program({
	init!: |_started| Ok({}),
})
`,
		"routes/+page.rocx": `import pf.Html

view! = |_| <main><h1>Hello from the image</h1></main>
`,
		"static/robots.txt": "User-agent: *\n",
	};
	for (const [path, content] of Object.entries(files)) {
		mkdirSync(dirname(join(app, path)), { recursive: true });
		writeFileSync(join(app, path), content);
	}
	symlinkSync(root, join(app, ".rocx"));
	image = join(work, "out", "shop.tar");
});

after(() => {
	if (work) rmSync(work, { recursive: true, force: true });
	if (docker) spawnSync("docker", ["image", "rm", "-f", "rocx-image-test:1"]);
});

test("rocx build --image: an OCI image of the app's release, with no Dockerfile, that docker loads and runs", { skip, timeout: 30 * 60 * 1000 }, async () => {
	const built = spawnSync(rocxBinary(), ["build", app, "--image", image, "--tag", "rocx-image-test:1"], { encoding: "utf8", env: { ...process.env, NO_COLOR: "1" } });
	assert.equal(built.status, 0, built.stdout + built.stderr);
	assert.match(built.stderr, new RegExp(`rocx build --image: .*shop\\.tar, rocx-image-test:1 \\(linux/${arch}\\) in [\\d.]+ s: [\\d.]+ MB to send, [\\d.]+ MB unpacked`));

	const outer = untar(readFileSync(image));
	assert.deepEqual([...outer.keys()].filter((name) => !name.startsWith("blobs/")), ["oci-layout", "index.json", "manifest.json"]);
	assert.deepEqual(JSON.parse(outer.get("oci-layout").bytes), { imageLayoutVersion: "1.0.0" });
	// Every blob is named by its SHA-256.
	for (const [name, entry] of outer) if (name.startsWith("blobs/sha256/")) assert.equal(sha256(entry.bytes), name.slice("blobs/sha256/".length), name);
	const blob = (descriptor) => {
		const found = outer.get(`blobs/sha256/${descriptor.digest.slice("sha256:".length)}`);
		assert.ok(found, descriptor.digest);
		assert.equal(found.bytes.length, descriptor.size, `${descriptor.digest}: its size`);
		return found.bytes;
	};
	const index = JSON.parse(outer.get("index.json").bytes);
	assert.equal(index.manifests.length, 1);
	assert.deepEqual(index.manifests[0].annotations, { "io.containerd.image.name": "docker.io/library/rocx-image-test:1", "org.opencontainers.image.ref.name": "1" });
	const manifest = JSON.parse(blob(index.manifests[0]));
	assert.equal(manifest.mediaType, "application/vnd.oci.image.manifest.v1+json");
	assert.equal(manifest.layers.length, 1);
	assert.equal(manifest.layers[0].mediaType, "application/vnd.oci.image.layer.v1.tar+gzip");
	const config = JSON.parse(blob(manifest.config));
	const layer = gunzipSync(blob(manifest.layers[0]));
	assert.deepEqual(config.rootfs, { type: "layers", diff_ids: [`sha256:${sha256(layer)}`] });
	assert.equal(config.os, "linux");
	assert.equal(config.architecture, arch);
	assert.deepEqual(config.config.Entrypoint, ["/app/server", "--host", "0.0.0.0", "--static", "/app/static"]);
	assert.deepEqual([config.config.User, config.config.WorkingDir, config.config.Env, config.config.ExposedPorts], ["65532:65532", "/app", ["PATH=/app", "PORT=8080"], { "8080/tcp": {} }]);
	// Docker's own list, for a Docker that reads no OCI layout.
	assert.deepEqual(JSON.parse(outer.get("manifest.json").bytes), [{ Config: `blobs/sha256/${manifest.config.digest.slice(7)}`, RepoTags: ["rocx-image-test:1"], Layers: [`blobs/sha256/${manifest.layers[0].digest.slice(7)}`] }]);

	const files = untar(layer);
	const server = files.get("app/server");
	assert.deepEqual([server.type, server.mode, server.uid], ["0", 0o755, 0]);
	assert.deepEqual([...server.bytes.subarray(0, 4)], [0x7f, 0x45, 0x4c, 0x46], "a Linux executable (ELF)");
	const names = sections(Buffer.from(server.bytes));
	assert.ok(names.includes(".text") && names.includes(".symtab"), `its code, and its symbols for a backtrace: ${names}`);
	assert.deepEqual(names.filter((name) => name.startsWith(".debug")), [], "no debug info");
	assert.ok(!server.bytes.includes("turso_core"), "no Turso in the host of an app that doesn't name it");
	assert.ok(server.bytes.includes("tokio_postgres"), "Postgres, the database of an app that names none");
	assert.ok(server.bytes.includes("rusqlite"), "SQLite's in every host");
	assert.deepEqual([files.get("app/data/").type, files.get("app/data/").uid, files.get("app/data/").owner], ["5", 65532, "nonroot"]);
	assert.deepEqual([files.get("tmp/").type, files.get("tmp/").mode], ["5", 0o1777]);
	assert.match(files.get("etc/passwd").bytes.toString(), /^nonroot:x:65532:65532:/m);
	assert.equal(files.get("app/static/robots.txt").bytes.toString(), "User-agent: *\n", "the app's static/");
	assert.ok([...files.keys()].some((name) => /^app\/static\/rocx\/.*\.wasm$/.test(name)), "the browser's wasm");
	assert.ok(files.has("app/static/rocx/"), "each directory has its entry");

	if (!docker) return;
	const loaded = spawnSync("docker", ["load", "-i", image], { encoding: "utf8" });
	assert.equal(loaded.status, 0, loaded.stderr);
	assert.match(loaded.stdout, /rocx-image-test:1/);
	const started = spawnSync("docker", ["run", "-d", "--rm", "-p", "127.0.0.1::8080", "rocx-image-test:1", "--dev"], { encoding: "utf8" });
	assert.equal(started.status, 0, started.stderr);
	const container = started.stdout.trim();
	try {
		const port = spawnSync("docker", ["port", container, "8080/tcp"], { encoding: "utf8" }).stdout.trim().split(":").pop();
		let page = null;
		for (let tries = 0; tries < 100 && !page; tries++) {
			page = await fetch(`http://127.0.0.1:${port}/`).catch(() => null);
			if (!page) await new Promise((done) => setTimeout(done, 100));
		}
		assert.ok(page, spawnSync("docker", ["logs", container], { encoding: "utf8" }).stderr);
		assert.equal(page.status, 200);
		assert.match(await page.text(), /Hello from the image/);
	} finally {
		spawnSync("docker", ["rm", "-f", container]);
	}
});
