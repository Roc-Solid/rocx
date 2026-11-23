// The fixture plugin's script (server/test/fixture): every page loads it, before start.js. It
// registers an effect, as a plugin's script does, named with the plugin's name first.
window.rocxEffects = { ...window.rocxEffects, "fixture.mark": (arg, { under }) => (window.fixtureMarked = under(arg.url)) };
window.fixtureLoaded = true;
