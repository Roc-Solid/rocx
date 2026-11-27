// A clock the renderer moves (packages/video's render.mjs runs this in every document of its tab,
// before the page's own scripts). Until `freeze()`, it is the page's own: everything runs in real
// time, so the page loads and hydrates as it would. Frozen, time moves only when `advance(ms)` says,
// so a frame looks the same however long it took to film:
//
// - `performance.now()`, `Date.now()` and `new Date()` read the moved clock;
// - `setTimeout` and `setInterval` (with a delay) and `requestAnimationFrame` wait for it, and run
//   in their order as it passes them (a timeout of 0 still runs at once);
// - every animation (the runtime's transitions, `element.animate`, CSS transitions and animations,
//   `document.getAnimations()`) is held still, and `sync()` puts it where the moved clock says: as
//   far in as the clock has moved since it was first seen, finished once it is past its end.
//
// Timers made before `freeze()` keep their real time.
(() => {
	if (window.__rocxClock) return;
	const real = {
		setTimeout: window.setTimeout.bind(window),
		setInterval: window.setInterval.bind(window),
		clearTimeout: window.clearTimeout.bind(window),
		clearInterval: window.clearInterval.bind(window),
		requestAnimationFrame: window.requestAnimationFrame?.bind(window),
		cancelAnimationFrame: window.cancelAnimationFrame?.bind(window),
		now: performance.now.bind(performance),
		dateNow: Date.now,
		Date,
	};
	let frozen = false;
	// The clock, in performance.now()'s milliseconds, and the wall clock's at the same moment.
	let now = 0;
	let wall = 0;
	let next = 1;
	// Ids of our own go above the browser's, so a clear of either finds its own.
	const offset = 1 << 30;
	const timers = new Map();
	const frames = new Map();
	const seen = new WeakMap();

	window.setTimeout = (fn, ms = 0, ...args) => {
		if (!frozen || !(ms > 0)) return real.setTimeout(fn, ms, ...args);
		const id = offset + next++;
		timers.set(id, { at: now + ms, every: 0, fn, args, order: id });
		return id;
	};
	window.setInterval = (fn, ms = 0, ...args) => {
		if (!frozen) return real.setInterval(fn, ms, ...args);
		const id = offset + next++;
		const every = Math.max(1, Number(ms) || 0);
		timers.set(id, { at: now + every, every, fn, args, order: id });
		return id;
	};
	window.clearTimeout = window.clearInterval = (id) => {
		if (timers.delete(id)) return;
		real.clearTimeout(id);
	};
	window.requestAnimationFrame = (fn) => {
		if (!frozen) return real.requestAnimationFrame(fn);
		const id = offset + next++;
		frames.set(id, fn);
		return id;
	};
	window.cancelAnimationFrame = (id) => {
		if (frames.delete(id)) return;
		real.cancelAnimationFrame?.(id);
	};
	performance.now = () => (frozen ? now : real.now());
	const dateNow = () => (frozen ? wall + (now - frozenAt) : real.dateNow());
	let frozenAt = 0;
	class ClockDate extends real.Date {
		constructor(...args) {
			if (args.length === 0) super(dateNow());
			else super(...args);
		}
		static now() {
			return dateNow();
		}
	}
	window.Date = ClockDate;

	const call = (fn, args) => {
		try {
			typeof fn === "function" ? fn(...args) : (0, eval)(String(fn));
		} catch (error) {
			real.setTimeout(() => {
				throw error;
			});
		}
	};

	window.__rocxClock = {
		/** Stops real time: from now on, time moves only by `advance`. */
		freeze() {
			if (frozen) return;
			now = real.now();
			frozenAt = now;
			wall = real.dateNow();
			frozen = true;
		},
		get now() {
			return now;
		},
		/** Moves the clock `ms` on: each timer due on the way runs at its time, in order, then each
		 * animation frame asked for runs once, at the new time. */
		advance(ms) {
			const end = now + Math.max(0, ms);
			for (;;) {
				let due = null;
				for (const [id, timer] of timers) if (timer.at <= end && (!due || timer.at < due[1].at || (timer.at === due[1].at && timer.order < due[1].order))) due = [id, timer];
				if (!due) break;
				const [id, timer] = due;
				now = Math.max(now, timer.at);
				if (timer.every) timer.at += timer.every;
				else timers.delete(id);
				call(timer.fn, timer.args);
			}
			now = end;
			const asked = [...frames.values()];
			frames.clear();
			for (const fn of asked) call(fn, [now]);
		},
		/** Puts every animation where the clock says: held still, as far in as the clock has moved
		 * since it was first seen, or finished once past its end. */
		sync() {
			for (const animation of document.getAnimations()) {
				if (!seen.has(animation)) {
					seen.set(animation, now);
					animation.pause();
				}
				const t = now - seen.get(animation);
				const end = animation.effect?.getComputedTiming?.().endTime ?? Infinity;
				if (Number.isFinite(end) && t >= end) {
					if (animation.playState !== "finished") animation.finish();
				} else {
					if (animation.playState !== "paused") animation.pause();
					animation.currentTime = t;
				}
			}
		},
		/** Waits for the page to catch up: a few turns of its tasks (what a write runs is patched),
		 * its fonts, and its images. */
		async settle() {
			for (let i = 0; i < 3; i++) await new Promise((resolve) => real.setTimeout(resolve, 0));
			await document.fonts?.ready;
			const pending = [...document.images].filter((image) => !image.complete);
			const loaded = (image) =>
				new Promise((resolve) => {
					image.addEventListener("load", resolve, { once: true });
					image.addEventListener("error", resolve, { once: true });
				});
			await Promise.all(pending.map(loaded));
		},
	};
})();
