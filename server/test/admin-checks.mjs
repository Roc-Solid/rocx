// packages/admin's tables admin, asked over HTTP the same way on Postgres (server.test.mjs) and on
// SQLite (sqlite.test.mjs): each test app mounts it at /admin/db over admin_authors and admin_books
// (a foreign key, a check that is a choice, a boolean, a number, JSON), open to all.
import assert from "node:assert/strict";

/** The admin at `url`: its index, a new row's form (the check's values and the authors as choices,
 * the boolean a checkbox), a row created, shown, found by a search and a filter, changed, and
 * deleted, each form sent back with the token its cookie holds. */
export async function adminWorks(url) {
	const at = `${url}/admin/db`;
	const first = await fetch(at);
	assert.equal(first.status, 200);
	const cookie = (first.headers.get("set-cookie") ?? "").split(";")[0];
	const token = cookie.split("=")[1];
	assert.match(token, /^[0-9a-f]{32}$/, "a token for its forms, in a cookie");
	const index = await first.text();
	assert.match(index, /admin_books/);
	assert.doesNotMatch(index, /__turso_internal/, "Turso's own tables (its MVCC's) aren't the app's");
	assert.match(index, /admin_authors/);
	const get = async (query) => {
		const answer = await fetch(`${at}?${query}`, { headers: { cookie } });
		assert.equal(answer.status, 200, query);
		return answer.text();
	};
	const blank = await get("table=admin_books&new");
	assert.match(blank, /<select[^>]*name="v\.state"[^>]*>[\s\S]*?<option value="draft"[^>]*>draft<\/option><option value="sold"[^>]*>sold<\/option><\/select>/, "the check's values, a choice");
	const ada = /<option value="(\d+)"[^>]*>Ada<\/option>/.exec(blank);
	assert.ok(ada, "the authors, a choice by name");
	assert.match(blank, /name="v\.done" value="true"/, "the boolean, a checkbox");
	const post = (fields) =>
		fetch(at, {
			method: "POST",
			redirect: "manual",
			headers: { cookie, "content-type": "application/x-www-form-urlencoded" },
			body: new URLSearchParams({ csrf: token, table: "admin_books", ...fields }),
		});

	const created = await post({ action: "create", "v.title": "Dune", "v.author_id": ada[1], "v.state": "sold", "v.done": "true", "v.price": "9.5", "v.meta": '{"tags":["sf"]}' });
	assert.equal(created.status, 303, await created.text());
	const location = created.headers.get("location");
	const id = /k\.id=(\d+)/.exec(location)?.[1];
	assert.ok(id, location);
	const row = await get(`table=admin_books&k.id=${id}`);
	assert.match(row, /value="Dune"/);
	assert.match(row, /name="v\.done" value="true" checked/, "written as the database keeps a boolean, read back as one");
	assert.match(row, /<option value="sold" selected>/);
	assert.match(row, /sf/);

	assert.match(await get("table=admin_books&q=dun"), /Dune/, "a search, in any case");
	assert.match(await get("table=admin_books&f.state=sold"), /Dune/, "a filter");
	assert.doesNotMatch(await get("table=admin_books&q=nothing+like+it"), /Dune/);

	const changed = await post({ action: "update", "k.id": id, "v.title": "Dune Messiah", "v.done": "false" });
	assert.equal(changed.status, 303, await changed.text());
	const after = await get(`table=admin_books&k.id=${id}`);
	assert.match(after, /value="Dune Messiah"/);
	assert.doesNotMatch(after, /name="v\.done" value="true" checked/);

	const deleted = await post({ action: "delete", "k.id": id });
	assert.equal(deleted.status, 303, await deleted.text());
	assert.equal((await fetch(`${at}?table=admin_books&k.id=${id}`, { headers: { cookie } })).status, 404);
}
