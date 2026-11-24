# echo

The smallest app on the server platform, there to measure the server itself. It has two endpoints
and no pages, so it has no browser half. Read it to see an endpoint at its simplest, and a JSON
body read into a typed record and written back.

## The two endpoints

- **`POST /echo`** ([`routes/echo/+server.roc`](routes/echo/+server.roc)) answers with the JSON
  string it was sent. It is the least an endpoint can do, so what a request costs here is the
  server's own cost.
- **`POST /echo/json`** ([`routes/echo/json/+server.roc`](routes/echo/json/+server.roc)) reads an
  order into a record of its type, `Shop.Order` ([`Shop.roc`](Shop.roc): a customer with an
  address, items each with its tags, shipping, a note), and answers with it, written as JSON again.
  That is what most endpoints do with a body. A body that doesn't fit the type is refused with a
  400 before the endpoint runs. [`order.json`](order.json) is the order the benchmark sends.

A request goes through everything an app's request goes through, and nothing more: the native
host, the request read into a `Server.Request`, a middleware that only passes it on
([`main.roc`](main.roc)), the routes `rocx build` generates, and the JSON body read and the answer
written. There is no database, no page and no log line.

## Run it

From the repository's root, after `just setup`:

```sh
cd examples/echo
../../bin/rocx dev    # http://localhost:8080, built again on each save
```

Then, from another terminal in `examples/echo`:

```sh
curl -H 'content-type: application/json' -d '"hello"' http://localhost:8080/echo
curl -H 'content-type: application/json' -d @order.json http://localhost:8080/echo/json
```

`rocx dev` builds without optimizations. Measure with the benchmark below instead.

## Benchmark it

[`bench.sh`](bench.sh) builds the app optimized (`--opt=speed`), starts it, and runs
[bombardier](https://github.com/codesenberg/bombardier) on each endpoint at 1, 16, 64 and 256
connections:

```sh
examples/echo/bench.sh            # 10 s a level, on port 18080
examples/echo/bench.sh 30 9000    # 30 s a level, on port 9000
```

Or by hand, from the repository's root:

```sh
bin/rocx build examples/echo
node server/build.mjs examples/echo/main.roc /tmp/rocx-echo/echo --opt=speed
/tmp/rocx-echo/echo --port 18080 --host 127.0.0.1 &
bombardier -m POST -H 'content-type: application/json' -b '"hello"' -c 64 -d 10s -l http://127.0.0.1:18080/echo
bombardier -m POST -H 'content-type: application/json' -b "$(node -e 'process.stdout.write(JSON.stringify(require("./examples/echo/order.json")))')" -c 64 -d 10s -l http://127.0.0.1:18080/echo/json
```

Each answer's `server-timing` header says how long Roc took on it, so you can tell Roc's time from
the server's. Measure on a quiet machine: bombardier runs on the same one, and competes with the
server for its cores. `just example-apps --bench` runs the benchmark for the docs' page,
[Examples: echo](https://roc-solid.github.io/examples/echo).

## Test it

```sh
just examples echo                          # build, type-check, lint, run the expects and the tests
node --test 'examples/echo/test/*.test.mjs'
```

[`test/echo.test.mjs`](test/echo.test.mjs) checks that each endpoint answers what the benchmark
sends, that `server-timing` is there, and that a body that isn't an order is refused (400).
