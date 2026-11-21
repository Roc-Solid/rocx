## What the JS runtime does for Roc.
Host := [].{
	## The value under `key`; if it isn't there yet, the runtime aborts the caller (and runs it again later).
	async_read! : Str => Str
	## Starts getting the value under `key`, if nothing has yet; never aborts.
	async_start! : Str => {}
	## A cell holding any value: the host keeps the box.
	cell_new! : Box(a) => U64
	cell_get! : U64 => Box(a)
}
