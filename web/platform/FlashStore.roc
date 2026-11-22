import Host

## Where a plain form's flash waits between its post and the page it goes back to
## (`Server.flash_back!`, `Server.flash!`). Each platform has its own: on the server, its memory
## (server/platform/FlashStore.roc); in the browser, the page, which the server noted the flash in.
FlashStore := [].{

	## Keeps a flash: the server's to do, where a plain form posts. The browser never answers a post.
	keep! : { url : Str, input : Str, status : U16, body : Str } => List({ name : Str, value : Str })
	keep! = |_| crash "a plain form's flash is kept by the server that answers its post (Server.flash_back!)"

	## The flash the page came with, as JSON (the server noted it in a script), whatever the cookie
	## says; "" with none. Rendered by web/runtime.js's renderToString (the tests'), the cookie's
	## value is the flash itself, noted for the page.
	read! : Str => Str
	read! = |found| Host.flash!(found)
}
