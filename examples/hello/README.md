# hello

The smallest Roc Solid app with a page: a button at `/` that counts its clicks, and an endpoint at
`/hello`. It is the app the docs' [Getting started](https://roc-solid.github.io/#start) makes, and
what every app starts from.

## Run it

From the repository's root, after `just setup`:

```sh
cd examples/hello
../../bin/rocx dev    # http://localhost:8080, built again on each save
```

The first run builds the server's host, once, in a few minutes. Then open http://localhost:8080
and click the button. `curl http://localhost:8080/hello` answers `"Hello from the server"`.

## Its three files

- **[`routes/+page.rocx`](routes/+page.rocx)** is the page at `/`. Its `view!` is an effectful
  component: it runs once, and makes a signal with `create_signal!(0.I64)`, which gives an accessor
  (`count!`, to read it) and a setter (`set_count!`). The hole `{count!().to_str()}` reads the
  signal, so each click changes that text and nothing else. The server renders the page; the
  browser then takes it over (hydration), and the button works.
- **[`routes/hello/+server.roc`](routes/hello/+server.roc)** is the endpoint `GET /hello`. A route's
  folder is its URL, and `get!` answers a GET there. What it returns is sent as JSON.
- **[`main.roc`](main.roc)** is the app's program. `rocx dev` wrote it, because the app had none:
  `App.program` with an `init!` and a middleware that passes every request on. It is yours to change
  when the app needs a database, a middleware of its own or plugins.

`rocx dev` also writes `Generated/` (modules made from your routes) and `build/`. Both are
gitignored.

Your own app can live anywhere, in a folder of its own with `routes/` in it. Run `rocx dev` there
(`bin/rocx` on your `PATH`), and it writes a `main.roc` like this one, its platform's path pointing
into your clone.

## Change something first

- Change the page's heading and save. The page reloads with it.
- Copy `routes/+page.rocx` to `routes/about/+page.rocx`: that is a page at `/about`.
- Make the endpoint answer a record: change `Str` in its type to `{ greeting : Str }`, and its
  answer to `Ok({ greeting: "Hello" })`. The JSON follows the type.

## Read next

- [`examples/tasks`](../tasks): a whole app, written the plain way, with comments throughout:
  layouts, a database, forms that work without JavaScript, optimistic changes.
- The docs at [roc-solid.github.io](https://roc-solid.github.io/): start with
  [Components](https://roc-solid.github.io/components) (signals, holes, `view` and `view!`) and
  [Routing](https://roc-solid.github.io/routing) (pages, layouts, endpoints).
