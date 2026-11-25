## The docs site's prepare step (`rocx site prepare [--dev] [--no-lock]`): everything `roc check`
## needs of site/, written before the site's wasm and server are built (`just dev`, `just site`,
## the tests). In order:
##
## 1. site/Generated/PlatformReference.roc (SiteReference), ExampleApps.roc (from
##    site/example-apps.json, which site/example-apps.mjs measures), DbBench.roc (from
##    site/sqlite-vs-turso.json) and JsBench.roc (from site/js-framework-benchmark.json,
##    benchmarks/jsframework/run.mjs's): before rocx build, which copies them into the browser's copy;
## 2. rocx build site --client site/build/client (with the stories, for a dev build);
## 3. the server platform's copy of the modules both platforms have;
## 4. site/Generated/Sources.roc (SiteSources), which quotes what rocx build wrote, and the
##    browser's copy of it.
##
## A file that would be written as it is stays untouched, so a watcher doesn't build again. Builds
## share site/build, so this holds site/build/building.lock while it writes (site/build.mjs's lock,
## which `just site` and the tests take): a JSON file, `{"pid":…,"what":…}`, made only if none is
## there; another build waits for it, and one left by a process that is gone is taken over.
## `--no-lock` is for site/build.mjs, which holds it already.
import pf.Env
import pf.File
import pf.Stderr
import pf.Time
import Build
import Fs
import SiteReference
import SiteSources
import Text
import Value

Site := [].{

	## `rocx site prepare [--dev] [--no-lock]`, in `root` (the clone rocx is in); `rocx` is this
	## program, for the check's report. What went wrong, if anything did.
	prepare! : Str, Str, List(Str) => Try({}, [Problem(Str)])
	prepare! = |root, rocx, flags| {
		dev = flags.contains("--dev")
		locking = !flags.contains("--no-lock")
		what = if (dev) "a dev build" else "a build"
		if locking {
			Site.acquire!(root, what)?
		}
		done = Site.prepare_unlocked!(root, rocx, dev)
		if locking {
			Site.release!(root)
		}
		done
	}

	prepare_unlocked! : Str, Str, Bool => Try({}, [Problem(Str)])
	prepare_unlocked! = |root, rocx, dev| {
		generated = Fs.join([root, "site", "Generated"])
		Site.write_if_changed!(Fs.join([generated, "PlatformReference.roc"]), SiteReference.module_text(SiteReference.platform_reference!(root)?))
		facts = Value.parse(Fs.read_or_empty!(Fs.join([root, "site", "example-apps.json"]))) ?? Null
		Site.write_if_changed!(Fs.join([generated, "ExampleApps.roc"]), Site.example_apps_module(facts, Site.shot_files!(Fs.join([root, "site", "static", "shots"]))))
		bench = Value.parse(Fs.read_or_empty!(Fs.join([root, "site", "sqlite-vs-turso.json"]))) ?? Null
		Site.write_if_changed!(Fs.join([generated, "DbBench.roc"]), Site.db_bench_module(bench))
		frameworks = Value.parse(Fs.read_or_empty!(Fs.join([root, "site", "js-framework-benchmark.json"]))) ?? Null
		Site.write_if_changed!(Fs.join([generated, "JsBench.roc"]), Site.js_bench_module(frameworks))
		# rocx build, in this process.
		built = Build.build!(["site"], { client: Some("site/build/client"), cwd: root, dev, rocx: root })?
		if !built.ok {
			return Err(Problem("rocx build failed:\n${Str.join_with(built.said, "\n")}"))
		}
		Site.sync_shared!(root)
		# The sources the pages show, which quote what rocx build wrote, so they come after it; and
		# the browser's copy of the site gets them too, since rocx build copied the site before they
		# were written (on a fresh checkout, before there were any).
		sources = SiteSources.module!(root, rocx, Site.roc!(root)?)?
		Site.write_if_changed!(Fs.join([generated, "Sources.roc"]), sources)
		Site.write_if_changed!(Fs.join([root, "site", "build", "client", "Generated", "Sources.roc"]), sources)
		Ok({})
	}

	## The Roc compiler: the one `just setup` links in .tools (the fork rocx builds with), as the file
	## it links to (a new pin is a new path); else $ROC.
	roc! : Str => Try(Str, [Problem(Str)])
	roc! = |root| {
		active = Fs.join([root, ".tools", "roc-active"])
		if Fs.exists!(active) {
			Ok(Fs.real!(active))
		} else {
			match Env.var!("ROC") {
				Ok(roc) => Ok(roc)
				Err(NotFound) => Err(Problem("no Roc compiler: run `just setup` (or set ROC)"))
			}
		}
	}

	## Writes `text` to `path` unless it holds that already: an unchanged file stays untouched, so a
	## watcher doesn't see a change and build again.
	write_if_changed! : Str, Str => {}
	write_if_changed! = |path, text| {
		match Fs.read!(path) {
			Ok(old) if old == text => {}
			_ => {
				_ = Fs.write!(path, text)
			}
		}
	}

	## The server platform's copy of the modules both platforms have (server/build.mjs's syncShared).
	sync_shared! : Str => {}
	sync_shared! = |root| {
		for name in SiteReference.shared_modules {
			text = Fs.read_or_empty!(Fs.join([root, "web", "platform", "${name}.roc"]))
			Site.write_if_changed!(Fs.join([root, "server", "platform", "${name}.roc"]), text)
		}
	}

	# ---- One build at a time ----

	lock_of : Str -> Str
	lock_of = |root| Fs.join([root, "site", "build", "building.lock"])

	## Takes site/build's lock, waiting while another process that is running holds it: one that is
	## gone, or a lock that can't be read for two seconds (left half-written), is taken over.
	acquire! : Str, Str => Try({}, [Problem(Str)])
	acquire! = |root, what| {
		lock = Site.lock_of(root)
		Fs.make_dirs!(Fs.dirname(lock))
		mine = Value.encode(Object([{ key: "pid", value: Number(Env.pid!({}).to_i64()) }, { key: "what", value: Text(what) }]))
		var $told = Bool.False
		var $unreadable_since = 0
		var $taken = Bool.False
		while !$taken {
			match File.create_new!(lock, mine) {
				Ok({}) => return Ok({})
				Err(CantWrite(why)) => return Err(Problem(why))
				Err(Exists) => {}
			}
			holder = Value.parse(Fs.read_or_empty!(lock)) ?? Null
			pid = Value.int_or(Value.field(holder, "pid"), 0)
			if pid <= 0 {
				# Being written, or gone already; or left half-written by a process that died.
				now = Time.now_ms!({})
				if $unreadable_since == 0 {
					$unreadable_since = now
				} else if now - $unreadable_since > 2000 {
					Fs.delete!(lock)
				}
			} else {
				$unreadable_since = 0
				if !Env.alive!(pid.to_u32_wrap()) {
					Fs.delete!(lock)
				} else if !$told {
					Stderr.line!("rocx site: waiting for the build in process ${pid.to_str()} (${Value.str(Value.field(holder, "what"))}) to finish") ?? {}
					$told = Bool.True
				}
			}
			Time.sleep!(200)
		}
		Ok({})
	}

	## Lets site/build's lock go, if this process holds it.
	release! : Str => {}
	release! = |root| {
		lock = Site.lock_of(root)
		holder = Value.parse(Fs.read_or_empty!(lock)) ?? Null
		if Value.int_or(Value.field(holder, "pid"), 0) == Env.pid!({}).to_i64() {
			Fs.delete!(lock)
		}
	}

	# ---- The example apps' facts and SQLite against Turso, as Roc ----

	int : Value -> Str
	int = |value| Value.int_or(value, 0).to_str()

	## The screenshots under site/static/shots, as `<app>/<scene>`.
	shot_files! : Str => List(Str)
	shot_files! = |dir| {
		var $found = []
		for named in Fs.entries!(dir) {
			if Fs.is_dir!(Fs.join([dir, named])) {
				for file in Fs.entries!(Fs.join([dir, named])) {
					if file.ends_with(".webp") {
						$found = $found.append("${named}/${file.drop_suffix(".webp")}")
					}
				}
			}
		}
		Text.sorted($found)
	}

	## site/Generated/ExampleApps.roc: `facts` (site/example-apps.json) as values the examples page reads.
	example_apps_module : Value, List(Str) -> Str
	example_apps_module = |facts, shots| {
		q = Text.roc_string
		field = |value, key| Value.field(value, key)
		size = |s|
			match s {
				Object(_) => "[{ bytes: ${Site.int(field(s, "bytes"))}, gzip: ${Site.int(field(s, "gzip"))}, brotli: ${Site.int(field(s, "brotli"))} }]"
				_ => "[]"
			}
		database = |e|
			match field(e, "database") {
				Null => if (Value.bool_or(field(e, "postgres"), Bool.False)) "Postgres" else ""
				given => Value.str(given)
			}
		example = |e| [
			"\t\t{",
			"\t\t\tname: ${q(Value.str(field(e, "name")))},",
			"\t\t\ttitle: ${q(Value.str(field(e, "title")))},",
			"\t\t\tpages: ${Site.int(field(e, "pages"))},",
			"\t\t\tendpoints: ${Site.int(field(e, "endpoints"))},",
			"\t\t\tlines: ${Site.int(field(e, "lines"))},",
			"\t\t\texpects: ${Site.int(field(e, "expects"))},",
			"\t\t\ttests: ${Site.int(field(e, "tests"))},",
			"\t\t\tpkgs: [${Str.join_with(Value.items(field(e, "packages")).map(|p| q(Value.str(p))), ", ")}],",
			"\t\t\tdatabase: ${q(database(e))},",
			"\t\t\twasm: ${size(field(e, "wasm"))},",
			"\t\t},",
		]
		level = |l| "{ connections: ${Site.int(field(l, "connections"))}, rps: ${Site.int(field(l, "rps"))}, p50_us: ${Site.int(field(l, "p50_us"))}, p99_us: ${Site.int(field(l, "p99_us"))}, errors: ${Site.int(field(l, "errors"))} }"
		variant = |v| {
			body = Value.str(field(v, "body"))
			shown = Value.str_or(field(v, "shown"), body)
			"{ name: ${q(Value.str(field(v, "name")))}, path: ${q(Value.str(field(v, "path")))}, body: ${q(body)}, shown: ${q(shown)}, bytes: ${Site.int(field(v, "bytes"))}, roc_us: ${Site.int(field(v, "roc_us"))}, load: ${q(Value.str(field(v, "load")))}, levels: [${Str.join_with(Value.items(field(v, "levels")).map(level), ", ")}] }"
		}
		b = field(facts, "bench")
		# A benchmark from before echo had two endpoints measured its one: POST /echo, a string.
		variants =
			match field(b, "variants") {
				Array(list) => list
				_ => {
					body = Value.str_or(field(b, "body"), "\"hello\"")
					[
						Object([
							{ key: "name", value: Text("simple") },
							{ key: "path", value: Text("/echo") },
							{ key: "body", value: Text(body) },
							{ key: "bytes", value: Value.count(body.to_utf8().len()) },
							{ key: "roc_us", value: field(b, "roc_us") },
							{ key: "load", value: field(b, "load") },
							{ key: "levels", value: field(b, "levels") },
						]),
					]
				}
			}
		bench_line =
			match b {
				Object(_) => "\tbench = [{ measured: ${q(Value.str(field(b, "measured")))}, commit: ${q(Value.str(field(b, "commit")))}, machine: ${q(Value.str(field(b, "machine")))}, load: ${q(Value.str(field(b, "load")))}, opt: ${q(Value.str(field(b, "opt")))}, seconds: ${Site.int(field(b, "seconds"))}, hardware: ${Site.machine_record(field(b, "hardware"))}, variants: [${Str.join_with(variants.map(variant), ", ")}] }]"
				_ => "\tbench = []"
			}
		runtime = size(field(facts, "runtime"))
		runtime_bytes = runtime.to_utf8()
		lines =
			[
				"## Written by `rocx site prepare` from site/example-apps.json, which site/example-apps.mjs measures.",
				"## Run that again (`just example-apps`), not this one.",
				"ExampleApps := [].{",
				"\tSize : { bytes : U64, gzip : U64, brotli : U64 }",
				"\tExample : { name : Str, title : Str, pages : U64, endpoints : U64, lines : U64, expects : U64, tests : U64, pkgs : List(Str), database : Str, wasm : List(Size) }",
				"\tLevel : { connections : U64, rps : U64, p50_us : U64, p99_us : U64, errors : U64 }",
				"\tHardware : { model : Str, cpu : Str, cores : Str, memory : Str, storage : Str, os : Str, arch : Str, power : Str }",
				"",
				"\t## One endpoint's run: what was sent (`body`, exactly; `shown`, as the page shows it), Roc's own time on a request, and each level.",
				"\tVariant : { name : Str, path : Str, body : Str, shown : Str, bytes : U64, roc_us : U64, load : Str, levels : List(Level) }",
				"\tBench : { measured : Str, commit : Str, machine : Str, load : Str, opt : Str, seconds : U64, hardware : Hardware, variants : List(Variant) }",
				"",
				"\t## When, at which commit, with which compiler, and on what the sizes were measured.",
				"\tmeasured : { date : Str, commit : Str, roc : Str, machine : Str }",
				"\tmeasured = { date: ${q(Value.str(field(facts, "measured")))}, commit: ${q(Value.str(field(facts, "commit")))}, roc: ${q(Value.str(field(facts, "roc")))}, machine: ${q(Value.str(field(facts, "machine")))} }",
				"",
				"\t## The runtime every page loads beside its app's wasm (web/runtime.js).",
				"\truntime : Size",
				"\truntime = ${Text.cut(runtime_bytes, 1, if (runtime_bytes.len() > 1) runtime_bytes.len() - 1 else 1)}",
				"",
				"\t## The example apps, by name.",
				"\tall : List(Example)",
				"\tall = [",
			]
				.concat(Value.items(field(facts, "examples")).fold([], |all, e| all.concat(example(e))))
				.concat([
					"\t]",
					"",
					"\t## The screenshots there are under site/static/shots, as `<app>/<scene>` (`just example-shots`).",
					"\tshots : List(Str)",
					"\tshots = [${Str.join_with(shots.map(q), ", ")}]",
					"",
					"\t## The server's benchmark (echo's), if one was run.",
					"\tbench : List(Bench)",
					bench_line,
					"}",
					"",
				])
		Str.join_with(lines, "\n")
	}

	## A machine's facts as a Roc record (site/machine.mjs's; "" where there are none: a benchmark
	## from before they were kept).
	machine_record : Value -> Str
	machine_record = |facts| {
		keys = ["model", "cpu", "cores", "memory", "storage", "os", "arch", "power"]
		"{ ${Str.join_with(keys.map(|key| "${key}: ${Text.roc_string(Value.str(Value.field(facts, key)))}"), ", ")} }"
	}

	## site/Generated/DbBench.roc: `results` (site/sqlite-vs-turso.json, or `Null` before it was run)
	## as values examples/sqlite-vs-turso's page reads. A file from before runs in a row (one median a
	## workload, `machine` a line) has no workloads here, and no machine.
	db_bench_module : Value -> Str
	db_bench_module = |results| {
		q = Text.roc_string
		field = |value, key| Value.field(value, key)
		text = |key| Value.str(field(results, key))
		number = |key| Site.int(field(results, key))
		engines = Value.items(field(results, "engines"))
		keys = engines.map(|e| Value.str(field(e, "key")))
		first_workload =
			match Value.items(field(results, "workloads")).first() {
				Ok(w) => w
				Err(_) => Null
			}
		first_key =
			match keys.first() {
				Ok(key) => key
				Err(_) => ""
			}
		fresh =
			match field(field(field(first_workload, "results"), first_key), "ns") {
				Array(_) => Bool.True
				_ => Bool.False
			}
		list = |values| "[${Str.join_with(Value.items(values).map(Site.int), ", ")}]"
		engine = |e| "{ key: ${q(Value.str(field(e, "key")))}, label: ${q(Value.str(field(e, "label")))}, note: ${q(Value.str(field(e, "note")))}, version: ${q(Value.str(field(e, "version")))} }"
		workload = |w| {
			result = |key| {
				r = field(field(w, "results"), key)
				"{ engine: ${q(key)}, ns: ${list(field(r, "ns"))}, runs: ${list(field(r, "runs"))} }"
			}
			[
				"\t\t{",
				"\t\t\tname: ${q(Value.str(field(w, "name")))},",
				"\t\t\twhat: ${q(Value.str(field(w, "what")))},",
				"\t\t\tcallers: ${Site.int(field(w, "callers"))},",
				"\t\t\tops: ${Site.int(field(w, "ops"))},",
				"\t\t\tresults: [${Str.join_with(keys.map(result), ", ")}],",
				"\t\t},",
			]
		}
		workloads = |key| if (fresh) Value.items(field(results, key)).fold([], |all, w| all.concat(workload(w))) else []
		machine = if (fresh) field(results, "machine") else Null
		lines =
			[
				"## Written by `rocx site prepare` from site/sqlite-vs-turso.json, which site/sqlite-vs-turso.mjs",
				"## measures. Run that again (`just db-bench`), not this one.",
				"DbBench := [].{",
				"\tEngine : { key : Str, label : Str, note : Str, version : Str }",
				"",
				"\t## An engine's time for a workload in each run, in order (nanoseconds), and its transactions' runs.",
				"\tResult : { engine : Str, ns : List(U64), runs : List(U64) }",
				"\tWorkload : { name : Str, what : Str, callers : U64, ops : U64, results : List(Result) }",
				"",
				"\t## When, at which commit, how big (the everyday run's items; the big run's orders and customers), and how many runs in a row of each.",
				"\tmeasured : { date : Str, commit : Str, load : Str, opt : Str, size : U64, rows : U64, orders : U64, customers : U64, runs : U64, big_runs : U64 }",
				"\tmeasured = { date: ${q(text("measured"))}, commit: ${q(text("commit"))}, load: ${q(text("load"))}, opt: ${q(text("opt"))}, size: ${number("size")}, rows: ${number("rows")}, orders: ${number("orders")}, customers: ${number("customers")}, runs: ${number("runs")}, big_runs: ${number("bigRuns")} }",
				"",
				"\t## What it ran on (site/machine.mjs).",
				"\tmachine : { model : Str, cpu : Str, cores : Str, memory : Str, storage : Str, os : Str, arch : Str, power : Str }",
				"\tmachine = ${Site.machine_record(machine)}",
				"",
				"\t## The engines, in the page's order.",
				"\tengines : List(Engine)",
				"\tengines = [${Str.join_with(engines.map(engine), ", ")}]",
				"",
				"\t## Each everyday workload, its time on each engine in each run.",
				"\tworkloads : List(Workload)",
				"\tworkloads = [",
			]
				.concat(workloads("workloads"))
				.concat(["\t]", "", "\t## Each workload of the big run (a million orders), its time on each engine in each run.", "\tbig : List(Workload)", "\tbig = ["])
				.concat(workloads("big"))
				.concat(["\t]", "}", ""])
		Str.join_with(lines, "\n")
	}

	## site/Generated/JsBench.roc: js-framework-benchmark's results (site/js-framework-benchmark.json,
	## which benchmarks/jsframework/run.mjs writes; `Null` before it was run) as values the
	## benchmark's page reads: the entries, each benchmark's mean and spread for each, and each
	## entry's summary, in hundredths (the file's `hundredths`: rocx reads a JSON number whole).
	js_bench_module : Value -> Str
	js_bench_module = |results| {
		q = Text.roc_string
		field = |value, key| Value.field(value, key)
		text = |key| Value.str(field(results, key))
		frameworks = Value.items(field(results, "frameworks"))
		names = frameworks.map(|f| Value.str(field(f, "entry")))
		hundredths = field(results, "hundredths")
		entry = |f| "{ entry: ${q(Value.str(field(f, "entry")))}, name: ${q(Value.str(field(f, "name")))}, version: ${q(Value.str(field(f, "version")))} }"
		row = |b| {
			id = Value.str(field(b, "id"))
			of = |key| Str.join_with(names.map(|name| Site.int(field(field(field(field(hundredths, "results"), name), id), key))), ", ")
			"\t\t{ id: ${q(id)}, label: ${q(Value.str(field(b, "label")))}, means: [${of("mean")}], spreads: [${of("stddev")}] },"
		}
		category = |c, i| {
			numbers = field(Value.items(field(hundredths, "categories")).get(i) ?? Null, "values")
			ratios = field(Value.items(field(hundredths, "categories")).get(i) ?? Null, "ratios")
			whole = |list| Str.join_with(Value.items(list).map(Site.int), ", ")
			"\t\t{ id: ${q(Value.str(field(c, "id")))}, label: ${q(Value.str(field(c, "label")))}, unit: ${q(Value.str(field(c, "unit")))}, what: ${q(Value.str(field(c, "what")))}, values: [${whole(numbers)}], ratios: [${whole(ratios)}] },"
		}
		summary = |name| {
			s = field(field(hundredths, "summary"), name)
			n = |key| Site.int(field(s, key))
			"\t\t{ cpu: ${n("cpu_geomean_ms")}, slowdown: ${n("slowdown")}, ready_memory: ${n("ready_memory_mb")}, run_memory: ${n("run_memory_mb")}, compressed: ${n("compressed_kb")}, uncompressed: ${n("uncompressed_kb")}, first_paint: ${n("first_paint_ms")} },"
		}
		lines =
			[
				"## Written by `rocx site prepare` from site/js-framework-benchmark.json, which",
				"## benchmarks/jsframework/run.mjs measures (`just js-bench bench`). Run that again, not this one.",
				"JsBench := [].{",
				"\t## An entry: its folder in the benchmark (`keyed/solid`), its name on the page, and what was measured (`solid-v1.9.3-keyed`).",
				"\tEntry : { entry : Str, name : Str, version : Str }",
				"",
				"\t## A benchmark's results, in hundredths (of a millisecond, a megabyte or a kilobyte): each entry's mean and standard deviation, in `entries`' order (0 where there is none).",
				"\tRow : { id : Str, label : Str, means : List(U64), spreads : List(U64) }",
				"",
				"\t## An entry's summary, in hundredths: the CPU benchmarks' geometric mean (ms), its slowdown against each benchmark's fastest (×), memory once ready and with 1,000 rows (MB), what the page downloads compressed and not (KB), and its first paint (ms). 0 where there is none.",
				"\tSummary : { cpu : U64, slowdown : U64, ready_memory : U64, run_memory : U64, compressed : U64, uncompressed : U64, first_paint : U64 }",
				"",
				"\t## When, at which commit of Roc Solid and of the benchmark, in which Chrome, how many rounds of how many iterations, how long, and the load and power during it.",
				"\tmeasured : { date : Str, commit : Str, benchmark : Str, chrome : Str, rounds : U64, count : U64, minutes : U64, load : Str, power : Str }",
				"\tmeasured = { date: ${q(text("measured"))}, commit: ${q(text("commit"))}, benchmark: ${q(text("benchmark"))}, chrome: ${q(text("chrome"))}, rounds: ${Site.int(field(results, "rounds"))}, count: ${Site.int(field(results, "count"))}, minutes: ${Site.int(field(results, "minutes"))}, load: ${q(text("load"))}, power: ${q(text("power"))} }",
				"",
				"\t## What it ran on (site/machine.mjs).",
				"\tmachine : { model : Str, cpu : Str, cores : Str, memory : Str, storage : Str, os : Str, arch : Str, power : Str }",
				"\tmachine = ${Site.machine_record(field(results, "machine"))}",
				"",
				"\t## The entries, in the page's order.",
				"\tentries : List(Entry)",
				"\tentries = [${Str.join_with(frameworks.map(entry), ", ")}]",
				"",
				"\t## What the page leads with: a figure each (`what` it is made of, in `unit`), each entry's value and its ratio to the best entry's, in hundredths, in `entries`' order (0 where there is none). Lower is better.",
				"\tCategory : { id : Str, label : Str, unit : Str, what : Str, values : List(U64), ratios : List(U64) }",
				"",
				"\t## Ready to use, first paint, making rows, updating rows, memory, download.",
				"\tcategories : List(Category)",
				"\tcategories = [",
			]
				.concat(Value.items(field(results, "categories")).map_with_index(category))
				.concat([
					"\t]",
					"",
					"\t## Each benchmark, in the runner's order.",
					"\trows : List(Row)",
					"\trows = [",
				])
				.concat(Value.items(field(results, "benchmarks")).map(row))
				.concat(["\t]", "", "\t## Each entry's summary, in `entries`' order.", "\tsummaries : List(Summary)", "\tsummaries = ["])
				.concat(names.map(summary))
				.concat(["\t]", "}", ""])
		Str.join_with(lines, "\n")
	}

	# ---- rocx internal, for the site's test ----

	## The calls site/test/site.test.mjs makes (rocx-cli/rocx.mjs names them); `root` is the clone's.
	rpc! : Str, Str, List(Value) => Try(Value, [Failed(Value), Unknown(Str)])
	rpc! = |root, name, args| {
		arg = |i| args.get(i) ?? Null
		match name {
			"platformReference" =>
				match SiteReference.platform_reference!(Value.str_or(arg(0), root)) {
					Ok(modules) => Ok(Array(modules.map(SiteReference.module_value)))
					Err(Problem(message)) => Err(Failed(Value.problem(message)))
				}
			"undocumented" => Ok(Value.strs(SiteReference.undocumented(Value.items(arg(0)).map(SiteReference.module_from))))
			"referenceBlocks" => Ok(Array(SiteReference.blocks(Value.str(arg(0))).map(SiteReference.block_value)))
			_ => Err(Unknown(name))
		}
	}
}
