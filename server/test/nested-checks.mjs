// Transactions inside transactions (D-076), asked over HTTP the same way on Postgres
// (server.test.mjs) and on SQLite and Turso, in MVCC and in WAL mode (sqlite.test.mjs): each test
// app answers /nested… with the same routes, and writes its marks in nested_marks. A
// `Db.transaction!` inside one is a level of it, a savepoint: an inner `Ok` keeps its writes in the
// level around it, an inner `Err` (or a failing statement) undoes only its own, and the outer body
// may go on; what a level notified, and the jobs it queued, go with it; on Turso's MVCC a level that
// loses to another's write isn't run again on its own, the whole transaction is.
import assert from "node:assert/strict";

/** Registers the tests on node:test's `test`, for the app `server()` answers (its `url`, and what it
 * has `logged()`), on `engine` ("postgres", "sqlite", "turso" or "turso-wal"), skipped as `skip`
 * says; each name begins `prefix`. */
export function nestedTests({ test, server, engine, skip, prefix = "" }) {
	/** A name of this run's own, so rows from runs before don't count. */
	const fresh = (name) => `${name}${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
	const get = async (path) => (await fetch(`${server().url}${path}`)).text();
	const post = async (path) => (await fetch(`${server().url}${path}`, { method: "POST" })).text();
	/** The marks a run's levels left, in the order they were written. */
	const marks = (run) => get(`/nested/marks?run=${run}`);

	test(`${prefix}nested transactions: an inner Ok keeps both levels' writes; an inner Err or a failing statement undoes only the inner's, and the outer goes on and commits; an outer Err after an inner Ok undoes both; a crash in a level rolls everything back`, { skip }, async () => {
		const ok = fresh("ok");
		assert.equal(await post(`/nested?run=${ok}&inner=ok`), "inner committed");
		assert.equal(await marks(ok), "outer,inner,after");

		const err = fresh("err");
		assert.equal(await post(`/nested?run=${err}&inner=err`), "inner rolled back: inner on purpose");
		assert.equal(await marks(err), "outer,after", "only the inner's write undone");

		const statement = fresh("statement");
		assert.match(await post(`/nested?run=${statement}&inner=statement`), /^inner rolled back: .*nowhere/);
		assert.equal(await marks(statement), "outer,after", "the outer goes on after a statement failed in the inner (on Postgres too)");

		// A failing statement whose error the inner body drops: on Postgres it aborted the transaction,
		// so the level can't be released, and is undone instead; SQLite and Turso failed the statement
		// alone, and the level commits.
		const swallowed = fresh("swallow");
		if (engine === "postgres") {
			assert.match(await post(`/nested?run=${swallowed}&inner=swallow`), /^inner rolled back: 25P02: current transaction is aborted/);
			assert.equal(await marks(swallowed), "outer,after");
		} else {
			assert.equal(await post(`/nested?run=${swallowed}&inner=swallow`), "inner swallowed its error");
			assert.equal(await marks(swallowed), "outer,inner,after");
		}

		const outer = fresh("outer");
		assert.equal(await post(`/nested?run=${outer}&inner=ok&outer=err`), "rolled back: outer on purpose");
		assert.equal(await marks(outer), "", "the inner's committed write goes with the outer");

		const crashed = fresh("crash");
		const crash = await fetch(`${server().url}/nested?run=${crashed}&inner=crash`, { method: "POST" });
		assert.equal(crash.status, 500);
		assert.equal(await marks(crashed), "");
		assert.match(server().logged(), /a call ended with its transaction open: rolled back/);

		// The connections went back to the pool clean, and many at once (on Turso's MVCC, some run
		// again) each leave their three marks, once.
		const many = Array.from({ length: 12 }, (_, i) => fresh(`many${i}`));
		const answers = await Promise.all(many.map((run) => post(`/nested?run=${run}&inner=ok`)));
		assert.deepEqual(new Set(answers), new Set(["inner committed"]));
		assert.deepEqual(new Set(await Promise.all(many.map(marks))), new Set(["outer,inner,after"]));
	});

	test(`${prefix}nested transactions three levels deep: a level that errs undoes its writes and those of the levels inside it, the levels around it keep theirs; what a level notified is heard only if it and every level around it commit`, { skip }, async () => {
		const payload = fresh("p");
		const heard = get("/nested/listen?ms=1500");
		// Postgres is told to listen first.
		await new Promise((resolve) => setTimeout(resolve, 300));
		const runs = {};
		for (const fail of [0, 3, 2, 1]) {
			runs[fail] = fresh(`deep${fail}`);
			const said = await post(`/nested/deep?run=${runs[fail]}&payload=${payload}${fail}&fail=${fail}`);
			const expected = { 0: "l1 l2 l3", 3: "l1 l2 (l3 failed)", 2: "l1 (l2 failed)", 1: "rolled back: l1 failed" }[fail];
			assert.equal(said, expected, `level ${fail} failing`);
		}
		assert.equal(await marks(runs[0]), "l1,l2,l3");
		assert.equal(await marks(runs[3]), "l1,l2");
		assert.equal(await marks(runs[2]), "l1", "the third committed into the second, which rolled back");
		assert.equal(await marks(runs[1]), "");
		const mine = (await heard).split(",").filter((said) => said.startsWith(payload));
		assert.deepEqual(mine, [`${payload}0-l1`, `${payload}0-l2`, `${payload}0-l3`, `${payload}3-l1`, `${payload}3-l2`, `${payload}2-l1`]);
	});

	test(`${prefix}a job queued in a level that rolls back is never queued and never runs (what it notified goes with it); one queued in the level around it is, and runs`, { skip }, async () => {
		const run = fresh("job");
		assert.equal(await post(`/nested/job?run=${run}`), "dropped on purpose");
		await until(async () => (await get(`/nested/jobs?run=${run}`)) === "queued 1 0, ran 1 0");
		await new Promise((resolve) => setTimeout(resolve, 300));
		assert.equal(await get(`/nested/jobs?run=${run}`), "queued 1 0, ran 1 0");
	});

	if (engine === "turso") {
		test(`${prefix}nested transactions on Turso's MVCC: a level that loses to another's write isn't run again on its own, the whole transaction is, from its outermost level; a write its outer body makes after taking the inner's error in its stride doesn't land`, { skip }, async () => {
			for (const handled of [false, true]) {
				const run = fresh(handled ? "handled" : "bump");
				const both = await Promise.all([0, 1].map(() => post(`/nested/bump?run=${run}&name=${run}&ms=300${handled ? "&handle=yes" : ""}`)));
				assert.deepEqual(both.map(Number).sort((a, b) => a - b), [1, 2], "each saw the other's");
				const runs = await get(`/nested/runs?run=${run}`);
				const [outer, inner, lost] = /^outer=(\d+) inner=(\d+) lost=(\d+)$/.exec(runs).slice(1).map(Number);
				assert.ok(lost >= 1, `the inner level lost to the other's write: ${runs}`);
				assert.equal(inner, outer, `the inner level ran once each time the outer did: ${runs}`);
				assert.ok(outer >= 2 + lost, `the outer ran again after each loss: ${runs}`);
				assert.equal(await marks(run), "", "nothing ran outside the transaction that lost");
			}
		});
	}
}

/** Waits until `check` (async) is true, or fails after `ms`. */
async function until(check, ms = 5000) {
	const started = performance.now();
	while (!(await check())) {
		if (performance.now() - started > ms) assert.fail(`not within ${ms} ms`);
		await new Promise((resolve) => setTimeout(resolve, 25));
	}
}
