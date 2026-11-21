# echo

The smallest app on the server platform, for measuring the server itself: one endpoint,
`POST /echo` (`routes/echo/+server.roc`), which answers with the JSON string it was sent. A request
goes through everything an app's request does (the host, `Server.from_http`, a middleware that only
passes it on, the generated routes, reading the JSON body and writing the JSON answer) and nothing
more: no database, no page, no log line.

```sh
examples/echo/bench.sh            # build with --opt=speed, start it on :18080, run bombardier
examples/echo/bench.sh 30 9000    # 30 s a level, on port 9000
```

By hand:

```sh
node bin/rocx.mjs build examples/echo
node server/build.mjs examples/echo/main.roc /tmp/rocx-echo/echo --opt=speed
/tmp/rocx-echo/echo --port 18080 --host 127.0.0.1 &
bombardier -m POST -H 'content-type: application/json' -b '"hello"' -c 64 -d 10s -l http://127.0.0.1:18080/echo
```

Each answer's `server-timing` header says how long Roc took on it. Measure on a quiet machine:
bombardier runs on the same one and competes with the server for its cores.
