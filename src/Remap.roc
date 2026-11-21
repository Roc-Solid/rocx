## Points the Roc compiler's reports into .rocx files (was src/remap.mjs).
import Value

Remap := [].{

	## `rocx internal`'s calls of this module's functions (src/rocx.mjs names them), by name.
	rpc! : Str, List(Value) => Try(Value, [Failed(Value), Unknown(Str)])
	rpc! = |name, _args| Err(Unknown(name))
}
