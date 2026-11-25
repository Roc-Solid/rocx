## Versions of rocx (D-078): which one this is (an installed version's folder has a `VERSION`; a
## clone has none), which one an app wants (its `.rocx-version`, committed), the app's link to it
## (`.rocx`, gitignored, which its headers reach the platform and packages through), the version an
## app wants run in this one's place (installed first when it isn't, as rustup does), and `rocx
## upgrade`.
##
## Installed versions are in `$ROCX_HOME` (else `~/.rocx`): `versions/<v>/`, `current` (a link to the
## default one) and `bin/rocx`. A release is installed by its own `install.sh`, from
## `$ROCX_RELEASES` (else GitHub's releases of Roc-Solid/rocx; a directory laid out as they are
## will do, for tests): `<releases>/download/v<v>/install.sh`, or the latest's,
## `<releases>/latest/download/install.sh`.
import pf.Cmd
import pf.Env
import pf.File
import pf.Stderr
import pf.Stdout
import Fs
import Text

Versions := [].{

	## The commands that work on an app, and so run the version it wants.
	app_commands : List(Str)
	app_commands = ["dev", "build", "check", "test", "routes", "lint"]

	## Where releases come from: `ROCX_RELEASES` (a URL, or a directory laid out as one), else
	## GitHub's.
	releases! : {} => Str
	releases! = |{}| Env.var!("ROCX_RELEASES") ?? "https://github.com/Roc-Solid/rocx/releases"

	## Where versions are installed: `ROCX_HOME`, else `~/.rocx`.
	install_root! : {} => Str
	install_root! = |{}|
		match Env.var!("ROCX_HOME") {
			Ok(given) => given
			Err(NotFound) => Fs.join([Env.var!("HOME") ?? "/", ".rocx"])
		}

	## Where version `version` is (or would be) installed: `<install root>/versions/<version>`.
	installed : Str, Str -> Str
	installed = |install_root, version| Fs.join([install_root, "versions", version])

	## The version of the rocx at `home`: the first word of its `VERSION`; "" for a clone, which has
	## none.
	own! : Str => Str
	own! = |home| Versions.first_word(Fs.read_or_empty!(Fs.join([home, "VERSION"])))

	## The version the app at `dir` wants: the first word of its `.rocx-version`; "" when it has none
	## (an app in the repo, whose headers reach the platform by `../`).
	wanted! : Str => Str
	wanted! = |dir| Versions.first_word(Fs.read_or_empty!(Fs.join([dir, ".rocx-version"])))

	## The first word of a text, its spaces and line ends around it gone.
	first_word : Str -> Str
	first_word = |text| Text.trim(text).split_on(" ").first() ?? ""

	## Whether `version` can name a folder and a release: letters, digits, `.`, `-` and `_`, never
	## `..` (`2026.11.25`, `2026.11.25.2`).
	is_version : Str -> Bool
	is_version = |version| !version.is_empty() and !version.contains("..") and !version.starts_with(".") and version.to_utf8().all(|byte| Text.is_word(byte) or byte == '.' or byte == '-')

	## Whether the rocx at `home` comes from Nix, which manages its versions: rocx never downloads one.
	is_nix : Str -> Bool
	is_nix = |home| home.starts_with("/nix/store/")

	## `rocx --version`: the `VERSION` of the rocx at `home` (version, commit, the compiler's pin);
	## from a clone, which has none, its commit.
	line! : Str => Str
	line! = |home| {
		version = Text.trim(Fs.read_or_empty!(Fs.join([home, "VERSION"])))
		if !version.is_empty() {
			return "rocx ${version}"
		}
		commit =
			match Cmd.new("git").args(["-C", home, "rev-parse", "--short", "HEAD"]).output!() {
				Ok(ran) if ran.code == 0 => Text.trim(ran.stdout)
				_ => ""
			}
		if (commit.is_empty()) "rocx from a clone at ${home}" else "rocx from a clone at ${commit} (${home})"
	}

	## The app at `dir`'s `.rocx` made a link to `home` (an installed version, or a clone), unless it
	## is one already: made when missing, mended when it points elsewhere or at nothing. A `.rocx` that
	## is a directory of its own is left alone.
	link! : Str, Str => Try({}, [Failed(Str)])
	link! = |dir, home| {
		linked = Fs.join([dir, ".rocx"])
		match File.real_path!(linked) {
			Ok(real) if real == Fs.real!(home) => return Ok({})
			Ok(real) if real == Fs.join([Fs.real!(dir), ".rocx"]) and File.is_dir!(linked) => return Ok({})
			_ => {}
		}
		match File.symlink!(home, linked) {
			Ok({}) => {
				_ = Stderr.line!("rocx: ${Fs.basename(dir)}/.rocx links to ${home} now")
				Ok({})
			}
			Err(CantLink(why)) => Err(Failed("rocx: can't link the app to rocx: ${why}"))
		}
	}

	## Before a command on the app at `dir` (`args`: all of rocx's words): when the app names a
	## version (`.rocx-version`) and this rocx is another installed one, that version runs the command
	## in this one's place (installed first if it isn't); otherwise the app's `.rocx` is made to link
	## here. A clone (no `VERSION`) runs every app's command itself, linked to the clone. `Ok` when
	## this rocx goes on with the command.
	dispatch! : Str, Str, List(Str) => Try({}, [Exit(I32)])
	dispatch! = |home, dir, args| {
		wanted = Versions.wanted!(dir)
		if wanted.is_empty() {
			return Ok({})
		}
		if !Versions.is_version(wanted) {
			_ = Stderr.line!("rocx: ${Fs.join([dir, ".rocx-version"])} says ${Text.json_string(wanted)}, which isn't a version of rocx (2026.11.25)")
			return Err(Exit(2))
		}
		own = Versions.own!(home)
		if own.is_empty() or own == wanted {
			return
				match Versions.link!(dir, home) {
					Ok({}) => Ok({})
					Err(Failed(why)) => {
						_ = Stderr.line!(why)
						Err(Exit(1))
					}
				}
		}
		if Env.var!("ROCX_DISPATCHED") == Ok(wanted) {
			_ = Stderr.line!("rocx: rocx ${own} was run for this app's rocx ${wanted}, and isn't it: ${Versions.installed(Versions.install_root!({}), wanted)} is broken (rocx upgrade ${wanted} installs it again)")
			return Err(Exit(1))
		}
		if Versions.is_nix(home) {
			_ = Stderr.line!("rocx: this app wants rocx ${wanted} (its .rocx-version), and Nix gives rocx ${own} (${home}): bump the flake input that gives rocx to v${wanted}, or change .rocx-version")
			return Err(Exit(1))
		}
		binary = Fs.join([Versions.installed(Versions.install_root!({}), wanted), "bin", "rocx"])
		if !File.exists!(binary) {
			_ = Stderr.line!("rocx: this app wants rocx ${wanted} (its .rocx-version), and this is rocx ${own}: installing rocx ${wanted}")
			match Versions.install!(Exact(wanted), Bool.True) {
				Ok({}) => {}
				Err(Failed(why)) => {
					_ = Stderr.line!(why)
					return Err(Exit(1))
				}
			}
			if !File.exists!(binary) {
				_ = Stderr.line!("rocx: installing rocx ${wanted} put no ${binary}")
				return Err(Exit(1))
			}
		}
		match Cmd.new(binary).args(args).env("ROCX_DISPATCHED", wanted).exec!() {
			Ok({}) => Ok({})
			Err(CantStart(why)) => {
				_ = Stderr.line!("rocx: can't run rocx ${wanted}: ${why}")
				Err(Exit(1))
			}
		}
	}

	## A release installed by its own `install.sh` (the latest release's, or version `v`'s), run with
	## `--no-modify-path` and `ROCX_HOME` (what it does is said as it runs). With `keep_current`,
	## `current` is put back as it was: a version installed for an app alone isn't the default.
	install! : [Latest, Exact(Str)], Bool => Try({}, [Failed(Str)])
	install! = |which, keep_current| {
		install_root = Versions.install_root!({})
		releases = Versions.releases!({})
		named =
			match which {
				Latest => ["latest", "download", "install.sh"]
				Exact(version) => ["download", "v${version}", "install.sh"]
			}
		what =
			match which {
				Latest => "the latest rocx"
				Exact(version) => "rocx ${version}"
			}
		Fs.make_dirs!(install_root)
		script = Fs.join([install_root, ".install-${Env.pid!({}).to_str()}.sh"])
		if releases.starts_with("/") {
			match File.copy!(Fs.join([releases].concat(named)), script) {
				Ok({}) => {}
				Err(CantCopy(why)) => return Err(Failed("rocx: no install.sh for ${what}: ${why}"))
			}
		} else {
			url = Str.join_with([releases.drop_suffix("/")].concat(named), "/")
			match Cmd.new("curl").args(["-fsSL", "--retry", "2", "-o", script, url]).output!() {
				Ok(ran) if ran.code == 0 => {}
				Ok(ran) => return Err(Failed("rocx: can't download ${url}: ${Text.trim(ran.stderr)}"))
				Err(CantStart(why)) => return Err(Failed("rocx: downloading ${what} needs curl: ${why}"))
			}
		}
		current = Fs.join([install_root, "current"])
		before = File.real_path!(current)
		ran = Cmd.new("sh").args([script, "--no-modify-path"]).env("ROCX_HOME", install_root).status!()
		Fs.delete!(script)
		match ran {
			Ok(0) => {}
			Ok(code) => return Err(Failed("rocx: installing ${what} failed (install.sh exited ${code.to_str()})"))
			Err(CantStart(why)) => return Err(Failed("rocx: can't run install.sh: ${why}"))
		}
		now = File.real_path!(current) ?? ""
		match before {
			Ok(was) if keep_current and now != was =>
				match File.symlink!(Fs.join(["versions", Versions.version_at!(install_root, was)]), current) {
					Ok({}) => Ok({})
					Err(CantLink(why)) => Err(Failed("rocx: can't put ${current} back: ${why}"))
				}
			_ => Ok({})
		}
	}

	## The version installed at `real` (a real path): the name of the folder under `versions/` that is
	## it (or links to it), else the folder's own name.
	version_at! : Str, Str => Str
	version_at! = |install_root, real| {
		versions = Fs.join([install_root, "versions"])
		for name in Fs.entries!(versions) {
			if Fs.real!(Fs.join([versions, name])) == real {
				return name
			}
		}
		Fs.basename(real)
	}

	## `rocx upgrade [<version>]` (the words after `upgrade`), from the rocx at `home`: the version
	## (else the latest) installed, unless it is already, and made the default (`current`); in an app
	## (a `.rocx-version` here), the app moved onto it: its `.rocx-version` written and its `.rocx`
	## linked to it. A rocx from Nix refuses: Nix manages its versions.
	upgrade! : List(Str), Str => Try({}, [Exit(I32)])
	upgrade! = |args, home| {
		if args.len() > 1 or args.any(|arg| arg.starts_with("-")) {
			_ = Stderr.line!("usage: rocx upgrade [<version>]")
			return Err(Exit(2))
		}
		if Versions.is_nix(home) {
			_ = Stderr.line!("rocx upgrade: this rocx comes from Nix (${home}), which manages its versions: bump the flake input that gives rocx instead")
			return Err(Exit(1))
		}
		install_root = Versions.install_root!({})
		current = Fs.join([install_root, "current"])
		version =
			match args.first() {
				Ok(given) => {
					if !Versions.is_version(given) {
						_ = Stderr.line!("rocx upgrade: ${Text.json_string(given)} isn't a version of rocx (2026.11.25)")
						return Err(Exit(2))
					}
					if File.exists!(Fs.join([Versions.installed(install_root, given), "bin", "rocx"])) {
						match File.symlink!(Fs.join(["versions", given]), current) {
							Ok({}) => {}
							Err(CantLink(why)) => return Versions.failed!("rocx upgrade: ${why}")
						}
					} else {
						match Versions.install!(Exact(given), Bool.False) {
							Ok({}) => {}
							Err(Failed(why)) => return Versions.failed!(why)
						}
					}
					given
				}
				Err(_) => {
					match Versions.install!(Latest, Bool.False) {
						Ok({}) => {}
						Err(Failed(why)) => return Versions.failed!(why)
					}
					match File.real_path!(current) {
						Ok(real) => Versions.version_at!(install_root, real)
						Err(_) => return Versions.failed!("rocx upgrade: the latest release's install.sh left no ${current}")
					}
				}
			}
		at = Versions.installed(install_root, version)
		if !File.exists!(Fs.join([at, "bin", "rocx"])) {
			return Versions.failed!("rocx upgrade: there is no ${Fs.join([at, "bin", "rocx"])} after installing rocx ${version}")
		}
		_ = Stdout.line!("rocx upgrade: rocx ${version} is the default now (${at})")
		dir = Fs.cwd!()
		if File.exists!(Fs.join([dir, ".rocx-version"])) {
			if Versions.wanted!(dir) != version {
				match Fs.write!(Fs.join([dir, ".rocx-version"]), "${version}\n") {
					Ok({}) => {}
					Err(_) => return Versions.failed!("rocx upgrade: can't write .rocx-version")
				}
			}
			match Versions.link!(dir, at) {
				Ok({}) => {}
				Err(Failed(why)) => return Versions.failed!(why)
			}
			_ = Stdout.line!("rocx upgrade: this app uses rocx ${version} (.rocx-version); commit it")
		}
		Ok({})
	}

	## Says why, and fails (exit 1).
	failed! : Str => Try(a, [Exit(I32)])
	failed! = |why| {
		_ = Stderr.line!(why)
		Err(Exit(1))
	}

	## The app directory a command's words name (the words after the command): the first that isn't
	## an option or an option's value, before `--`; else here (`.`).
	app_dir : List(Str) -> Str
	app_dir = |words| {
		valued = ["--port", "--client", "--static", "--base", "--route", "--built", "--release", "--target", "--engine", "--server"]
		var $value_next = Bool.False
		for word in words {
			if word == "--" {
				return "."
			}
			if $value_next {
				$value_next = Bool.False
			} else if valued.contains(word) {
				$value_next = Bool.True
			} else if !word.starts_with("-") {
				return word
			}
		}
		"."
	}
}

expect Versions.app_dir(["--port", "9000", "app", "--", "--dev"]) == "app"
expect Versions.app_dir(["--sql", "examples/notes", "--engine", "turso"]) == "examples/notes"
expect Versions.app_dir(["--", "roc", "check", "x/main.roc"]) == "."
expect Versions.app_dir([]) == "."
expect Versions.app_dir(["site", "--release", "out", "--target", "arm64musl"]) == "site"
expect Versions.first_word("2026.11.25 1714d3c rocx-fork-4674b5973d\n") == "2026.11.25"
expect Versions.is_version("2026.11.25.2")
expect !Versions.is_version("../x")
expect !Versions.is_version("1.0/2")
expect !Versions.is_version("")
