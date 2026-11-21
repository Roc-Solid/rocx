## File-based routing, as SvelteKit has it (was src/routes.mjs).
import Value

Routes := [].{

	## `rocx internal`'s calls of this module's functions (src/rocx.mjs names them), by name.
	rpc! : Str, List(Value) => Try(Value, [Failed(Value), Unknown(Str)])
	rpc! = |name, _args| Err(Unknown(name))
}
