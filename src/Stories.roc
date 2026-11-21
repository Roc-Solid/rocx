## Stories: the ways a component looks, and a dev build's catalog of them (was src/stories.mjs).
import Value

Stories := [].{

	## `rocx internal`'s calls of this module's functions (src/rocx.mjs names them), by name.
	rpc : Str, List(Value) -> Try(Value, [Failed(Value), Unknown(Str)])
	rpc = |name, _args| Err(Unknown(name))
}
