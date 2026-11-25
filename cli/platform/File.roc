import Host

File := [].{
	exists! : Str => Bool
	exists! = |path| Host.exists!(path)

	is_dir! : Str => Bool
	is_dir! = |path| Host.is_dir!(path)

	## Nanoseconds since the epoch; 0 when the file isn't there.
	modified! : Str => U64
	modified! = |path| Host.modified!(path)

	read! : Str => Try(Str, [CantRead(Str)])
	read! = |path|
		match Host.read!(path) {
			Ok(text) => Ok(text)
			Err(why) => Err(CantRead("${path}: ${why}"))
		}

	write! : Str, Str => Try({}, [CantWrite(Str)])
	write! = |path, text|
		match Host.write_file!(path, text) {
			Ok({}) => Ok({})
			Err(why) => Err(CantWrite("${path}: ${why}"))
		}

	## Writes bytes (an image, a wasm module), its directory made first.
	write_bytes! : Str, List(U8) => Try({}, [CantWrite(Str)])
	write_bytes! = |path, bytes|
		match Host.write_bytes!(path, bytes) {
			Ok({}) => Ok({})
			Err(why) => Err(CantWrite("${path}: ${why}"))
		}

	rename! : Str, Str => Try({}, [CantRename(Str)])
	rename! = |from, to|
		match Host.rename!(from, to) {
			Ok({}) => Ok({})
			Err(why) => Err(CantRename("${from} → ${to}: ${why}"))
		}

	real_path! : Str => Try(Str, [NotFound(Str)])
	real_path! = |path|
		match Host.real_path!(path) {
			Ok(real) => Ok(real)
			Err(why) => Err(NotFound("${path}: ${why}"))
		}

	make_dirs! : Str => Try({}, [CantWrite(Str)])
	make_dirs! = |path|
		match Host.make_dirs!(path) {
			Ok({}) => Ok({})
			Err(why) => Err(CantWrite("${path}: ${why}"))
		}

	list! : Str => Try(List(Str), [CantRead(Str)])
	list! = |path|
		match Host.list!(path) {
			Ok(names) => Ok(names)
			Err(why) => Err(CantRead("${path}: ${why}"))
		}

	## Deletes a file, or a directory and everything in it; nothing when there is nothing there.
	delete! : Str => Try({}, [CantDelete(Str)])
	delete! = |path|
		match Host.delete!(path) {
			Ok({}) => Ok({})
			Err(why) => Err(CantDelete("${path}: ${why}"))
		}

	## Copies a file, or a directory and everything in it, to `to`.
	copy! : Str, Str => Try({}, [CantCopy(Str)])
	copy! = |from, to|
		match Host.copy!(from, to) {
			Ok({}) => Ok({})
			Err(why) => Err(CantCopy("${from} → ${to}: ${why}"))
		}

	## Makes `link` a symbolic link to `target` (absolute, or from the link's directory), in place of
	## a link or a file already there, never a directory (a link that points elsewhere, or at nothing,
	## is mended this way): there is always something at `link` while it does.
	symlink! : Str, Str => Try({}, [CantLink(Str)])
	symlink! = |target, link|
		match Host.symlink!(target, link) {
			Ok({}) => Ok({})
			Err(why) => Err(CantLink("${link} → ${target}: ${why}"))
		}

	## Makes the file with this text, only if nothing is there yet, in one step no other process can
	## come between (a lock): `Exists` when something was.
	create_new! : Str, Str => Try({}, [Exists, CantWrite(Str)])
	create_new! = |path, text|
		match Host.create_new!(path, text) {
			Ok(Bool.True) => Ok({})
			Ok(Bool.False) => Err(Exists)
			Err(why) => Err(CantWrite("${path}: ${why}"))
		}
}
