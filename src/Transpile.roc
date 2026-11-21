## rocx's transpiler: a .rocx file into plain Roc, line for line (was src/transpile.mjs).
import Value

Transpile := [].{

	## `rocx internal`'s calls of this module's functions (src/rocx.mjs names them), by name.
	rpc : Str, List(Value) -> Try(Value, [Failed(Value), Unknown(Str)])
	rpc = |name, _args| Err(Unknown(name))
}
