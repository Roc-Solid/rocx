## The command-line platform rocx is built on (`bin/rocx`): its output and input, the environment,
## files, commands run to their end or beside it, directory trees watched, the signals it is sent,
## and GETs of a server on this machine. Whatever happens while a program waits (a file changed, a
## child ended, a signal) is an event, and `Events.next!` waits for the next one: a program that
## watches is one plain loop.
## The host is Rust (../host), on the C library alone.
platform ""
	requires {
		main! : List(Str) => Try({}, [Exit(I32), ..])
	}
	exposes [Child, Cmd, Env, Events, File, Http, Stderr, Stdin, Stdout, Time, Watch]
	packages {}
	provides {
		"roc_main": main_for_host!,
	}
	hosted {
		"roc_host_alive": Host.alive!,
		"roc_host_copy": Host.copy!,
		"roc_host_create_new": Host.create_new!,
		"roc_host_cwd": Host.cwd!,
		"roc_host_delete": Host.delete!,
		"roc_host_env_var": Host.env_var!,
		"roc_host_exe_path": Host.exe_path!,
		"roc_host_exec": Host.exec!,
		"roc_host_exists": Host.exists!,
		"roc_host_free_port": Host.free_port!,
		"roc_host_http_get": Host.http_get!,
		"roc_host_is_dir": Host.is_dir!,
		"roc_host_is_terminal": Host.is_terminal!,
		"roc_host_kill": Host.kill!,
		"roc_host_list": Host.list!,
		"roc_host_make_dirs": Host.make_dirs!,
		"roc_host_modified": Host.modified!,
		"roc_host_next": Host.next!,
		"roc_host_now_ms": Host.now_ms!,
		"roc_host_now_ns": Host.now_ns!,
		"roc_host_pid": Host.pid!,
		"roc_host_read": Host.read!,
		"roc_host_read_bytes": Host.read_bytes!,
		"roc_host_real_path": Host.real_path!,
		"roc_host_rename": Host.rename!,
		"roc_host_run": Host.run!,
		"roc_host_sleep": Host.sleep!,
		"roc_host_spawn": Host.spawn!,
		"roc_host_stdin": Host.stdin!,
		"roc_host_stdin_line": Host.stdin_line!,
		"roc_host_symlink": Host.symlink!,
		"roc_host_watch": Host.watch!,
		"roc_host_write": Host.write!,
		"roc_host_write_bytes": Host.write_bytes!,
		"roc_host_write_file": Host.write_file!,
	}
	targets: {
		inputs_dir: "targets/",
		arm64mac: { inputs: ["libhost.a", app] },
		x64mac: { inputs: ["libhost.a", app] },
		arm64musl: { inputs: ["rcrt1.o", "libhost.a", app, "libunwind.a", "libc.a"] },
		x64musl: { inputs: ["rcrt1.o", "libhost.a", app, "libunwind.a", "libc.a"] },
	}

import Child
import Cmd
import Env
import Events
import File
import Host
import Http
import Stderr
import Stdin
import Stdout
import Time
import Watch

## The app's `main!`, given the arguments (not the program's name): its exit code. An error the app
## didn't handle is said, and exits 1.
main_for_host! : List(Str) => I32
main_for_host! = |args|
	match main!(args) {
		Ok({}) => 0
		Err(Exit(code)) => code
		Err(other) => {
			Host.write!(2, "${Str.inspect(other)}\n")
			1
		}
	}
