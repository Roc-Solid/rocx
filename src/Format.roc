## rocx fmt: a .rocx file's Roc formatted by `roc fmt`, its markup kept as written (was src/format.mjs).
import Value

Format := [].{

	## `rocx internal`'s calls of this module's functions (src/rocx.mjs names them), by name.
	rpc! : Str, List(Value) => Try(Value, [Failed(Value), Unknown(Str)])
	rpc! = |name, _args| Err(Unknown(name))
}
