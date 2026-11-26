## `rocx build <dir> --image <file.tar> [--tag name:tag] [--target arm64musl|x64musl]` (D-099): the
## app's release (`Release`, a static Linux executable and the files it serves) as a container
## image, written by rocx itself: no Dockerfile, and no Docker to build it. The server is static
## (musl, its TLS roots inside it), so the image has no base: one layer with
##
## - `/app/server` and `/app/static/`, as `--release` makes them;
## - `/app/data/`, the working directory's `data/` (a SQLite or Turso app's file, `data/app.db`),
##   owned by the user it runs as, for a volume to be mounted there;
## - `/etc/passwd` and `/etc/group` naming that user (`nonroot`, 65532, as distroless's), and `/tmp`.
##
## It runs as 65532 in `/app`: `/app/server --host 0.0.0.0` (with `--static /app/static` when the app
## serves files), on PORT 8080. The file is an OCI image layout in a tar, with Docker's
## `manifest.json` beside it, as `docker save` writes them: `docker load -i <file>` (or podman's,
## or `skopeo copy oci-archive:<file> …` to a registry) takes it. The layer is gzipped by the
## system's `gzip`; the digests are Roc's SHA-256.
import pf.Cmd
import pf.File
import pf.Stderr
import pf.Time
import Fs
import Release
import Static
import Text
import Value

Image := [].{

	usage : Str
	usage = "usage: rocx build <dir> --image <file.tar> [--tag name:tag] [--target arm64musl|x64musl]"

	## What `rocx build … --image` was asked: the app's directory, the file, the image's name and
	## tag, and the target (`""`: this machine's Linux). Paths are absolute.
	Asked : { dir : Str, file : Str, tag : Str, target : Str }

	## The words after `rocx build`, read, with paths from `cwd`; `Usage` says what is wrong.
	options : List(Str), Str -> Try(Asked, [Usage(Str)])
	options = |args, cwd| {
		var $file = ""
		var $tag = ""
		var $target = ""
		var $dirs = []
		var $i = 0
		while $i < args.len() {
			arg = args.get($i) ?? ""
			value = args.get($i + 1) ?? ""
			if arg == "--image" or arg == "--tag" or arg == "--target" {
				if value.is_empty() or value.starts_with("--") {
					return Err(Usage("rocx build ${arg}: give it a value\n${Image.usage}"))
				}
				if arg == "--image" {
					$file = value
				} else if arg == "--tag" {
					$tag = value
				} else if value == "arm64musl" or value == "x64musl" {
					$target = value
				} else {
					return Err(Usage("rocx build --image --target: arm64musl or x64musl (a container is Linux), not ${value}"))
				}
				$i = $i + 2
			} else if arg.starts_with("-") {
				return Err(Usage("rocx build --image: not with ${arg}\n${Image.usage}"))
			} else {
				$dirs = $dirs.append(arg)
				$i = $i + 1
			}
		}
		if $dirs.len() != 1 or $file.is_empty() {
			return Err(Usage("rocx build --image: one directory, the app's, and the file the image goes to\n${Image.usage}"))
		}
		dir = Fs.resolve(cwd, [$dirs.first() ?? "."])
		tag = if ($tag.is_empty()) "${Image.name_of(Fs.basename(dir))}:latest" else if (Image.has_tag($tag)) $tag else "${$tag}:latest"
		Ok({ dir, file: Fs.resolve(cwd, [$file]), tag, target: $target })
	}

	## `rocx build <dir> --image <file> …` (the words after `build`), with the home of this rocx: exit
	## 2 for arguments it can't take, 1 when the build fails.
	run! : List(Str), Str => Try({}, [Exit(I32)])
	run! = |args, rocx| {
		cwd = Fs.cwd!()
		asked = match Image.options(args, cwd) {
			Ok(read) => read
			Err(Usage(message)) => {
				_ = Stderr.line!(message)
				return Err(Exit(2))
			}
		}
		match Image.made!(asked, cwd, rocx) {
			Ok(said) => {
				for line in said {
					_ = Stderr.line!(line)
				}
				Ok({})
			}
			Err(Failed(message)) => {
				_ = Stderr.line!("rocx build --image: ${message}")
				Err(Exit(1))
			}
		}
	}

	## The release built into the app's `build/image/release`, then the image from it.
	made! : Asked, Str, Str => Try(List(Str), [Failed(Str)])
	made! = |asked, cwd, rocx| {
		started = Time.now_ms!({})
		target = if (asked.target.is_empty()) Image.linux_of(Image.machine!({})) else asked.target
		work = Fs.join([asked.dir, "build", "image"])
		release = Fs.join([work, "release"])
		_ = Release.made!({ dir: asked.dir, out: release, target }, cwd, rocx)?
		static = Fs.join([release, "static"])
		serves = File.is_dir!(static)
		files = if (serves) Fs.files!(static, "", |_| Bool.False) else []
		server = Image.read!(Fs.join([release, "server"]))?
		var $entries = [
			Dir({ path: "app/", uid: 0, mode: Image.dir_mode }),
			Dir({ path: "app/data/", uid: Image.user, mode: Image.dir_mode }),
			Dir({ path: "etc/", uid: 0, mode: Image.dir_mode }),
			File({ path: "etc/group", mode: Image.file_mode, bytes: "root:x:0:\nnonroot:x:65532:\n".to_utf8() }),
			File({ path: "etc/passwd", mode: Image.file_mode, bytes: "root:x:0:0:root:/root:/sbin/nologin\nnonroot:x:65532:65532:nonroot:/home/nonroot:/sbin/nologin\n".to_utf8() }),
			Dir({ path: "tmp/", uid: 0, mode: Image.tmp_mode }),
			File({ path: "app/server", mode: Image.run_mode, bytes: server }),
		]
		if serves {
			inside = files.map(|path| Fs.relative(static, path))
			for dir in Image.parents(inside) {
				$entries = $entries.append(Dir({ path: "app/static/${dir}", uid: 0, mode: Image.dir_mode }))
			}
			for path in files {
				bytes = Image.read!(path)?
				$entries = $entries.append(File({ path: "app/static/${Fs.relative(static, path)}", mode: Image.file_mode, bytes }))
			}
		}
		_ = Stderr.line!("rocx: the image (its layer, gzipped, and its manifest)…")
		layer_tar = Image.tarred($entries)?
		diff_id = "sha256:${Crypto.SHA256.hash(layer_tar).to_hex()}"
		layer_file = Fs.join([work, "layer.tar"])
		Fs.delete!("${layer_file}.gz")
		Image.write!(layer_file, layer_tar)?
		# The system's gzip, without the name and time (`-n`), so the same layer zips the same.
		zipped = match Cmd.new("gzip").args(["-n", "-9", "-f", layer_file]).output!() {
			Ok(ran) if ran.code == 0 => Image.read!("${layer_file}.gz")?
			Ok(ran) => return Err(Failed("gzip failed: ${ran.stderr}"))
			Err(CantStart(why)) => return Err(Failed("can't run gzip: ${why}"))
		}
		layer = Image.blob_of(zipped)
		entrypoint = ["/app/server", "--host", "0.0.0.0"].concat(if (serves) ["--static", "/app/static"] else [])
		config = Image.blob_of(Value.encode(Image.config_of({ arch: Image.arch_of(target), diff_id, entrypoint, created: Image.iso_time(Time.now_ms!({})) })).to_utf8())
		manifest = Image.blob_of(Value.encode(Image.manifest_of(config, layer)).to_utf8())
		archive = Image.tarred([
			File({ path: "oci-layout", mode: Image.file_mode, bytes: "{\"imageLayoutVersion\":\"1.0.0\"}".to_utf8() }),
			File({ path: "index.json", mode: Image.file_mode, bytes: Value.encode(Image.index_of(manifest, asked.tag)).to_utf8() }),
			File({ path: "manifest.json", mode: Image.file_mode, bytes: Value.encode(Image.docker_list(config, layer, asked.tag)).to_utf8() }),
			File({ path: "blobs/sha256/${config.hex}", mode: Image.file_mode, bytes: config.bytes }),
			File({ path: "blobs/sha256/${manifest.hex}", mode: Image.file_mode, bytes: manifest.bytes }),
			File({ path: "blobs/sha256/${layer.hex}", mode: Image.file_mode, bytes: layer.bytes }),
		])?
		Fs.make_dirs!(Fs.dirname(asked.file))
		Image.write!(asked.file, archive)?
		Fs.delete!("${layer_file}.gz")
		shown = Static.shown(cwd, asked.file)
		Ok([
			"rocx build --image: ${shown}, ${asked.tag} (linux/${Image.arch_of(target)}) in ${Image.seconds(Time.now_ms!({}) - started)} s: ${Image.megabytes(zipped.len())} to send, ${Image.megabytes(layer_tar.len())} unpacked",
			"docker load -i ${shown}, then run it with a volume at /app/data for its database (PORT 8080; DATABASE_URL, PUBLIC_URL…).",
		])
	}

	## The user the server runs as: distroless's `nonroot`.
	user : U64
	user = 65532

	## The modes, in decimal: 0755 for a directory, 0644 for a file, 0755 for the server, 1777 for
	## `/tmp` (anyone writes, only the owner deletes).
	dir_mode : U64
	dir_mode = 493

	file_mode : U64
	file_mode = 420

	run_mode : U64
	run_mode = 493

	tmp_mode : U64
	tmp_mode = 1023

	## A file's bytes, or why not, as the build says it.
	read! : Str => Try(List(U8), [Failed(Str)])
	read! = |path|
		match File.read_bytes!(path) {
			Ok(bytes) => Ok(bytes)
			Err(CantRead(why)) => Err(Failed(why))
		}

	## Writes `bytes` to `path`, or says why not.
	write! : Str, List(U8) => Try({}, [Failed(Str)])
	write! = |path, bytes|
		match File.write_bytes!(path, bytes) {
			Ok({}) => Ok({})
			Err(CantWrite(why)) => Err(Failed(why))
		}

	## `tar`, its refusal as the build says it.
	tarred : List(Image.Entry) -> Try(List(U8), [Failed(Str)])
	tarred = |entries|
		match Image.tar(entries) {
			Ok(bytes) => Ok(bytes)
			Err(TooLong(path)) => Err(Failed("${path}: a path too long for a tar's header"))
		}

	## What a layer holds: a directory (its path ending in `/`) or a file, owned by root but where
	## `uid` says.
	Entry : [Dir({ path : Str, uid : U64, mode : U64 }), File({ path : Str, mode : U64, bytes : List(U8) })]

	## A blob of the layout: its bytes, their SHA-256 in hex, and its descriptor's digest.
	Blob : { bytes : List(U8), hex : Str, digest : Str }

	blob_of : List(U8) -> Image.Blob
	blob_of = |bytes| {
		hex = Crypto.SHA256.hash(bytes).to_hex()
		{ bytes, hex, digest: "sha256:${hex}" }
	}

	## The image's configuration (the OCI image spec's): how it runs, and its layer's digest
	## uncompressed (`diff_id`).
	config_of : { arch : Str, diff_id : Str, entrypoint : List(Str), created : Str } -> Value
	config_of = |{ arch, diff_id, entrypoint, created }|
		Object([
			{ key: "created", value: Text(created) },
			{ key: "architecture", value: Text(arch) },
			{ key: "os", value: Text("linux") },
			{
				key: "config",
				value: Object([
					{ key: "User", value: Text("65532:65532") },
					{ key: "Env", value: Value.strs(["PATH=/app", "PORT=8080"]) },
					{ key: "Entrypoint", value: Value.strs(entrypoint) },
					{ key: "WorkingDir", value: Text("/app") },
					{ key: "ExposedPorts", value: Object([{ key: "8080/tcp", value: Object([]) }]) },
				]),
			},
			{ key: "rootfs", value: Object([{ key: "type", value: Text("layers") }, { key: "diff_ids", value: Value.strs([diff_id]) }]) },
			{ key: "history", value: Array([Object([{ key: "created", value: Text(created) }, { key: "created_by", value: Text("rocx build --image") }])]) },
		])

	## The image's manifest: its configuration and its one layer, gzipped.
	manifest_of : Image.Blob, Image.Blob -> Value
	manifest_of = |config, layer|
		Object([
			{ key: "schemaVersion", value: Number(2) },
			{ key: "mediaType", value: Text("application/vnd.oci.image.manifest.v1+json") },
			{ key: "config", value: Image.descriptor("application/vnd.oci.image.config.v1+json", config, []) },
			{ key: "layers", value: Array([Image.descriptor("application/vnd.oci.image.layer.v1.tar+gzip", layer, [])]) },
		])

	## The layout's index: the manifest, named as Docker and containerd read a name.
	index_of : Image.Blob, Str -> Value
	index_of = |manifest, tag|
		Object([
			{ key: "schemaVersion", value: Number(2) },
			{ key: "mediaType", value: Text("application/vnd.oci.image.index.v1+json") },
			{
				key: "manifests",
				value: Array([
					Image.descriptor(
						"application/vnd.oci.image.manifest.v1+json",
						manifest,
						[
							{ key: "io.containerd.image.name", value: Text(Image.full_name(tag)) },
							{ key: "org.opencontainers.image.ref.name", value: Text(Image.tag_of(tag)) },
						],
					),
				]),
			},
		])

	## `docker save`'s own list, for a Docker that reads no OCI layout.
	docker_list : Image.Blob, Image.Blob, Str -> Value
	docker_list = |config, layer, tag|
		Array([
			Object([
				{ key: "Config", value: Text("blobs/sha256/${config.hex}") },
				{ key: "RepoTags", value: Value.strs([tag]) },
				{ key: "Layers", value: Value.strs(["blobs/sha256/${layer.hex}"]) },
			]),
		])

	descriptor : Str, Image.Blob, List({ key : Str, value : Value }) -> Value
	descriptor = |media_type, blob, annotations|
		Object(
			[
				{ key: "mediaType", value: Text(media_type) },
				{ key: "digest", value: Text(blob.digest) },
				{ key: "size", value: Number(blob.bytes.len().to_i64_wrap()) },
			].concat(if (annotations.is_empty()) [] else [{ key: "annotations", value: Object(annotations) }]),
		)

	## Whether `name` has a tag after its last `/` (`ghcr.io:443/x` has none).
	has_tag : Str -> Bool
	has_tag = |name| {
		last = (name.split_on("/").last() ?? name)
		last.contains(":")
	}

	## The tag of `name:tag`.
	tag_of : Str -> Str
	tag_of = |name| (name.split_on("/").last() ?? name).split_on(":").last() ?? "latest"

	## A name as containerd keeps it: a Docker Hub name in full (`docker.io/library/notes:1`).
	full_name : Str -> Str
	full_name = |name| {
		parts = name.split_on("/")
		first = parts.first() ?? ""
		if parts.len() == 1 {
			"docker.io/library/${name}"
		} else if first.contains(".") or first.contains(":") or first == "localhost" {
			name
		} else {
			"docker.io/${name}"
		}
	}

	## A directory's name as an image's name: lower case, letters, digits, `-`, `_` and `.`.
	name_of : Str -> Str
	name_of = |dir| {
		kept = dir.to_utf8().keep_oks(
			|byte|
				if byte >= 'A' and byte <= 'Z' {
					Ok(byte + 32)
				} else if (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '_' or byte == '.' {
					Ok(byte)
				} else {
					Err(Skipped)
				},
		)
		named = Str.from_utf8_lossy(kept)
		if (named.is_empty()) "app" else named
	}

	## This machine's processor, as `uname -m` says it.
	machine! : {} => Str
	machine! = |{}|
		match Cmd.new("uname").args(["-m"]).output!() {
			Ok(ran) if ran.code == 0 => Text.trim(ran.stdout)
			_ => ""
		}

	## The Linux target for a processor: x64musl for x86_64, else arm64musl.
	linux_of : Str -> Str
	linux_of = |machine| if (machine == "x86_64" or machine == "amd64") "x64musl" else "arm64musl"

	## A target's architecture, as an image's configuration names it.
	arch_of : Str -> Str
	arch_of = |target| if (target == "x64musl") "amd64" else "arm64"

	## The directories `files` (paths, `/` between their parts) are in, each once, parents first,
	## each ending in `/`.
	parents : List(Str) -> List(Str)
	parents = |files| {
		var $dirs = []
		for file in files {
			parts = file.split_on("/").drop_last(1)
			var $at = ""
			for part in parts {
				$at = "${$at}${part}/"
				if !$dirs.contains($at) {
					$dirs = $dirs.append($at)
				}
			}
		}
		$dirs
	}

	## A tar (POSIX ustar) of `entries`, in order, every time 0 but the owners and modes theirs, then
	## the two empty blocks that end one. `TooLong` for a path no header can hold.
	tar : List(Image.Entry) -> Try(List(U8), [TooLong(Str)])
	tar = |entries| {
		var $out = []
		for entry in entries {
			match entry {
				Dir({ path, uid, mode }) => {
					$out = $out.concat(Image.header({ path, mode, uid, size: 0, kind: '5' })?)
				}
				File({ path, mode, bytes }) => {
					$out = $out.concat(Image.header({ path, mode, uid: 0, size: bytes.len(), kind: '0' })?).concat(bytes).concat(List.repeat(0, Image.padding(bytes.len())))
				}
			}
		}
		Ok($out.concat(List.repeat(0, 1024)))
	}

	## The zeros that fill a file's last block.
	padding : U64 -> U64
	padding = |size| if (size % 512 == 0) 0 else 512 - size % 512

	## A ustar header: 512 bytes, the path in `name` (and `prefix` when it is longer than 100), the
	## numbers in octal, the owner's name beside its id, and the checksum over it all.
	header : { path : Str, mode : U64, uid : U64, size : U64, kind : U8 } -> Try(List(U8), [TooLong(Str)])
	header = |{ path, mode, uid, size, kind }| {
		(prefix, name) = Image.split_path(path)?
		owner = if (uid == 0) "root" else "nonroot"
		before = Image.field(name.to_utf8(), 100)
			.concat(Image.octal(mode, 8))
			.concat(Image.octal(uid, 8))
			.concat(Image.octal(uid, 8))
			.concat(Image.octal(size, 12))
			.concat(Image.octal(0, 12))
		after = [kind]
			.concat(List.repeat(0, 100))
			.concat("ustar".to_utf8())
			.concat([0])
			.concat("00".to_utf8())
			.concat(Image.field(owner.to_utf8(), 32))
			.concat(Image.field(owner.to_utf8(), 32))
			.concat(Image.octal(0, 8))
			.concat(Image.octal(0, 8))
			.concat(Image.field(prefix.to_utf8(), 155))
			.concat(List.repeat(0, 12))
		sum = before.concat(List.repeat(' ', 8)).concat(after).fold(0, |total, byte| total + byte.to_u64())
		checksum = Image.digits(sum, 6).concat([0, ' '])
		Ok(before.concat(checksum).concat(after))
	}

	## A path as ustar holds it: all of it in `name` when it fits in 100 bytes, else split at a `/`
	## into a `prefix` of up to 155 and a name of up to 100.
	split_path : Str -> Try((Str, Str), [TooLong(Str)])
	split_path = |path| {
		bytes = path.to_utf8()
		if bytes.len() <= 100 {
			return Ok(("", path))
		}
		var $i = bytes.len()
		while $i > 0 {
			$i = $i - 1
			if bytes.get($i) == Ok('/') and $i <= 155 and bytes.len() - $i - 1 <= 100 and bytes.len() - $i - 1 > 0 {
				return Ok((Str.from_utf8_lossy(bytes.sublist({ start: 0, len: $i })), Str.from_utf8_lossy(bytes.sublist({ start: $i + 1, len: bytes.len() - $i - 1 }))))
			}
		}
		Err(TooLong(path))
	}

	## `bytes` in a field of `width`, the rest zeros (cut to fit).
	field : List(U8), U64 -> List(U8)
	field = |bytes, width| {
		kept = bytes.take_first(width)
		kept.concat(List.repeat(0, width - kept.len()))
	}

	## `n` in octal in a field of `width`: `width - 1` digits, zero-padded, and a NUL.
	octal : U64, U64 -> List(U8)
	octal = |n, width| Image.digits(n, width - 1).append(0)

	## `n` in octal, `count` digits, zero-padded.
	digits : U64, U64 -> List(U8)
	digits = |n, count| {
		var $out = []
		var $left = n
		var $i = 0
		while $i < count {
			$out = $out.prepend('0' + ($left % 8).to_u8_wrap())
			$left = $left // 8
			$i = $i + 1
		}
		$out
	}

	## A time in milliseconds since 1970 as RFC 3339, in UTC to the second (`2026-11-26T18:04:05Z`).
	iso_time : U64 -> Str
	iso_time = |ms| {
		whole = ms.to_i64_wrap() // 1000
		days = whole // 86400
		of_day = whole % 86400
		# Days to the civil date (Hinnant's `civil_from_days`).
		z = days + 719468
		era = (if (z >= 0) z else z - 146096) // 146097
		doe = z - era * 146097
		yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
		doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
		mp = (5 * doy + 2) // 153
		day = doy - (153 * mp + 2) // 5 + 1
		month = if (mp < 10) mp + 3 else mp - 9
		year = yoe + era * 400 + (if (month <= 2) 1 else 0)
		two = |n| if (n < 10) "0${n.to_str()}" else n.to_str()
		"${year.to_str()}-${two(month)}-${two(day)}T${two(of_day // 3600)}:${two(of_day % 3600 // 60)}:${two(of_day % 60)}Z"
	}

	## Milliseconds as seconds, to a tenth.
	seconds : U64 -> Str
	seconds = |ms| "${(ms // 1000).to_str()}.${(ms % 1000 // 100).to_str()}"

	## Bytes as megabytes (10⁶), to a tenth.
	megabytes : U64 -> Str
	megabytes = |bytes| "${(bytes // 1000000).to_str()}.${(bytes % 1000000 // 100000).to_str()} MB"
}

expect Image.digits(8, 3) == "010".to_utf8()
expect Image.octal(Image.dir_mode, 8) == "0000755".to_utf8().append(0)
expect Image.digits(Image.tmp_mode, 4) == "1777".to_utf8() and Image.digits(Image.file_mode, 4) == "0644".to_utf8()
expect Image.padding(0) == 0 and Image.padding(1) == 511 and Image.padding(512) == 0 and Image.padding(513) == 511
expect Image.split_path("app/server") == Ok(("", "app/server"))
expect {
	long = "app/static/${Str.repeat("a", 90)}/${Str.repeat("b", 60)}.js"
	Image.split_path(long) == Ok(("app/static/${Str.repeat("a", 90)}", "${Str.repeat("b", 60)}.js"))
}
expect Image.split_path(Str.repeat("x", 120)) == Err(TooLong(Str.repeat("x", 120)))
expect {
	made = Image.header({ path: "app/server", mode: Image.dir_mode, uid: 0, size: 3, kind: '0' })
	match made {
		Ok(bytes) => bytes.len() == 512 and bytes.sublist({ start: 257, len: 5 }) == "ustar".to_utf8()
		Err(_) => Bool.False
	}
}
# The checksum is the sum of the header's bytes with its own field as eight spaces.
expect {
	made = Image.header({ path: "a", mode: Image.file_mode, uid: 0, size: 0, kind: '0' }) ?? []
	sum = made.sublist({ start: 0, len: 148 }).concat(List.repeat(' ', 8)).concat(made.sublist({ start: 156, len: 356 })).fold(0, |total, byte| total + byte.to_u64())
	made.sublist({ start: 148, len: 8 }) == Image.digits(sum, 6).concat([0, ' '])
}
expect Image.tar([]) == Ok(List.repeat(0, 1024))
expect (Image.tar([File({ path: "a", mode: Image.file_mode, bytes: [1, 2, 3] })]) ?? []).len() == 512 + 512 + 1024
expect Image.parents(["a.css", "rocx/app.wasm", "rocx/x/y.js"]) == ["rocx/", "rocx/x/"]
expect Image.has_tag("notes:1") and !Image.has_tag("localhost:5000/notes") and Image.has_tag("localhost:5000/notes:2")
expect Image.full_name("notes:1") == "docker.io/library/notes:1"
expect Image.full_name("ghcr.io/acme/notes:1") == "ghcr.io/acme/notes:1"
expect Image.full_name("acme/notes:1") == "docker.io/acme/notes:1"
expect Image.tag_of("ghcr.io/acme/notes:abc") == "abc"
expect Image.name_of("Acme Notes") == "acmenotes"
expect Image.iso_time(0) == "1970-01-01T00:00:00Z"
expect Image.iso_time(1_795_716_245_000) == "2026-11-26T18:04:05Z" and Image.iso_time(951_782_400_000) == "2000-02-29T00:00:00Z"
expect Image.megabytes(23_456_789) == "23.4 MB"
expect Image.options(["app", "--image", "out/app.tar"], "/w") == Ok({ dir: "/w/app", file: "/w/out/app.tar", tag: "app:latest", target: "" })
expect Image.options(["app", "--image", "a.tar", "--tag", "ghcr.io/x/app", "--target", "x64musl"], "/w") == Ok({ dir: "/w/app", file: "/w/a.tar", tag: "ghcr.io/x/app:latest", target: "x64musl" })
expect {
	read = Image.options(["app", "--image", "a.tar", "--target", "arm64mac"], "/w")
	match read {
		Err(Usage(_)) => Bool.True
		Ok(_) => Bool.False
	}
}
