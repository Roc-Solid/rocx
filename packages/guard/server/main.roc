## Guard on the server platform: its middleware (`Guard`), the rate limits' counts and the flags'
## overrides kept between requests (`Kept`, `FlagStore`, each an actor). A package that names the
## server platform, so that `roc check packages/guard/server/main.roc` checks these modules on their
## own. An app copies them in by hand for now: see ../README.md, and PROPOSALS.md, "Server-only
## modules in packages".
package [FlagStore, Guard, Kept] { guard: "../main.roc", pf: platform "../../../server/platform/main.roc" }
