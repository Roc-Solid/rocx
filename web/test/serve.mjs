// A static file server for tests: `dir` as a site, with the right content types (wasm streams
// only as application/wasm), on a free port. `pages` may render a page per request, and `api`
// answer other requests (an endpoint's GET a component sends, say).
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, normalize, sep } from "node:path";

const TYPES = { ".css": "text/css", ".js": "text/javascript", ".svg": "image/svg+xml", ".wasm": "application/wasm", ".html": "text/html; charset=utf-8", ".txt": "text/plain; charset=utf-8" };

/** Serves `dir`; `pages` may answer a path first (a page rendered per request, with the request),
 * and `api` any request, with its body, whole URL and the request: `{ status, body, headers? }`, or
 * null to pass; or `{ status, headers?, stream }`, `stream(response, request)` writing the body as
 * it goes (events). */
export async function serve(dir, pages = () => null, api = () => null) {
	const server = createServer(async (request, response) => {
		const path = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
		const chunks = [];
		for await (const chunk of request) chunks.push(chunk);
		const answered = await api(request.method, path, Buffer.concat(chunks).toString("utf8"), request.url, request);
		if (answered) {
			response.writeHead(answered.status, { "content-type": TYPES[".txt"], ...answered.headers });
			if (answered.stream) return answered.stream(response, request);
			return response.end(answered.body);
		}
		const page = pages(path, request);
		if (page !== null) {
			response.writeHead(200, { "content-type": TYPES[".html"] });
			return response.end(page);
		}
		for (const candidate of [path, join(path, "index.html")]) {
			const full = normalize(join(dir, candidate));
			if (!full.startsWith(dir + sep) && full !== dir) continue;
			try {
				const body = await readFile(full);
				response.writeHead(200, { "content-type": TYPES[extname(full)] ?? "application/octet-stream" });
				return response.end(body);
			} catch {}
		}
		response.writeHead(404, { "content-type": TYPES[".html"] });
		response.end(await readFile(join(dir, "404.html")).catch(() => "not found"));
	});
	await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
	return { url: `http://127.0.0.1:${server.address().port}`, close: () => new Promise((resolve) => (server.close(resolve), server.closeAllConnections())) };
}
