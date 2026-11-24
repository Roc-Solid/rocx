// The vibrate plugin's script (packages/vibrate): every page loads it before start.js, so the
// effect it registers is there before the page wakes: `vibrate.pattern`, which `Vibrate.once!`
// and `Vibrate.pattern!` call (`Browser.call!("vibrate.pattern", { pattern })`), once the handler
// is done and the page is patched. Milliseconds on, off, on…, as `navigator.vibrate` takes them. A
// browser with no motor, or none it lets a page use, does nothing, and that is no failure.
function vibrate({ pattern = [] }) {
	if (typeof navigator === "undefined" || typeof navigator.vibrate !== "function") return;
	try {
		navigator.vibrate(pattern);
	} catch {
		// A page the reader hasn't touched yet may not buzz.
	}
}

window.rocxEffects = { ...window.rocxEffects, "vibrate.pattern": vibrate };
