## Scoped styles, as Svelte has them (was src/styles.mjs).
import Value

Styles := [].{

	## `rocx internal`'s calls of this module's functions (src/rocx.mjs names them), by name.
	rpc : Str, List(Value) -> Try(Value, [Failed(Value), Unknown(Str)])
	rpc = |name, _args| Err(Unknown(name))
}
