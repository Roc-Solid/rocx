// The audio plugin's script (packages/audio): the player. Every page loads it before start.js, so
// the effect it registers is there before the page wakes: `audio.play`, which `Audio.play!` calls
// (`Browser.call!("audio.play", { url, volume, rate })`), once the handler is done and the page is
// patched. A sound file, any the browser can, fetched the first time and kept by it, at a volume
// and a rate, its pitch moving with its speed. A URL that begins with `/` is the site's, under its
// base (`under`, which the runtime gives every effect). Until the reader has done something on the
// page the browser refuses to play it, and that is no failure.
function play({ url, volume = 1, rate = 1 }, { under = (path) => path } = {}) {
	if (typeof Audio === "undefined") return;
	const sound = new Audio(under(url));
	sound.volume = Math.min(Math.max(volume, 0), 1);
	sound.preservesPitch = false;
	sound.playbackRate = Math.min(Math.max(rate, 0.0625), 16);
	sound.play()?.catch((error) => {
		if (error?.name !== "NotAllowedError") console.error(`audio: the sound ${url} can't be played: ${error?.message ?? error}`);
	});
}

window.rocxEffects = { ...window.rocxEffects, "audio.play": play };
