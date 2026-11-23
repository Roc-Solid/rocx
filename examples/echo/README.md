# echo

The smallest app on the server platform, for measuring the server itself. Two endpoints:

- `POST /echo` (`routes/echo/+server.roc`) answers with the JSON string it was sent. It's the least
  an endpoint can be asked, so what's left is the server's own cost.
- `POST /echo/json` (`routes/echo/json/+server.roc`) reads an order into a record of its type,
  `Shop.Order` (`Shop.roc`: a customer with an address, items each with its tags, shipping, a
  note), and answers with it, written as JSON again: what most endpoints do with a body. A body the
  type doesn't fit is refused with a 400 before the endpoint runs. `order.json` is the order the
  benchmark sends (compact, as a client sends JSON).

A request goes through everything an app's request does (the host, `Server.from_http`, a middleware
that only passes it on, the generated routes, reading the JSON body and writing the JSON answer) and
nothing more: no database, no page, no log line. `test/echo.test.mjs` checks that each endpoint
answers what the benchmark sends.

```sh
examples/echo/bench.sh            # build with --opt=speed, start it on :18080, run bombardier on each endpoint
examples/echo/bench.sh 30 9000    # 30 s a level, on port 9000
```

By hand:

```sh
bin/rocx build examples/echo   # bin/rocx: `just check` (or any script) builds it from rocx-cli/
node server/build.mjs examples/echo/main.roc /tmp/rocx-echo/echo --opt=speed
/tmp/rocx-echo/echo --port 18080 --host 127.0.0.1 &
bombardier -m POST -H 'content-type: application/json' -b '"hello"' -c 64 -d 10s -l http://127.0.0.1:18080/echo
bombardier -m POST -H 'content-type: application/json' -b "$(node -e 'process.stdout.write(JSON.stringify(require("./examples/echo/order.json")))')" -c 64 -d 10s -l http://127.0.0.1:18080/echo/json
```

Each answer's `server-timing` header says how long Roc took on it. Measure on a quiet machine:
bombardier runs on the same one and competes with the server for its cores.
